import XCTest
import AgentDeckCore

final class HookDaemonContractTests: XCTestCase {
    private var home: URL!
    private var daemon: Daemon?
    private var latest: [Session] = []
    // Contract/ -> AgentDeckCoreTests/ -> Tests/ -> repo root
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var hook: String { repo.appendingPathComponent("hooks/adeck-hook").path }
    private func fixture(_ rel: String) -> String {
        repo.appendingPathComponent("Tests/AgentDeckCoreTests/Fixtures/\(rel)").path }

    override func setUpWithError() throws {
        var t = Array("/tmp/adk.XXXXXX".utf8CString)
        XCTAssertNotNil(mkdtemp(&t))
        home = URL(fileURLWithPath: String(cString: t))
    }
    override func tearDown() { daemon?.stop(); try? FileManager.default.removeItem(at: home) }

    private func startDaemon(caps: [String: Int] = [:]) throws {
        let paths = AppPaths.live(home: home)
        XCTAssertLessThanOrEqual(paths.socket.path.utf8.count, 103)   // sun_path limit, protocol §1
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !caps.isEmpty {
            var cats = ["Bash": 3, "EditWrite": 3, "Web": 3, "MCP": 3, "Question": 3, "ExitPlanMode": 3, "Other": 3]
            cats.merge(caps) { $1 }
            let json: [String: Any] = ["version": 1, "extensionVersion": "test", "measuredAt": NSNull(),
                "deepLink": "cursor://anthropic.claude-code/open?session={session}", "categories": cats]
            try JSONSerialization.data(withJSONObject: json).write(to: paths.capabilities)
        }
        let d = Daemon(paths: paths, settings: AppSettings())
        d.onChange = { [weak self] in self?.latest = $0 }
        try d.start(); daemon = d
    }

