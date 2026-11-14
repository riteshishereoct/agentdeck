import SwiftUI
import AgentDeckCore

/// Recovery controls only: these never resolve a pending request or navigate to its conversation.
struct HookHealthView: View {
    let session: Session
    let check: () -> Void
    let repair: () -> Void

    var body: some View {
        if let explanation = RowDetail.hookHealthLine(session) {
            VStack(alignment: .leading, spacing: 4) {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if session.hookHealth.offersRetry {
                        Button("Check connection", action: check)
                            .accessibilityLabel("Check hook connection for session " + RowFormat.shortId(session))
                    }
                    if session.hookHealth.offersRepair {
                        Button("Repair hooks", action: repair)
                            .accessibilityLabel("Repair AgentDeck hook installation")
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
    }
}
