import XCTest
@testable import AgentDeckCore

final class SessionStoreTests: XCTestCase {
    private func ev(_ k: HookKind, _ s: String, at: TimeInterval) -> AgentEvent { Make.event(.hook(k), session: s, at: Make.t(at)) }

    func testSessionsAreIndependentAndTickDoesNotCreateOne() {
        let st = SessionStore(); st.apply(ev(.userPromptSubmit, "a", at: 0)); st.apply(ev(.sessionStart, "b", at: 0))
        st.apply(Make.event(.tick, session: "", at: Make.t(1)))
        XCTAssertEqual(Set(st.sessions.keys), ["a", "b"]); XCTAssertEqual(st.sessions["a"]?.state, .working); XCTAssertEqual(st.sessions["b"]?.state, .idle)
    }
    func testEndedSessionRemovedExactly120sAfterEnd() {
        let st = SessionStore(); st.apply(ev(.userPromptSubmit, "a", at: 0)); st.apply(ev(.sessionEnd, "a", at: 10))
        st.apply(Make.event(.tick, session: "", at: Make.t(129.9))); XCTAssertNotNil(st.sessions["a"])
        st.apply(Make.event(.tick, session: "", at: Make.t(130))); XCTAssertNil(st.sessions["a"])
    }
    func testMissingSessionEndIsCoveredByPidGone() {
        let st = SessionStore(); st.apply(ev(.userPromptSubmit, "a", at: 0)); st.apply(Make.event(.pidGone, session: "a", at: Make.t(50)))
        XCTAssertEqual(st.sessions["a"]?.state, .ended)
    }
    func testOrderedNeedsYouFirstThenNewestThenId() {
        let st = SessionStore()
        st.apply(ev(.userPromptSubmit, "old", at: 0)); st.apply(ev(.userPromptSubmit, "new", at: 20)); st.apply(ev(.userPromptSubmit, "tie", at: 20))
        st.apply(ev(.userPromptSubmit, "ask", at: 5)); st.apply(Make.event(.requestHeld(Make.request("r", session: "ask")), session: "ask", at: Make.t(6)))
        XCTAssertEqual(st.ordered.map(\.id), ["ask", "new", "tie", "old"])
    }
    func testRestoreSeedsSessions() {
        let st = SessionStore(); st.restore([Session(id: "x", startedAt: Make.t0, lastEventAt: Make.t0)])
        XCTAssertEqual(st.sessions["x"]?.state, .idle)
    }
}
