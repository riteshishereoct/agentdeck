import Foundation

/// UI-only wording for why a hold is required and why a card action was dropped. Decides nothing.
public enum HoldReason {
    public static func text(risk: RiskLevel, context: ConsentContext?, broadRule: Bool = false) -> String {
        if risk == .high { return "High risk" }
        if context?.overflows == true { return "Long command: not all of it fits on the card" }
        if context?.incomplete == true { return "Part of the request is not shown on the card" }
        if broadRule { return "Broad rule: lasts beyond this request" }
        return "Confirm with a deliberate hold"   // unreachable unless callers disagree with CardLayout; never claim a risk level we did not compute
    }

    public static func dropText(_ why: CardDrop) -> String {
        switch why {
        case .noCard, .staleCard, .notApplicable: return "Already resolved or expired"
        case .notArmed: return "Not ready: card was not fully visible"
        case .needsHold, .highRiskHotkey: return "Needs a hold"
        case .personOnly: return "Only you can decide this"
        case .noteOpen: return "Close the note first"
        }
    }

    public static let releasedEarly = "Keep holding for 1 s"
    public static let notReady = "Not ready: keep the card fully visible"
}
