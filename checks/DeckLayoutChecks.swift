import AppKit
import SwiftUI
import AgentDeckCore
import Combine

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let home = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("home")
let paths = AppPaths.live(home: home)
let defaults = UserDefaults(suiteName: "AgentDeckHostedCheck.\(UUID().uuidString)")!
let settings = SettingsStore(defaults: defaults)
let model = DeckModel(daemon: Daemon(paths: paths, settings: settings.load()), settingsStore: settings, logURL: paths.logFile)
model.panelVisible = true; model.expanded = true; model.pinned = true
model.panelWidth = 440; model.maxPanelHeight = 600
let now = Date()
let request = Request(id: "layout-check", sessionId: "session", kind: .permission, hook: .permissionRequest, tool: "Bash", preview: "echo layout",
                      fullInput: .object(["command": .string("echo layout"), "description": .string("Check layout")]), risk: Risk(level: .low, reason: "Routine action"), channel: .race, createdAt: now)
model.sessions = [Session(id: "session", project: "layout", cwd: "/private/tmp", title: "Layout probe", state: .needsYou, pending: [request], startedAt: now, lastEventAt: now)]
model.tick()
let host = NSHostingView(rootView: DeckView(model: model))
let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 440, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = host
func run(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL: " + message); exit(1) }
}
func measure(_ size: CGSize) {
    model.panelWidth = size.width; model.maxPanelHeight = size.height
    window.setContentSize(size); run(0.15)
    window.setContentSize(host.fittingSize); run(0.75)
}
func scrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
}
func scrollBodyToEnd() {
    // The request body has the largest overflowing vertical viewport; the list is separate and short in this fixture.
    let candidates = scrollViews(host).filter {
        guard let doc = $0.documentView else { return false }
        return doc.frame.height > $0.contentView.bounds.height + 1 && $0.contentView.bounds.height > 20
    }
    guard let scroll = candidates.max(by: { $0.contentView.bounds.height < $1.contentView.bounds.height }), let doc = scroll.documentView else {
        print("FAIL: overflowing request has no reachable native vertical scroll view"); exit(1)
    }
    let end = max(0, doc.frame.height - scroll.contentView.bounds.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? end : 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    run(0.8)
}
func textFields(_ view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(textFields)
}
/// Real key events into the focused field editor, with run-loop turns (ticks, re-renders, refits) between them.
func type(_ text: String) {
    for ch in text {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                              charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)!)
        }
        run(0.01)
    }
}
func focusOnlyField() {
    let fields = textFields(host)
    require(fields.count == 1, "expected exactly one editable field, found \(fields.count)")
    _ = window.makeFirstResponder(fields[0]); run(0.1)
}
// Mirrors PanelController: every model publish refits the window to the hosting view's fitting size on the next main-queue turn.
var refits = 0
let refitSink = model.objectWillChange.sink { _ in
    DispatchQueue.main.async { refits += 1; let f = host.fittingSize; if f != window.frame.size { window.setContentSize(f) } }
}
let clickModel = DeckModel(daemon: Daemon(paths: paths, settings: settings.load()), settingsStore: settings, logURL: paths.logFile)
clickModel.sessions = model.sessions
clickModel.tick()
require(!clickModel.expanded, "click mode auto-expands a new pending request")
require(PillSummary.make(clickModel.sessions).text.contains("needs you"), "collapsed attention label lost")
clickModel.pointer(inside: true); run(0.5)
require(!clickModel.expanded, "click mode opens on hover")
clickModel.update { $0.hoverToOpen = true }
clickModel.pointer(inside: false); clickModel.pointer(inside: true); run(0.5)
require(clickModel.expanded, "hover mode cannot be enabled")
clickModel.collapsePanel(); run(0.5)
require(!clickModel.expanded, "explicit collapse reopens under a stationary pointer")
clickModel.pillInteraction(began: true); run(0.5)
clickModel.pillInteraction(began: false); run(0.5)
require(!clickModel.expanded, "drag release reopens hover mode")
clickModel.pillInteraction(began: true); clickModel.pillInteraction(began: false, activate: true)
require(clickModel.expanded && clickModel.pinned, "deliberate click cannot open")
require(clickModel.queue.showingTop?.id == request.id, "deliberate click does not immediately expose pending card")
clickModel.collapsePanel(); clickModel.handle(.toggleExpand)
require(clickModel.queue.showingTop?.id == request.id, "hotkey opening does not immediately expose pending card")
clickModel.settings.hoverToOpen = false
clickModel.panelVisible = false
require(!clickModel.expanded && !clickModel.pinned, "hidden click-mode panel retains expansion for the next request")
clickModel.panelVisible = true; clickModel.tick()
require(!clickModel.expanded, "showing a hidden click-mode panel opens old expanded content")
print("PASS click mode: arrivals and hover stay collapsed; attention summary retained; hover override works")
let dragView = PillHitView(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
let dragWindow = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 180, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
dragWindow.contentView = dragView
var activations: [Bool] = []
dragView.onInteraction = { began, activate in if !began { activations.append(activate) } }
func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: dragWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
func nativeRelease(moved: Bool) {
    app.postEvent(mouse(.leftMouseUp, CGPoint(x: 30, y: 10)), atStart: true)
    // AppKit normalizes posted mouse coordinates; match the delivered event, not the pre-post coordinates.
    guard let release = app.nextEvent(matching: .leftMouseUp, until: Date.distantFuture, inMode: .default, dequeue: false) else { fatalError("missing release") }
    let start = release.locationInWindow.applying(CGAffineTransform(translationX: moved ? -20 : 0, y: 0))
    dragView.mouseDown(with: mouse(.leftMouseDown, start))
}
let originBeforeDrag = dragWindow.frame.origin
nativeRelease(moved: true)
require(activations == [false], "fast moved release activates or starts native drag after release")
require(dragWindow.frame.origin != originBeforeDrag, "native moved release does not move the pill")
nativeRelease(moved: false)
require(activations == [false, true], "deliberate native pill click does not activate")
let idleModel = DeckModel(daemon: Daemon(paths: paths, settings: settings.load()), settingsStore: settings, logURL: paths.logFile)
idleModel.settings.hoverToOpen = false
idleModel.showPanel = { idleModel.panelVisible = true }
idleModel.hidePanel = { idleModel.panelVisible = false }
idleModel.pointer(inside: true); idleModel.tick()
idleModel.pointer(inside: false)
require(!idleModel.panelVisible, "click-mode idle panel stays visible after pointer exits")
print("PASS native pill mouse sequence: fast moved release never opens; click opens; idle pointer-exit hides")
let gripView = GripNSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
dragWindow.contentView = gripView
var gripDelta = CGVector.zero
gripView.onDrag = { phase, delta in if phase == .changed { gripDelta = delta } }
gripView.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 10)))
gripView.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 30, y: 40)))
gripView.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 30, y: 40)))
require(gripDelta == CGVector(dx: 20, dy: 30), "resize ignores delivered event coordinates")
print("PASS native resize: uses delivered event displacement")
measure(CGSize(width: 704, height: 848))
// Live 10:28Z: a one-line card left ~480 pt blank above its buttons in a 704x848 panel.
require(host.fittingSize.height < 848 - 300, "short card does not hug its content: fit=\(host.fittingSize)")
require(model.requestPresentation.reviewAtEnd.contains(request.id) && model.queue.isArmed, "short hugging card does not arm without scrolling")
print("PASS short card hugs content at 704x848: fit=\(host.fittingSize), armed without scrolling")
measure(CGSize(width: 440, height: 600))
require(host.fittingSize.height <= 600.1, "short card exceeds panel height")
require(model.requestPresentation.reviewAtEnd.contains(request.id), "visible short request is not recognized as reviewed")
require(model.queue.isArmed, "fully visible short request never arms")
print("PASS short card: fit=\(host.fittingSize), reviewed, armed")
let typed = "synthetic draft survives collapse, exactly: 0123456789 llama"
model.openNote(for: request.id); run(0.3)
focusOnlyField()
let refitsBefore = refits
type(typed); run(0.3)
require(textFields(host).first?.stringValue == typed, "note field lost characters while typing: \(textFields(host).first?.stringValue ?? "nil")")
require(refits - refitsBefore < typed.count / 2, "each note keystroke republishes the deck (\(refits - refitsBefore) refits)")
model.panelVisible = false; run(0.3)
require(!model.expanded && !model.pinned && model.noteFor == nil, "hiding retains expanded content or editor focus")
require(!model.queue.isArmed, "hiding retains approval arming")
require(model.requestPresentation.notes[request.id] == typed, "hiding loses the pending note draft")
model.panelVisible = true
require(!model.expanded, "reshow opens without a click")
model.expandPanel(); model.openNote(for: request.id); run(0.8)
require(textFields(host).first?.stringValue == typed, "explicit reopen after hide loses the exact draft")
print("PASS hide/reshow: stays collapsed until explicit open; hidden view/editor released, exact note retained and fresh arming")
model.collapseRequest(request.id); run(0.3)
require(model.noteFor == nil && textFields(host).isEmpty, "collapsed card keeps the note editor open")
require(model.requestPresentation.notes[request.id] == typed, "collapse loses or truncates note: \(model.requestPresentation.notes[request.id] ?? "nil")")
require(!model.queue.isArmed, "collapsed card remains armed")
require(model.queue.top?.id == request.id, "collapse resolves or changes request")
model.expandRequest(request.id)
require(!model.queue.isArmed, "reopen bypasses fresh arming")
run(0.8)
require(model.queue.isArmed, "reopened visible card never re-arms")
require(model.noteFor == request.id, "reopen does not restore the open note editor")
require(textFields(host).first?.stringValue == typed, "reopened note editor lost text: \(textFields(host).first?.stringValue ?? "nil")")
require(model.queue.perform(.deny(note: nil), renderedId: request.id, via: .hotkey) == .dropped(.noteOpen), "Deny hotkey would drop an open note draft")
model.closeNote(); run(0.3)
require(model.requestPresentation.notes[request.id] == typed, "Cancel loses the note draft")
print("PASS note draft: typed text exact through collapse/reopen, editor restored, Deny hotkey refused while it is open")
model.requestPresentation.notes[request.id] = nil
print("PASS collapse: disarmed, pending/draft preserved, reopened with fresh arming")
measure(CGSize(width: 320, height: 320))
require(host.fittingSize.height <= 320.1 && host.fittingSize.width <= 320.1, "minimum-size layout exceeds its bounds")
if !model.queue.isArmed { scrollBodyToEnd() }
require(model.queue.isArmed, "minimum-size card cannot arm after scrolling to end")
print("PASS minimum 320x320: content reachable, actions arm after review")
let long = Request(id: "long-layout", sessionId: "session", kind: .permission, hook: .permissionRequest, tool: "Bash", preview: "long",
                   fullInput: .object(["command": .string("echo layout"), "description": .string(String(repeating: "Explain this necessary step. ", count: 120))]),
                   risk: Risk(level: .low, reason: "Routine action"), channel: .race, createdAt: now)
