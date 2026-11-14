import XCTest
@testable import AgentDeckCore

final class SessionNavigatorTests: XCTestCase {
    let cursor = "com.todesktop.230313mzl4w4u92"
    let template = CapabilityMatrix.defaultDeepLink
    private func session(_ id: String = "11111111-2222-3333", entry: String?, host: String?, root: String? = "/w/api", cwd: String = "/w/api") -> Session {
        Session(id: id, project: "api", cwd: cwd, workspaceRoot: root, host: host, entrypoint: entry,
                startedAt: Date(timeIntervalSince1970: 0), lastEventAt: Date(timeIntervalSince1970: 0))
    }

    func testExtensionSessionFocusesItsWorkspaceWindowThenOpensExactSessionLink() {
        let steps = SessionNavigator.plan(for: session(entry: "claude-vscode", host: cursor), cursorBundleIds: [cursor],
                                          deepLinkTemplate: template, isDirectory: { _ in true })
        XCTAssertEqual(steps, [.focusFolder(path: "/w/api", bundleId: cursor),
                               .openURL(URL(string: "cursor://anthropic.claude-code/open?session=11111111-2222-3333")!)])
    }

    func testWorkspaceRootWinsOverALaterToolCwd() {
        let s = session(entry: "claude-vscode", host: cursor, root: "/w/api", cwd: "/private/tmp/scratch")
        XCTAssertEqual(SessionNavigator.plan(for: s, cursorBundleIds: [cursor], deepLinkTemplate: template, isDirectory: { _ in true }).first,
                       .focusFolder(path: "/w/api", bundleId: cursor))
    }

    func testMissingFolderOrUnknownHostNeverResumesViaDeepLink() {   // review M1
        XCTAssertEqual(SessionNavigator.plan(for: session(entry: "claude-vscode", host: cursor), cursorBundleIds: [cursor],
                                             deepLinkTemplate: template, isDirectory: { _ in false }), [.activateApp(bundleId: cursor)])
        XCTAssertEqual(SessionNavigator.plan(for: session(entry: "claude-vscode", host: nil), cursorBundleIds: [cursor],
                                             deepLinkTemplate: template, isDirectory: { _ in true }), [.activateApp(bundleId: cursor)])
        XCTAssertEqual(SessionNavigator.plan(for: session(entry: "claude-vscode", host: cursor, root: nil, cwd: "/w/api/sub"), cursorBundleIds: [cursor],
                                             deepLinkTemplate: template, isDirectory: { _ in true }), [.activateApp(bundleId: cursor)])
    }

    func testCliSessionNeverGetsTheExtensionDeepLink() {
        let inCursor = SessionNavigator.plan(for: session(entry: "cli", host: cursor), cursorBundleIds: [cursor], deepLinkTemplate: template, isDirectory: { _ in true })
        XCTAssertEqual(inCursor, [.focusFolder(path: "/w/api", bundleId: cursor)])
        let iterm = SessionNavigator.plan(for: session(entry: "cli", host: "com.googlecode.iterm2"), cursorBundleIds: [cursor], deepLinkTemplate: template, isDirectory: { _ in true })
        XCTAssertEqual(iterm, [.activateApp(bundleId: "com.googlecode.iterm2")])
        XCTAssertEqual(SessionNavigator.plan(for: session(entry: "sdk-ts", host: nil), cursorBundleIds: [cursor], deepLinkTemplate: template, isDirectory: { _ in true }), [])
    }

    func testNonCursorHostAndUnknownEntrypointNeverGetCursorDeepLink() {   // review M1
        let vs = SessionNavigator.plan(for: session(entry: "claude-vscode", host: "com.microsoft.VSCode"), cursorBundleIds: [cursor], deepLinkTemplate: template, isDirectory: { _ in true })
        XCTAssertEqual(vs, [.focusFolder(path: "/w/api", bundleId: "com.microsoft.VSCode")])
        let unk = SessionNavigator.plan(for: session(entry: nil, host: cursor), cursorBundleIds: [cursor], deepLinkTemplate: template, isDirectory: { _ in true })
        XCTAssertEqual(unk, [.focusFolder(path: "/w/api", bundleId: cursor)])
    }
    func testHostileSessionIdCannotAddLinkParameters() {   // review L4
        let s = session("x&prompt=rm", entry: "claude-vscode", host: cursor)
        let steps = SessionNavigator.plan(for: s, cursorBundleIds: [cursor], deepLinkTemplate: template, isDirectory: { _ in true })
        XCTAssertEqual(steps.last, .openURL(URL(string: "cursor://anthropic.claude-code/open?session=x%26prompt%3Drm")!))
    }
    func testSourceLabelsComeOnlyFromReportedFields() {
        XCTAssertEqual(RowFormat.sourceLabel(session(entry: "claude-vscode", host: cursor)), "Claude Code · Cursor extension")
        XCTAssertEqual(RowFormat.sourceLabel(session(entry: "cli", host: cursor)), "Claude Code CLI · Cursor terminal")
        XCTAssertEqual(RowFormat.sourceLabel(session(entry: "cli", host: "Apple_Terminal")), "Claude Code CLI · Terminal")
        XCTAssertEqual(RowFormat.sourceLabel(session(entry: nil, host: nil)), "Claude Code · unknown host")
        XCTAssertEqual(RowFormat.sourceLabel(session(entry: "sdk-py", host: nil)), "Claude Code headless (sdk-py)")
    }

