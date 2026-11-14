import AppKit
import SwiftUI
import AgentDeckCore

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func require(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { print("FAIL: " + message); exit(1) }
}
let home = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("home")
let paths = AppPaths.live(home: home)
let defaults = UserDefaults(suiteName: "AgentDeckOnboardingCheck.\(UUID().uuidString)")!
let store = SettingsStore(defaults: defaults)
let model = DeckModel(daemon: Daemon(paths: paths, settings: store.load()), settingsStore: store, logURL: paths.logFile)
let panel = PanelController(model: model)
let controller = MenubarController(model: model, panel: panel)
let item = Mirror(reflecting: controller).children.first { $0.label == "item" }?.value as? NSStatusItem
require(model.sessions.isEmpty, "fixture must have no sessions")
let menu = item?.menu
for title in ["Setup & Help…", "Install or repair hooks…"] {
    require(menu?.items.contains { $0.title == title && $0.target != nil && $0.action != nil && $0.isEnabled } == true,
            "no-session menu cannot reach " + title)
}
model.installHooks()
let end = Date().addingTimeInterval(3)
while model.installingHooks && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
require(!model.installingHooks && model.setupStatus?.contains("Bundled installer") == true,
        "no-session install failure has no visible recovery status")
require(Bundle.main.url(forResource: "AgentDeck-Guide", withExtension: "html") != nil, "offline guide missing from package")
print("PASS: no-session menu exposes setup and repair; offline guide bundled")
