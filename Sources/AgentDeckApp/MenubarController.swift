import AppKit
import Combine
import SwiftUI
import AgentDeckCore

final class MenubarController: NSObject, NSMenuDelegate {
    private let model: DeckModel
    private let panel: PanelController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var toggles: [(NSMenuItem, KeyPath<AppSettings, Bool>)] = []
    private var settingsWindow: NSWindow?
    private var summary: NSMenuItem?
    private var showHideItem: NSMenuItem?
    private var bag = Set<AnyCancellable>()

    init(model: DeckModel, panel: PanelController) {
        self.model = model; self.panel = panel
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "AgentDeck")
        item.button?.imagePosition = .imageLeading
        item.menu = buildMenu()
        model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshBadge() } }.store(in: &bag)
        refreshBadge()
    }

    func refreshBadge() { item.button?.title = MenubarFormat.badge(pending: model.queue.ordered.count) }

    private func buildMenu() -> NSMenu {
        let m = NSMenu(); m.delegate = self
        func add(_ title: String, _ sel: Selector) { let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; m.addItem(i) }
        func toggle(_ title: String, _ kp: KeyPath<AppSettings, Bool>, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; m.addItem(i); toggles.append((i, kp))
        }
        let summary = NSMenuItem(title: "", action: nil, keyEquivalent: ""); summary.isEnabled = false; m.addItem(summary); self.summary = summary
        add("Show", #selector(showHide)); showHideItem = m.items.last
        m.addItem(.separator())
        toggle("Away mode", \.awayMode, #selector(toggleAway))
        toggle("Quiet", \.quiet, #selector(toggleQuiet))
        toggle("Privacy", \.privacy, #selector(togglePrivacy))
        toggle("Pause AgentDeck", \.paused, #selector(togglePause))
        m.addItem(.separator())
        add("Settings…", #selector(openSettings))
        add("Setup & Help…", #selector(openSetupHelp))
        add("Install or repair hooks…", #selector(installHooks))
        add("Reload capabilities", #selector(reload))
        m.addItem(.separator())
        add("Quit", #selector(quit))
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        summary?.title = PillSummary.make(model.sessions).text
        showHideItem?.title = model.panelVisible ? "Hide" : "Show"
        for (i, kp) in toggles { i.state = model.settings[keyPath: kp] ? .on : .off }
    }

    @objc private func showHide() { model.toggleVisible() }
    @objc private func toggleAway() { model.update { $0.awayMode.toggle() } }
    @objc private func toggleQuiet() { model.update { $0.quiet.toggle() } }
    @objc private func togglePrivacy() { model.update { $0.privacy.toggle() } }
    @objc private func togglePause() { model.update { $0.paused.toggle() } }
    @objc private func openSetupHelp() { openSettings(); model.openSetupHelp() }
    @objc private func installHooks() { openSettings(); model.installHooks() }
    @objc private func reload() { model.daemon.reloadMatrix() }
    @objc private func quit() { model.daemon.stop(); NSApp.terminate(nil) }

    // An explicit user action, so bringing the settings window to the front is fine.
    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AgentDeck Settings"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center(); settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
