import Carbon
import AgentDeckCore

/// Carbon RegisterEventHotKey: needs no Accessibility or Input Monitoring permission.
final class HotkeyCenter {
    private let onAction: (HotkeyAction) -> Void
    private var refs: [EventHotKeyRef] = []
    private var byId: [UInt32: HotkeyAction] = [:]
    private var handler: EventHandlerRef?
    private var gate = HotkeyRepeatGate()

    init(onAction: @escaping (HotkeyAction) -> Void) {
        self.onAction = onAction
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard st == noErr else { return st }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()   // delivered on the main thread
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { center.gate.released(id.id) } else { center.fire(id.id) }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit { unregisterAll(); if let h = handler { RemoveEventHandler(h) } }

    private func fire(_ id: UInt32) { if gate.pressed(id), let a = byId[id] { onAction(a) } }

    private func unregisterAll() { refs.forEach { UnregisterEventHotKey($0) }; refs = []; byId = [:]; gate.reset() }

    /// Re-registers every action. A non-zero status means that action is unbound (e.g. -9878: combination already taken).
    @discardableResult
    func apply(_ config: HotkeyConfig) -> [HotkeyAction: OSStatus] {
        unregisterAll()
        var out: [HotkeyAction: OSStatus] = [:]
        for (i, a) in HotkeyAction.allCases.enumerated() {
            let k = config[a]
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(k.keyCode, k.modifiers, EventHotKeyID(signature: 0x4144434B, id: UInt32(i)),
                                         GetApplicationEventTarget(), 0, &ref)
            out[a] = st
            if st == noErr, let ref { refs.append(ref); byId[UInt32(i)] = a }
        }
        return out
    }
}
