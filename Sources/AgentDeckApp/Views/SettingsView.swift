import AppKit
import ServiceManagement
import SwiftUI
import AgentDeckCore

struct SettingsView: View {
    @ObservedObject var model: DeckModel
    @State private var bundleText = ""
    @State private var loginError: String?

    private func bind<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: kp] }, set: { v in model.update { $0[keyPath: kp] = v } })
    }

    var body: some View {
        Form {
            Section("Setup & Help") {
                Button("Setup & Help…") { model.openSetupHelp() }
                if let status = model.setupStatus {
                    Text(status).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(status)
                }
                Button("Install or repair hooks…") { model.installHooks() }
                    .disabled(model.installingHooks)
                Text("Installs hooks for this macOS user and backs up changed Claude settings. Restart Claude Code tabs afterward.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cursor") {
                TextField("Cursor bundle ids (comma separated)", text: $bundleText)
                    .onAppear { bundleText = model.settings.cursorBundleIds.joined(separator: ", ") }
                    .onChange(of: bundleText) { _, t in
                        let ids = SettingsFormat.parseBundleIds(t, fallback: AppSettings().cursorBundleIds)
                        model.update { $0.cursorBundleIds = ids }
                    }
                Toggle("Also supervise other hosts", isOn: bind(\.gateOtherHosts))
            }
            Section("Behaviour") {
                Toggle("Open on hover", isOn: bind(\.hoverToOpen))
                Text("Off: click the pill to open. Drag to move. Attention sounds and the needs-you label still work.").font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { model.settings.awayThresholdSeconds },
                                       set: { v in model.update { $0.awayThresholdSeconds = SettingsFormat.clampAway(v) } }),
                        in: SettingsFormat.awayRange, step: 5) { Text("Away after \(Int(model.settings.awayThresholdSeconds)) s idle") }
                Picker("Gate scope", selection: bind(\.gateScope)) {
                    Text("Automatic").tag(GateScope.automatic); Text("Full").tag(GateScope.full); Text("Risky only").tag(GateScope.riskyOnly)
                }
                Toggle("Hide when idle", isOn: bind(\.hideWhenIdle))
                Toggle("Sounds", isOn: bind(\.sounds))
                Toggle("Summarizer (off by default)", isOn: bind(\.summarizer))
                Text("Sends the last assistant message of a finished turn to claude -p (Haiku). Network use. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: Binding(get: { model.settings.launchAtLogin }, set: setLaunchAtLogin))
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("Sources") {
                Text("Sources tracked: Claude Code via hooks (Cursor extension, CLI). Codex and other agents are not tracked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hotkeys (must include Control)") {
                ForEach(HotkeyAction.allCases, id: \.self) { HotkeyRow(model: model, action: $0) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            model.update { $0.launchAtLogin = on }; loginError = nil
        } catch { loginError = "Launch at login failed: \(error.localizedDescription)" }   // toggle stays at its old value
    }
}

private struct HotkeyRow: View {
    @ObservedObject var model: DeckModel
    let action: HotkeyAction
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(action.rawValue); Spacer()
                Button(recording ? "Press keys…" : HotkeyLabel.text(model.hotkeyConfig[action])) { recording ? stop() : start() }
            }
            if let e = error ?? model.hotkeyFailures[action].map({ "Registration failed (status \($0)); another app may own it" }) {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        error = nil; recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Escape cancels
            let f = e.modifierFlags
            let mods = HotkeyConfig.carbonModifiers(control: f.contains(.control), option: f.contains(.option),
                                                    command: f.contains(.command), shift: f.contains(.shift))
            error = model.rebind(action, to: Hotkey(keyCode: UInt32(e.keyCode), modifiers: mods))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
