import AppKit
import AgentDeckCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    private(set) var daemon: Daemon!
    var presence: PresenceMonitor!
    var model: DeckModel!
    var panel: PanelController!
    var hotkeys: HotkeyCenter!
    var menubar: MenubarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        daemon = Daemon(paths: .live(), settings: settingsStore.load())
        daemon.hookSource = Bundle.main.resourceURL?.appendingPathComponent("AgentDeck", isDirectory: true)
        do {
            try daemon.start()
        } catch DaemonError.alreadyRunning {
            fatalAlert("AgentDeck is already running")
        } catch DaemonError.socketPathTooLong(let n) {
            fatalAlert("Socket path is \(n) bytes; the limit is 103")
        } catch {
            fatalAlert(String(describing: error))
        }
        model = DeckModel(daemon: daemon, settingsStore: settingsStore)
        panel = PanelController(model: model)
        hotkeys = HotkeyCenter { [weak self] in self?.model.handle($0) }
        model.hotkeys = hotkeys
        model.applyHotkeys()
        menubar = MenubarController(model: model, panel: panel)
        presence = PresenceMonitor(daemon: daemon) { [weak self] in self?.model.snapshot = $0 }
        presence.start()
        model.tick()    // first visibility decision: stays hidden when nothing is active
    }

    func applicationWillTerminate(_ notification: Notification) { presence?.stop(); daemon?.stop() }

    // Startup alerts may activate the app: acceptable, nothing is being typed at launch.
    private func fatalAlert(_ text: String) {
        let a = NSAlert(); a.messageText = text; a.runModal()
        NSApp.terminate(nil)
    }
}