    private final class HookRun {
        let process = Process(); let out = Pipe()
        private let lock = NSLock(); private var _done = false
        var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
        init(hook: String, mode: String, name: String, stdin: String, home: URL) throws {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [hook, mode, name]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin",
                "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92", "CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]
            process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: stdin)) // a file, never a pipe: no EPIPE
            process.standardOutput = out; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [self] _ in lock.lock(); _done = true; lock.unlock() }
            try process.run()
        }
        func waitExit(_ timeout: TimeInterval) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return done
        }
        var stdout: Data { out.fileHandleForReading.readDataToEndOfFile() }
    }
    private func start(_ mode: String, _ name: String, _ fx: String) throws -> HookRun {
        try HookRun(hook: hook, mode: mode, name: name, stdin: fixture("hooks/\(fx).json"), home: home)
    }
    private func waitFor(_ timeout: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }
    private func firstPending() -> Request? { latest.flatMap(\.pending).first }
    private func obj(_ d: Data) throws -> NSDictionary { try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? NSDictionary) }

    func testEventExitsZeroEmptyAndSessionAppears() throws {
        try startDaemon()
        let sid = try HookInput.decode(Data(contentsOf: URL(fileURLWithPath: fixture("hooks/SessionStart.json")))).sessionId
        let h = try start("event", "SessionStart", "SessionStart")
        XCTAssertTrue(h.waitExit(2)); XCTAssertEqual(h.process.terminationStatus, 0)
        XCTAssertTrue(h.stdout.isEmpty)
        XCTAssertTrue(waitFor { self.latest.contains { $0.id == sid } }, "session never reached onChange")
    }

    func testGateOnNotifyCategoryPrintsNothing() throws {
        try startDaemon()                                    // no capabilities.json -> every category notify
        let h = try start("gate", "PreToolUse", "PreToolUse-Bash")
        XCTAssertTrue(h.waitExit(2)); XCTAssertEqual(h.process.terminationStatus, 0)
        XCTAssertTrue(h.stdout.isEmpty)
    }

    func testDecideRaceHoldsThenAllowMatchesEnvelope() throws {
        try startDaemon(caps: ["Bash": 1])
        let h = try start("decide", "PermissionRequest", "PermissionRequest-Bash")
        XCTAssertTrue(waitFor { self.firstPending() != nil }, "no held request")
        let req = try XCTUnwrap(firstPending())
        XCTAssertNotEqual(req.risk.level, .high, "fixture must not be high risk or allow needs hold-confirm")
        XCTAssertFalse(h.waitExit(0.5), "hook must block while held")
        var result: ResolveResult?
        daemon!.resolve(requestId: req.id, decision: .allow, source: .click) { result = $0 }
        XCTAssertTrue(h.waitExit(3)); XCTAssertEqual(result, .applied); XCTAssertEqual(h.process.terminationStatus, 0)
        let expected = try obj(Data(contentsOf: URL(fileURLWithPath: fixture("envelopes/permission-allow.json"))))
        XCTAssertEqual(try obj(h.stdout), expected)          // leading heartbeat spaces are valid JSON
    }

    func testDaemonStopDuringHoldReleasesWithin1s() throws {
        try startDaemon(caps: ["Bash": 1])
        let h = try start("decide", "PermissionRequest", "PermissionRequest-Bash")
        XCTAssertTrue(waitFor { self.firstPending() != nil })
        let t0 = Date(); daemon!.stop(); daemon = nil
        XCTAssertTrue(h.waitExit(1)); XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        XCTAssertEqual(h.process.terminationStatus, 0); XCTAssertTrue(h.stdout.isEmpty)
    }

    private func armedCardAction(_ action: CardAction, request: Request) throws -> (String, Decision, DecisionSource) {
        let clock = FakeClock()
        let queue = CardQueue(clock: clock)
        queue.sync(pending: [request], context: QueueContext(expanded: true))
        queue.didRender(topId: request.id)
        XCTAssertEqual(queue.perform(action, renderedId: request.id, via: .click), .dropped(.notArmed))
        clock.advance(0.6)
        guard case .send(let id, let decision, let source) = queue.perform(action, renderedId: request.id, via: .click) else {
            XCTFail("rendered and armed card did not produce a decision")
            throw NSError(domain: "AgentDeckCardIntegration", code: 1)
        }
        XCTAssertEqual(id, request.id)
        return (id, decision, source)
    }

    func testQuestionRoundTripAnswersViaUpdatedInput() throws {
        try startDaemon(caps: ["Question": 2])
        daemon!.update(presence: PresenceSnapshot(frontmostBundleId: "com.apple.finder", idleSeconds: 600, at: Date())) // away
        let raw = try Data(contentsOf: URL(fileURLWithPath: fixture("hooks/PreToolUse-AskUserQuestion.json")))
        let toolInput = try XCTUnwrap((try obj(raw))["tool_input"] as? [String: Any])
        let q = try XCTUnwrap((toolInput["questions"] as? [[String: Any]])?.first?["question"] as? String)
        let h = try start("gate", "PreToolUse", "PreToolUse-AskUserQuestion")
        XCTAssertTrue(waitFor { self.firstPending()?.kind == .question }, "question not held while away")
        XCTAssertFalse(h.waitExit(0.5))
        let request = try XCTUnwrap(firstPending())
        XCTAssertEqual(CardLayout.buttons(for: request), [.submitAnswer, .openInCursor])
        let specs = QuestionForm.parse(request.fullInput)
        let answers = try XCTUnwrap(QuestionForm.answers(specs, QuestionSelection(other: [q: "yes-from-test"])))
        let (id, cardDecision, source) = try armedCardAction(.answer(answers), request: request)
        var result: ResolveResult?
        daemon!.resolve(requestId: id, decision: cardDecision, source: source) { result = $0 }
        XCTAssertTrue(h.waitExit(3)); XCTAssertEqual(result, .applied)
        var updated = toolInput; updated["answers"] = [q: "yes-from-test"]       // every original key kept, plus answers
        let expected: NSDictionary = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
            "permissionDecisionReason": "Answered in AgentDeck", "updatedInput": updated]]
        XCTAssertEqual(try obj(h.stdout), expected)
    }

    func testAllowAlwaysRoundTripCarriesSuggestionVerbatim() throws {
        try startDaemon(caps: ["Bash": 1])
        let input = try HookInput.decode(Data(contentsOf: URL(fileURLWithPath: fixture("hooks/PermissionRequest-Bash.json"))))
        let suggestion = try XCTUnwrap(input.permissionSuggestions.first, "fixture needs permission_suggestions")
        let h = try start("decide", "PermissionRequest", "PermissionRequest-Bash")
        XCTAssertTrue(waitFor { self.firstPending() != nil })
        let request = try XCTUnwrap(firstPending())
        XCTAssertTrue(CardLayout.buttons(for: request).contains(.allowAlways(rule: Envelopes.ruleText(for: suggestion), suggestion: suggestion)))
        let (id, cardDecision, source) = try armedCardAction(.allowAlways(suggestion), request: request)
        var result: ResolveResult?
        daemon!.resolve(requestId: id, decision: cardDecision, source: source) { result = $0 }
        XCTAssertTrue(h.waitExit(3)); XCTAssertEqual(result, .applied)
        let decision = try XCTUnwrap((try obj(h.stdout)["hookSpecificOutput"] as? NSDictionary)?["decision"] as? NSDictionary)
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let sent = try XCTUnwrap(decision["updatedPermissions"] as? [NSDictionary])
        XCTAssertEqual(sent, [try obj(suggestion.compactData())])
    }

    func testNoDaemonPrintsNothing() throws {
        let h = try start("gate", "PreToolUse", "PreToolUse-Bash")   // no daemon started, no socket
        XCTAssertTrue(h.waitExit(2)); XCTAssertEqual(h.process.terminationStatus, 0)
        XCTAssertTrue(h.stdout.isEmpty)
    }
}
