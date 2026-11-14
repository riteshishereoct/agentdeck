import SwiftUI
import AgentDeckCore

struct QuestionCardView: View {
    @ObservedObject var model: DeckModel
    let request: Request
    var showsSubmit = true
    private var selection: QuestionSelection { model.requestPresentation.questions[request.id] ?? QuestionSelection() }
    private var editing: Set<String> { model.requestPresentation.editingOther[request.id] ?? [] }        // questions whose Other field the person opened
    @FocusState private var focused: String?
    /// The field shows this local copy, so a deck re-render can never push older text back into it mid-typing.
    /// Every change is still written through: Submit's enabled state and answer read the model.
    @State private var otherDraft: [String: String] = [:]

    var body: some View {
        let specs = QuestionForm.parse(request.fullInput)
        let answers = QuestionForm.answers(specs, selection)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(specs, id: \.question) { spec in question(spec) }
            if showsSubmit { HStack {
                Button("Submit") {
                    if let answers {
                        model.perform(.answer(answers), renderedId: request.id, via: .click)

                    }
                }.disabled(!model.queue.isArmed || answers == nil)
                Button("Open in Cursor ↗") { model.openInCursor(sessionId: request.sessionId) }
            } }
        }
        .onDisappear { model.closeQuestionInput() }
    }

    @ViewBuilder private func question(_ spec: QuestionSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let h = spec.header, !h.isEmpty { Text(Masking.mask(h)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                Text(spec.multiSelect ? "Choose any" : "Choose one").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).background(Capsule().fill(Color.blue.opacity(0.18)))
            }
            Text(Masking.mask(spec.question)).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(spec.options.enumerated()), id: \.offset) { index, label in option(spec, index, label) }
            // Shown whenever it holds text, so a typed answer can never be submitted invisibly.
            if editing.contains(spec.question) || !(selection.other[spec.question] ?? "").isEmpty {
                TextField("Other answer…", text: Binding(get: { otherDraft[spec.question] ?? selection.other[spec.question] ?? "" },
                                                         set: { text in
                                                             otherDraft[spec.question] = text
                                                             var draft = selection; draft.setOther(text, for: spec)
                                                             model.requestPresentation.questions[request.id] = draft
                                                         }), axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($focused, equals: spec.question)
                    .accessibilityLabel("Other answer for: " + Masking.mask(spec.question))
                    .onTapGesture { model.openQuestionInput(for: request.id) }
            } else {
                Button("Other…") {
                    model.openQuestionInput(for: request.id)
                    model.requestPresentation.editingOther[request.id, default: []].insert(spec.question)
                    DispatchQueue.main.async { focused = spec.question }
                }
            }
        }
    }

    private func option(_ spec: QuestionSpec, _ index: Int, _ label: String) -> some View {
        let on = (selection.chosen[spec.question] ?? []).contains(index)
        let description = spec.descriptions.indices.contains(index) ? spec.descriptions[index] : nil
        return Button {
            var draft = selection; draft.toggle(index, in: spec)
            otherDraft[spec.question] = nil      // toggle discards the Other text; the field must not keep showing it
            model.requestPresentation.questions[request.id] = draft
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: on ? (spec.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                     : (spec.multiSelect ? "square" : "circle"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Masking.mask(label)).fixedSize(horizontal: false, vertical: true)
                    if let description {
                        Text(Masking.mask(description)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Masking.mask(label + (description.map { ", " + $0 } ?? "")))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
