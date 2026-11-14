import Foundation

/// Drafts and deliberate collapse survive redraws, but never survive a resolved request or app restart.
public struct RequestPresentation: Equatable {
    public var collapsed: Set<String> = []
    public var reviewAtEnd: Set<String> = []
    public var notes: [String: String] = [:]
    public var questions: [String: QuestionSelection] = [:]
    public var editingOther: [String: Set<String>] = [:]
    public var noteOpen: Set<String> = []       // note editor was open when the card was collapsed
    public init() {}
    public mutating func retain(pending ids: Set<String>) {
        collapsed.formIntersection(ids)
        reviewAtEnd.formIntersection(ids)
        noteOpen.formIntersection(ids)
        notes = notes.filter { ids.contains($0.key) }
        questions = questions.filter { ids.contains($0.key) }
        editingOther = editingOther.filter { ids.contains($0.key) }
    }
    /// Hides the body and forgets review; every draft stays, and an open note editor is remembered for reopen.
    public mutating func collapse(_ id: String, noteEditorOpen: Bool) {
        collapsed.insert(id); reviewAtEnd.remove(id)
        if noteEditorOpen { noteOpen.insert(id) }
    }
    /// Returns true when the note editor was open at collapse and should open again.
    public mutating func expand(_ id: String) -> Bool {
        collapsed.remove(id)
        return noteOpen.remove(id) != nil
    }
    /// The request was decided: its drafts must never outlive it.
    public mutating func resolved(_ id: String) {
        notes[id] = nil; questions[id] = nil; editingOther[id] = nil; noteOpen.remove(id)
    }
}
