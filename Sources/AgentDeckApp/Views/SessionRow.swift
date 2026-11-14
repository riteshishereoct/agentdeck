import SwiftUI
import AgentDeckCore

struct SessionRow: View {
    let session: Session
    /// Navigation only: never approves, denies or answers.
    let onOpen: () -> Void
    let onCheckHooks: () -> Void
    let onRepairHooks: (@escaping (Bool) -> Void) -> Void
    @State private var repairResult: String?

    // No per-second re-render: the step line uses absolute clock times (G-NOW, battery).
    var body: some View { content(now: Date()) }

    private func content(now: Date) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Button(action: onOpen) { Text(RowFormat.title(session)).font(.callout).lineLimit(2).multilineTextAlignment(.leading) }
                        .buttonStyle(.plain).help("Open session").accessibilityLabel(openLabel)
                    Spacer()
                    if let m = RowFormat.modelLabel(session.model) { Text(m).font(.caption2).foregroundStyle(.secondary) }
                }
                Text("\(RowFormat.sourceLabel(session)) · \(RowFormat.shortId(session))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text([RowFormat.stateText(session, now: now), RowFormat.stepLine(session, now: now)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch RowDetail.progress(session) {
                case .bar(let done, let total):
                    ProgressView(value: Double(min(total, max(0, done))), total: Double(total))
                        .accessibilityLabel("Task progress").accessibilityValue("\(done) of \(total)")
                    Text("\(done)/\(total) tasks").font(.caption2).foregroundStyle(.secondary)
                case .steps(let count, let spark):
                    Text("\(count) steps · \(spark)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        .accessibilityLabel("\(count) steps, recent activity chart")
                }
                if let summary = session.summary { Text(summary).font(.caption).lineLimit(2) }
                if let line = RowDetail.subagentLine(session) { Text(line).font(.caption2).lineLimit(2) }
                HookHealthView(session: session, check: onCheckHooks, repair: {
                    repairResult = nil
                    onRepairHooks { ok in
                        repairResult = ok ? "Hooks installed; waiting for a fresh tool event to confirm connection."
                                          : "Hook repair could not finish. Check macOS permissions and try Repair hooks again."
                    }
                })
                if let repairResult { Text(repairResult).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Button("Open session ↗", action: onOpen).font(.caption).accessibilityLabel(openLabel)
            }

    }

    /// Distinct per row so VoiceOver can tell same-named sessions apart.
    private var openLabel: String { "Open session \(RowFormat.title(session)) \(RowFormat.shortId(session))" }

    private var dot: Color {
        switch session.state {
        case .needsYou: return .orange
        case .error: return .red
        case .yourTurn: return .green
        case .working: return .blue
        default: return .gray
        }
    }
}
