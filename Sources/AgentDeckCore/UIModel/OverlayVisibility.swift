import Foundation

/// Decides whether the overlay panel should be on screen. Pure and event-driven: the app calls it from tick(), never from a timer of its own.
public struct OverlayVisibility: Equatable {
    private var revealed = false
    private var userHidden = false
    private var wasActive = false
    public init() {}

    /// Menubar Show / toggle hotkey / a new card arriving: stay visible until the next active -> idle transition.
    public mutating func reveal() { revealed = true; userHidden = false }

    /// Menubar Hide: stay hidden until revealed or until new activity starts.
    public mutating func userHide() { revealed = false; userHidden = true }

    public mutating func shouldShow(sessions: [Session], cardsVisible: Bool, hovering: Bool, hideWhenIdle: Bool) -> Bool {
        let working = sessions.contains { [.working, .needsYou, .error, .waitingInCursor].contains($0.state) }
        let pending = sessions.contains { $0.pending.contains { $0.status == .pending } }
        let active = working || pending
        if wasActive && !active { revealed = false }
        if !wasActive && active { userHidden = false }
        wasActive = active
        return !userHidden && (!hideWhenIdle || active || cardsVisible || hovering || revealed)
    }
}