    func testSameNameSessionsGetDistinctShortIds() {
        let a = session("aaaaaa11-x", entry: "claude-vscode", host: cursor), b = session("bbbbbb22-y", entry: "claude-vscode", host: cursor)
        XCTAssertEqual(RowFormat.title(a), RowFormat.title(b))
        XCTAssertNotEqual(RowFormat.shortId(a), RowFormat.shortId(b))
        XCTAssertEqual(RowFormat.shortId(a), "#aaaaaa")
    }

    func testSessionStartCwdIsAuthoritativeAndTitleNeverWakesQuiet() {
        let t = Date(timeIntervalSince1970: 100)
        var s = Reducer.apply(nil, AgentEvent(sessionId: "s", kind: .hook(.preToolUse), ts: t, cwd: "/w/api/sub"))
        s = Reducer.apply(s, AgentEvent(sessionId: "s", kind: .hook(.sessionStart), ts: t.addingTimeInterval(1), cwd: "/w/api"))
        XCTAssertEqual(s.workspaceRoot, "/w/api")
        s.state = .quiet
        var title = AgentEvent(sessionId: "s", kind: .transcriptTitle, ts: t.addingTimeInterval(9999)); title.text = "Fix pool leak"
        s = Reducer.apply(s, title)
        XCTAssertEqual(s.state, .quiet); XCTAssertEqual(s.title, "Fix pool leak"); XCTAssertEqual(s.lastEventAt, t.addingTimeInterval(1))
    }
    func testReducerKeepsFirstWorkspaceRootAcrossCwdChanges() {
        let t = Date(timeIntervalSince1970: 100)
        var s = Reducer.apply(nil, AgentEvent(sessionId: "s", kind: .hook(.sessionStart), ts: t, cwd: "/w/api"))
        s = Reducer.apply(s, AgentEvent(sessionId: "s", kind: .hook(.preToolUse), ts: t.addingTimeInterval(1), cwd: "/private/tmp/scratch"))
        XCTAssertEqual(s.workspaceRoot, "/w/api")
        XCTAssertEqual(s.cwd, "/private/tmp/scratch")
    }
}

final class WorkspaceResolverTests: XCTestCase {
    let cursor = "com.todesktop.230313mzl4w4u92"
    private func cand(_ f: String, _ folders: [String], _ t: Double) -> WorkspaceCandidate {
        WorkspaceCandidate(workspaceFilePath: f, folders: folders, lastUsed: Date(timeIntervalSince1970: t))
    }
    func testExactMatchNoPrefixMatchAndNil() {
        let c = [cand("/w/x.code-workspace", ["/a/bc"], 1), cand("/w/y.code-workspace", ["/a/b/"], 2)]
        XCTAssertEqual(WorkspaceResolver.target(forRoot: "/a/b", candidates: c), "/w/y.code-workspace")
        XCTAssertNil(WorkspaceResolver.target(forRoot: "/a/b", candidates: [c[0]]))
        XCTAssertNil(WorkspaceResolver.target(forRoot: "/a/b", candidates: []))
    }
    func testTieBrokenByRecency() {
        let c = [cand("/w/old", ["/a/b"], 1), cand("/w/new", ["/a/b"], 5), cand("/w/mid", ["/a/b"], 3)]
        XCTAssertEqual(WorkspaceResolver.target(forRoot: "/a/b", candidates: c), "/w/new")
    }
    func testJSONCStripperAndRelativeFolders() {
        let text = """
        {
          // comment
          "folders": [
            { "path": "../api" }, /* block */
            { "path": "/abs/url//x", },
          ],
          "settings": { "a": "http://x", },
        }
        """
        XCTAssertEqual(WorkspaceResolver.folders(inWorkspaceFile: text, baseDir: "/w/dir"), ["/w/api", "/abs/url/x"])
        XCTAssertNil(WorkspaceResolver.folders(inWorkspaceFile: "{ nope", baseDir: "/w"))
    }
    func testPlanUsesWorkspaceWhenGivenElseFocusFolder() {
        let s = Session(id: "abc", project: "api", cwd: "/w/api", workspaceRoot: "/w/api", host: cursor, entrypoint: "claude-vscode",
                        startedAt: Date(timeIntervalSince1970: 0), lastEventAt: Date(timeIntervalSince1970: 0))
        let t = CapabilityMatrix.defaultDeepLink
        let with = SessionNavigator.plan(for: s, cursorBundleIds: [cursor], deepLinkTemplate: t, isDirectory: { _ in true }, workspaceFor: { _ in "/w/r.code-workspace" })
        XCTAssertEqual(with.first, .openWorkspace(path: "/w/r.code-workspace", bundleId: cursor))
        XCTAssertEqual(with.count, 2)
        let without = SessionNavigator.plan(for: s, cursorBundleIds: [cursor], deepLinkTemplate: t, isDirectory: { _ in true })
        XCTAssertEqual(without.first, .focusFolder(path: "/w/api", bundleId: cursor))
    }
}