model.sessions[0].pending = [long]; model.tick()
measure(CGSize(width: 440, height: 600))
require(!model.queue.isArmed, "long unread request arms before scrolling")
scrollBodyToEnd()
require(model.queue.isArmed, "long request cannot arm after scrolling to end")
require(host.fittingSize.height >= 600 - 0.5, "long card is not capped at the panel: fit=\(host.fittingSize)")
print("PASS long card: capped, unseen context disarmed; native scroll end permits fresh arming")
let questionText = "Which colour should the chart use?"
let question = Request(id: "question-layout", sessionId: "session", kind: .question, hook: .preToolUse, tool: "AskUserQuestion", preview: "question",
                       fullInput: .object(["questions": .array([.object(["question": .string(questionText), "header": .string("Colour"), "multiSelect": .bool(false),
                                                                           "options": .array([.object(["label": .string("Blue")]), .object(["label": .string("Green")])])])])]),
                       risk: Risk(level: .low, reason: "Question"), channel: .gate, createdAt: now)
model.sessions[0].pending = [question]; model.tick()
measure(CGSize(width: 704, height: 848))
require(host.fittingSize.height < 848 - 200, "short question card does not hug its content: fit=\(host.fittingSize)")
model.openQuestionInput(for: question.id); model.requestPresentation.editingOther[question.id] = [questionText]; run(0.3)
focusOnlyField()
let other = "teal, with a dark outline — not blue"
type(other); run(0.3)
require(textFields(host).first?.stringValue == other, "Other field lost characters while typing: \(textFields(host).first?.stringValue ?? "nil")")
model.collapseRequest(question.id); run(0.3)
require(model.requestPresentation.questions[question.id]?.other[questionText] == other, "collapse loses the Other answer")
model.expandRequest(question.id); run(0.8)
require(textFields(host).first?.stringValue == other, "reopened question lost its Other text: \(textFields(host).first?.stringValue ?? "nil")")
print("PASS question Other: typed text exact through collapse/reopen; short question card hugs content")
refitSink.cancel()
// Host the real controller without ordering its window: SwiftUI's intrinsic window resize must not move the chosen corner.
let anchorDefaults = UserDefaults(suiteName: "AgentDeckAnchorCheck.\(UUID().uuidString)")!
let anchorSettings = SettingsStore(defaults: anchorDefaults)
let anchorModel = DeckModel(daemon: Daemon(paths: paths, settings: anchorSettings.load()), settingsStore: anchorSettings, logURL: paths.logFile)
anchorModel.sessions = [Session(id: "anchor", project: "layout", cwd: "/private/tmp", state: .working, startedAt: now, lastEventAt: now)]
guard let screen = NSScreen.main, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { fatalError("no display") }
let visible = screen.visibleFrame
let box = CGRect(x: visible.maxX - 8 - 440, y: visible.maxY - 8 - 600, width: 440, height: 600)
let frameStore = FrameStore(defaults: anchorDefaults)
frameStore.save(box, displayKey: PanelGeometry.boxKey(SnapGeometry.displayKey(number.uint32Value)))
let previousWindows = Set(app.windows.map(\.windowNumber))
let controller = PanelController(model: anchorModel, frames: frameStore)
guard let anchorPanel = app.windows.first(where: { !previousWindows.contains($0.windowNumber) && $0 is OverlayPanel }) else { fatalError("no controller panel") }
anchorModel.panelVisible = true; controller.refit(); run(0.3)
let chosenCorner = CGPoint(x: anchorPanel.frame.maxX, y: anchorPanel.frame.maxY)
for _ in 0..<3 {
    anchorModel.expandPanel(); run(0.4); controller.refit(); run(0.1)
    require(abs(anchorPanel.frame.maxX - chosenCorner.x) < 1 && abs(anchorPanel.frame.maxY - chosenCorner.y) < 1, "expansion moves the saved corner")
    anchorModel.collapsePanel(); run(0.4); controller.refit(); run(0.1)
    require(abs(anchorPanel.frame.maxX - chosenCorner.x) < 1 && abs(anchorPanel.frame.maxY - chosenCorner.y) < 1, "collapse moves the saved corner")
    anchorModel.panelVisible = false; run(0.1); anchorModel.panelVisible = true; controller.refit(); run(0.1)
    require(abs(anchorPanel.frame.maxX - chosenCorner.x) < 1 && abs(anchorPanel.frame.maxY - chosenCorner.y) < 1, "hide/reshow moves the saved corner")
}
require(!anchorPanel.isVisible, "offscreen check ordered a real window")
print("PASS real panel controller: chosen corner stable across expansion, collapse and hide/reshow")
let nearPill = CGRect(x: visible.midX + 10, y: visible.maxY - 100, width: 200, height: 31)
let nearBox = PanelGeometry.userBox(shown: nearPill, user: CGSize(width: 440, height: 600), in: visible, right: true)
let displayKey = SnapGeometry.displayKey(number.uint32Value)
frameStore.save(nearBox, displayKey: PanelGeometry.boxKey(displayKey))
frameStore.saveAnchorRight(true, displayKey: displayKey)
let nearModel = DeckModel(daemon: Daemon(paths: paths, settings: anchorSettings.load()), settingsStore: anchorSettings, logURL: paths.logFile)
nearModel.sessions = anchorModel.sessions
let beforeNear = Set(app.windows.map(\.windowNumber))
let nearController = PanelController(model: nearModel, frames: frameStore)
guard let nearPanel = app.windows.first(where: { !beforeNear.contains($0.windowNumber) && $0 is OverlayPanel }) else { fatalError("no near-centre panel") }
nearModel.panelVisible = true; nearController.refit(); run(0.3)
require(abs(nearPanel.frame.maxX - nearPill.maxX) < 1, "restored near-centre placement reverses its chosen side")
nearModel.expandPanel(); run(0.3); nearController.refit(); nearModel.collapsePanel(); run(0.3); nearController.refit()
require(abs(nearPanel.frame.maxX - nearPill.maxX) < 1, "near-centre expand/collapse reverses its chosen side")
require(!nearPanel.isVisible, "near-centre test ordered a window")
print("PASS persisted near-centre anchor: saved side preserved through restore and resize")
anchorDefaults.removeObject(forKey: "OverlayAnchorSides")
let legacyLeft = CGRect(x: visible.minX + 8, y: visible.maxY - 8 - 600, width: 440, height: 600)
frameStore.save(legacyLeft, displayKey: PanelGeometry.boxKey(displayKey))
nearPanel.setFrameOrigin(CGPoint(x: -200000, y: -200000))
NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
run(0.3); nearController.refit()
require(abs(nearPanel.frame.minX - legacyLeft.minX) < 1, "fallback to a legacy display reverses its saved left side")
print("PASS legacy display fallback: infer missing side from target display box")
print("Hosted layout checks PASS; no window shown, no live daemon or settings used")
exit(0)
