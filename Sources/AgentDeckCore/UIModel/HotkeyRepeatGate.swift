import Foundation

/// Holding a hotkey auto-repeats kEventHotKeyPressed; only the first press per hold may act (one decision per keystroke).
public struct HotkeyRepeatGate {
    private var down: Set<UInt32> = []
    public init() {}
    public mutating func pressed(_ id: UInt32) -> Bool { down.insert(id).inserted }
    public mutating func released(_ id: UInt32) { down.remove(id) }
    public mutating func reset() { down = [] }
}
