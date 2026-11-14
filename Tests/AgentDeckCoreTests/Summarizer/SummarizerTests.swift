import XCTest
@testable import AgentDeckCore

private final class FakeRunner: SummarizerRunner {
    var prompts: [String] = []; var pending: [(String?) -> Void] = []
    func run(prompt: String, completion: @escaping (String?) -> Void) { prompts.append(prompt); pending.append(completion) }
    func finish(_ s: String?) { pending.removeFirst()(s) }
}

final class SummarizerTests: XCTestCase {
    private let clock = FakeClock(); private let runner = FakeRunner()
    private lazy var sum: Summarizer = { let s = Summarizer(runner: runner, clock: clock); s.enabled = true; return s }()
    private func session(_ id: String = "s1") -> Session {
        Session(id: id, goal: "Fix the S3 pool leak", latestAsk: "add tests", currentStep: Step(label: "Bash: rm SECRET-CMD", tool: "Bash", startedAt: Make.t0),
                summary: "Added index.", startedAt: Make.t0, lastEventAt: Make.t0)
    }
    private func ask(_ s: Session) -> String?? { var out: String??; sum.request(session: s) { out = .some($0) }; return out }

    func testDisabledByDefaultNeverCallsTheRunner() {
        let s = Summarizer(runner: runner, clock: clock); var got: String? = "unset"
        s.request(session: session()) { got = $0 }
        XCTAssertNil(got); XCTAssertTrue(runner.prompts.isEmpty)
    }
    func testPromptUsesGoalAskAndSummaryButNeverTheStepLabel() {
        _ = ask(session()); XCTAssertEqual(runner.prompts.count, 1)
        let p = runner.prompts[0]; XCTAssertTrue(p.contains("Fix the S3 pool leak")); XCTAssertTrue(p.contains("add tests")); XCTAssertTrue(p.contains("Added index."))
        XCTAssertFalse(p.contains("SECRET-CMD"))
    }
    func testResultIsTrimmedFirstLineCappedAt120AndCached() {
        var out: String?; sum.request(session: session()) { out = $0 }
        runner.finish("  Fixing the leak\nsecond line  "); XCTAssertEqual(out, "Fixing the leak")
        var long: String?; clock.advance(121); sum.request(session: session()) { long = $0 }; runner.finish(String(repeating: "z", count: 300)); XCTAssertEqual(long?.count, 120)
    }
    func testDebouncedToOnePerSessionPerTwoMinutesWithCachedAnswer() {
        var first: String?; sum.request(session: session()) { first = $0 }; runner.finish("Fixing the leak")
        clock.advance(119); var again: String?; sum.request(session: session()) { again = $0 }
        XCTAssertEqual(again, "Fixing the leak"); XCTAssertEqual(runner.prompts.count, 1)
        clock.advance(1); sum.request(session: session()) { _ in }; XCTAssertEqual(runner.prompts.count, 2)
        sum.request(session: session("other")) { _ in }; XCTAssertEqual(runner.prompts.count, 3)   // per session
        XCTAssertEqual(first, "Fixing the leak")
    }
    func testFailureIsAlsoDebouncedAndInFlightRequestsDoNotStartASecondRun() {
        sum.request(session: session()) { _ in }
        var during: String? = "unset"; sum.request(session: session()) { during = $0 }; XCTAssertNil(during); XCTAssertEqual(runner.prompts.count, 1)
        runner.finish(nil)
        clock.advance(30); var after: String? = "unset"; sum.request(session: session()) { after = $0 }; XCTAssertNil(after); XCTAssertEqual(runner.prompts.count, 1)
    }
    func testLiveRunnerCommandAndEnvironment() {
        XCTAssertEqual(LiveSummarizerRunner.arguments, ["-p", "--model", "claude-haiku-5-5", "--settings", #"{"disableAllHooks":true}"#])
        let env = LiveSummarizerRunner.environment(base: ["PATH": "/usr/bin"]); XCTAssertEqual(env["ADECK_NESTED"], "1"); XCTAssertEqual(env["PATH"], "/usr/bin")
    }
    func testLiveRunnerWithAMissingExecutableCompletesNilWithoutRunningAnything() {
        let done = expectation(description: "completion"); let r = LiveSummarizerRunner(executable: "/nonexistent/claude", callbackQueue: .main)
        r.run(prompt: "x") { XCTAssertNil($0); done.fulfill() }
        wait(for: [done], timeout: 2)
    }
}
