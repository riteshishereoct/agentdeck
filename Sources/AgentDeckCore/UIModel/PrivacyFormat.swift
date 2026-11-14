import Foundation

public enum PrivacyFormat {
    public static func pill(_ sessions: [Session]) -> String { PillSummary.make(sessions).text }
    public static func row(index: Int, session: Session) -> String {
        if let r = session.pending.filter({ $0.status == .pending }).min(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            return "Session \(index) needs approval · \(CardFormat.displayTool(r.tool))"
        }
        let state: String
        switch session.state {
        case .yourTurn: state = "your turn"
        case .waitingInCursor: state = "waiting in Cursor ↗"
        case .needsYou: state = "needs you"
        default: state = session.state.rawValue
        }
        return "Session \(index) \(state)"
    }
}
