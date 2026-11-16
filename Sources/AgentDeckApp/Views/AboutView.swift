import SwiftUI
import AppKit
import AgentDeckCore

struct AboutView: View {
    @ObservedObject var model: DeckModel

    private var info: AboutInfo {
        AboutInfo(info: Bundle.main.infoDictionary,
                  hooks: AboutInfo.hooksSummary(sessions: model.sessions.count, degraded: model.sessions.filter { $0.hookHealth.degraded }.count),
                  socketPath: AppPaths.live().socket.path, home: NSHomeDirectory())
    }

    var body: some View {
        let info = info
        VStack(spacing: 12) {
            // The bundle ships no icon, so the companion is the face of the app (static frame: no animation cost).
            CompanionView(style: .pet, mood: .happy, animated: false, size: 72).frame(width: 72, height: 72).accessibilityHidden(true)
            Text("AgentDeck").font(.title2.bold())
            Text(info.versionLine).font(.callout).foregroundStyle(.secondary)
            Text("A floating deck that keeps every Claude Code session in view.")
                .font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Hooks", info.hooks)
                row("Socket", info.displaySocket)
                row("Requirements", AboutInfo.requirements)
                row("Signing", AboutInfo.signing)
                row("License", AboutInfo.license)
            }
            .font(.callout)
            HStack {
                Button("GitHub") { open(URL(string: "https://github.com/riteshishereoct/agentdeck")) }
                Button("Guide") {
                    open(Bundle.main.url(forResource: "AgentDeck-Guide", withExtension: "html")
                         ?? URL(string: "https://riteshishereoct.github.io/agentdeck/"))
                }
                Button("Copy details") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info.details, forType: .string)
                }
            }
            Text("Preview build. Memory target (≤60 MiB peak RSS) not met; see README.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 390)
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func open(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }
}
