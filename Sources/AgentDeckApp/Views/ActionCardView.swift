import SwiftUI
import AgentDeckCore

struct ActionCardView: View {
    @ObservedObject var model: DeckModel
    let request: Request
    /// Local draft: keystrokes never round-trip through published deck state (each publish re-renders the deck and refits the panel).
    @State private var noteDraft: String?
    private var note: String { noteDraft ?? model.requestPresentation.notes[request.id] ?? "" }
    @State private var bodyViewport: CGFloat = 0
    @State private var bodyContent: CGFloat = 0     // natural height of the scrollable body, so short cards hug their content
    @State private var reviewEnd: CGRect = .zero
    @FocusState private var noteFocused: Bool
    @State private var cachedContext: ConsentContext?   // the view is keyed by request.id, so this is per request

    var body: some View {
        let ctx = cachedContext ?? ConsentContext.make(request, session: model.sessions.first { $0.id == request.sessionId })
        let hold = CardLayout.allowNeedsHold(request, context: ctx)
        let isQuestion = request.kind == .question
        let buttons = CardLayout.buttons(for: request)
        let form = buttons.contains(.submitAnswer)      // the interactive form renders every question itself
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let p = model.queue.positionText { Text(p).font(.caption).foregroundStyle(.secondary).fixedSize().layoutPriority(2) }
                if let next = model.queue.nextId {
                    Button("Next ›") { model.expandRequest(next) }   // shows the next request; never decides
                        .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor).fixedSize().layoutPriority(2)
                        .help("Show the next waiting request").accessibilityLabel("Show next request")
                }
                Text(isQuestion ? "QUESTION" : request.kind == .planReview ? "PLAN REVIEW" : ctx.risk).font(.caption2.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill((isQuestion ? Color.blue : riskColor).opacity(0.22)))
                Spacer()
                Button {
                    if model.requestPresentation.collapsed.contains(request.id) { model.expandRequest(request.id) }
                    else { model.collapseRequest(request.id) }
                } label: {
                    Image(systemName: model.requestPresentation.collapsed.contains(request.id) ? "chevron.down" : "chevron.up")
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(model.requestPresentation.collapsed.contains(request.id) ? "Expand request details" : "Collapse request details")
                    .help(model.requestPresentation.collapsed.contains(request.id) ? "Expand request details" : "Collapse request details")
            }
            // G-CONSENT: who is asking, what for, what exactly, why (agent's words, labelled), and what it can touch.
            // #id + project on its own line, never truncated; the title below wraps (same-project sessions differ only by #id).
            Text(ctx.identity).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            if !model.requestPresentation.collapsed.contains(request.id) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
            if let title = ctx.sessionTitle {
                Text(title).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let task = ctx.task {
                Text("Task: " + task).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Text(ctx.what).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if !ctx.detail.isEmpty, !form { detailBox(ctx) }
            // AgentDeck's own reading (scope) is primary; the agent's words are secondary, italic and labelled.
            Text("Scope: " + ctx.scope).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if !isQuestion {
                Text(ctx.reason).font(.caption).italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
                        ForEach(Array(buttons.enumerated()), id: \.offset) { index, item in
                            if case .allowAlways = item {
                                Text("Allow rule #\(index + 1): " + Masking.mask(item.title))
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if form { QuestionCardView(model: model, request: request, showsSubmit: false) }
                        if model.noteFor == request.id { noteField }
                        Color.clear.frame(height: 1).background(GeometryReader { proxy in
                            Color.clear.preference(key: ReviewEndKey.self, value: proxy.frame(in: .named("RequestBody")))
                        })
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { proxy in Color.clear.preference(key: BodyContentKey.self, value: proxy.size.height) })
                }.scrollIndicators(.visible)
                    // Never taller than its content: the actions sit right under a short body; a long body scrolls inside the cap.
                    .frame(idealHeight: bodyContent > 0 ? bodyContent : nil, maxHeight: bodyContent > 0 ? bodyContent : nil)
                    .onPreferenceChange(BodyContentKey.self) { bodyContent = $0 }
                    .coordinateSpace(name: "RequestBody")
                    .background(GeometryReader { proxy in Color.clear.preference(key: ReviewHeightKey.self, value: proxy.size.height) })
                    .onPreferenceChange(ReviewEndKey.self) { reviewEnd = $0; reportReviewEnd() }
                    .onPreferenceChange(ReviewHeightKey.self) { bodyViewport = $0; reportReviewEnd() }
                if !model.requestPresentation.reviewAtEnd.contains(request.id) {
                    Text("Scroll through the request to enable actions").font(.caption2).foregroundStyle(.secondary)
                }
            if form {
                HStack {
                    Button("Submit answer") {
                        let specs = QuestionForm.parse(request.fullInput)
                        if let answers = QuestionForm.answers(specs, model.requestPresentation.questions[request.id] ?? QuestionSelection()) {
                            model.perform(.answer(answers), renderedId: request.id, via: .click)
                        }
                    }.disabled(!model.queue.isArmed || QuestionForm.answers(QuestionForm.parse(request.fullInput), model.requestPresentation.questions[request.id] ?? QuestionSelection()) == nil)
                    button(.openInCursor, hold: hold, index: 0)   // navigation only; never resolves the request
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(buttons.enumerated()), id: \.offset) { index, item in
                            button(item, hold: hold, index: index).fixedSize(horizontal: true, vertical: true)
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                }.scrollIndicators(.visible).frame(height: 62)
                .accessibilityLabel("Request actions")
            }
            }
        }
        .padding(10)
        .frame(maxHeight: model.requestPresentation.collapsed.contains(request.id) ? nil : model.cardHeight, alignment: .top)
        .background(ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.thinMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14))
        })
        .onAppear { if cachedContext == nil { cachedContext = ctx } }
    }

    private func reportReviewEnd() {
        model.reportReviewEnd(request.id, visible: bodyViewport > 0 && reviewEnd.minY >= -1 && reviewEnd.maxY <= bodyViewport + 1)
    }

    /// The real (masked) command / file+diff / input. Long content scrolls inside a bounded box so the buttons stay reachable.
    @ViewBuilder private func detailBox(_ ctx: ConsentContext) -> some View {
        let text = Text(ctx.detail).font(.system(.caption, design: .monospaced)).textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 2) {
            Text(ctx.detailLabel).font(.caption2).foregroundStyle(.secondary)
            Group {
                if ctx.overflows { ScrollView { text }.frame(height: 140).scrollIndicators(.visible) } else { text }
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            .accessibilityElement(children: .ignore).accessibilityLabel(ctx.detailLabel).accessibilityValue(ctx.detail)
            if ctx.overflows {
                // The end is where a dangerous `&& rm …` hides: always on screen, outside the scroll box.
                Text("Ends with:").font(.caption2).foregroundStyle(.secondary)
                Text(ctx.tail).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                    .accessibilityLabel(ctx.detailLabel + " ends with").accessibilityValue(ctx.tail)
            }
            if ctx.incomplete {
                Text("Not everything is shown here. Allow needs a hold; open in Cursor to see all.").font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var riskColor: Color { request.risk.level == .high ? .red : request.risk.level == .med ? .orange : .green }

    private func hint(_ a: HotkeyAction) -> String { " " + HotkeyLabel.text(model.hotkeyConfig[a]) }

    @ViewBuilder private func button(_ b: CardButton, hold: Bool, index: Int) -> some View {
        switch b {
        case .allow:
            if hold {
                HoldButton(title: b.title, enabled: model.queue.isArmed, requestId: request.id,
                           tint: request.risk.level == .high ? .red : .accentColor,
                           reason: HoldReason.text(risk: request.risk.level, context: cachedContext ?? ConsentContext.make(request, session: model.sessions.first { $0.id == request.sessionId })),
                           notice: model.cardNotice?.id == request.id ? model.cardNotice?.text : nil,
                           onReleasedEarly: { model.holdReleasedEarly(request.id) }) { model.perform(.allow, renderedId: request.id, via: .hold) }
            } else {
                Button(b.title + hint(.allowTop)) { model.perform(.allow, renderedId: request.id, via: .click) }
                    .disabled(!model.queue.isArmed).accessibilityLabel(b.title)
            }
        case .submitAnswer: EmptyView()
        case .allowAlways(_, let suggestion):
            let title = "Allow rule #\(index + 1)"
            if hold || SuggestionScope.needsHold(suggestion, cwd: model.sessions.first { $0.id == request.sessionId }.map { $0.workspaceRoot ?? $0.cwd }) {
                HoldButton(title: title, enabled: model.queue.isArmed, requestId: request.id,
                           tint: request.risk.level == .high ? .red : .accentColor,
                           reason: HoldReason.text(risk: request.risk.level, context: cachedContext, broadRule: true),
                           notice: model.cardNotice?.id == request.id ? model.cardNotice?.text : nil,
                           onReleasedEarly: { model.holdReleasedEarly(request.id) }) {
                    model.perform(.allowAlways(suggestion), renderedId: request.id, via: .hold)
                }
            } else {
                Button { model.perform(.allowAlways(suggestion), renderedId: request.id, via: .click) } label: {
                    Text(title)   // Exact numbered scope stays readable in the reviewed, scrollable body.
                }
                .disabled(!model.queue.isArmed)
            }
        case .deny:
            Button(b.title + hint(.denyTop)) { model.perform(.deny(note: nil), renderedId: request.id, via: .click) }.disabled(!model.queue.isArmed).accessibilityLabel(b.title)
        case .denyWithNote:
            Button(b.title) { model.openNote(for: request.id) }
        case .dismiss:
            Button(b.title) { model.dismiss(requestId: request.id) }
        case .openInCursor, .approveInCursor, .reviewInCursor, .answerInCursor, .needsApprovalOpen:
            Button(b.title) { model.openInCursor(sessionId: request.sessionId) }
        }
    }

    /// Opens below the buttons: everything above (task, command, reason, scope) stays on screen while typing.
    private var noteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Note to Claude (sent with the denial)", text: Binding(get: { note }, set: { noteDraft = $0 }), axis: .vertical).lineLimit(1...4)
                .textFieldStyle(.roundedBorder).focused($noteFocused).onAppear { noteFocused = true }
                .onDisappear { model.saveNote(note, for: request.id) }   // collapse, Cancel, privacy or card change keep the exact text
                .onSubmit(send).accessibilityLabel("Denial note")
            HStack {
                Button("Deny + send note", action: send).disabled(!model.queue.isArmed)
                Button("Cancel") { model.closeNote() }
            }
        }
    }

    private func send() {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        model.perform(.deny(note: t.isEmpty ? nil : t), renderedId: request.id, via: .click)
    }
}

private struct ReviewEndKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.height > 0 { value = next }
    }
}
private struct BodyContentKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ReviewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
