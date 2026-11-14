import Combine
import SwiftUI
import AgentDeckCore

/// Press and hold for `HoldGesture.duration`; a progress ring fills. Used for a high-risk Allow.
struct HoldButton: View {
    let title: String               // e.g. "Allow rule #2"; shown as "Hold to allow rule #2"
    let enabled: Bool
    let requestId: String
    var tint: Color = .accentColor  // red only for high risk
    var reason: String = ""         // why a hold is needed
    var disabledReason = HoldReason.notReady
    var notice: String?             // drop reason from the model, shown for a few seconds
    var onReleasedEarly: () -> Void = {}
    let onComplete: () -> Void
    @State private var message: String?
    @State private var messageWork: DispatchWorkItem?   // one-shot, never repeating
    @State private var gesture = HoldGesture(clock: SystemClock())
    @State private var pressing = false
    @State private var progress = 0.0
    @State private var timer: Publishers.Autoconnect<Timer.TimerPublisher>?   // runs only while pressed
    @State private var voiceOverArmedAt: Date?                                  // VoiceOver cannot hold: activate twice instead

    private var label: String { "Hold to " + (title.hasPrefix("Allow") ? "a" + title.dropFirst() : title) }
    private var caption: String { "Hold 1 s" + (reason.isEmpty ? "" : " · " + reason) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                    Circle().trim(from: 0, to: progress).stroke(tint, lineWidth: 2).rotationEffect(.degrees(-90))
                }.frame(width: 12, height: 12).accessibilityHidden(true)
                Text(label).font(.callout)
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(pressing ? 0.35 : 0.18)))
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !enabled { if message == nil { flash(disabledReason) } }
                else if !pressing {
                    pressing = true; gesture.begin(requestId: requestId)
                    timer = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()
                }
            }
            .onEnded { _ in
                let early = pressing
                cancel()
                if early { flash(HoldReason.releasedEarly, seconds: 2); onReleasedEarly() }
            })
        .onReceive(timer?.eraseToAnyPublisher() ?? Empty(completeImmediately: false).eraseToAnyPublisher()) { _ in
            guard pressing else { return }
            if !enabled { cancel(); return }
            progress = gesture.progress()
            if progress >= 1 {
                let done = gesture.complete() != nil
                pressing = false; progress = 0; timer = nil
                if done { onComplete() }
            }
        }
            if let m = notice ?? message { Text(m).font(.caption2.weight(.semibold)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .help("Press and hold for 1 s")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + (reason.isEmpty ? "" : ", " + reason))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(voiceOverArmedAt == nil ? "Hold for 1 second, or activate twice to confirm" : "Activate again to confirm")
        .accessibilityAction {
            guard enabled else { return }
            if let t = voiceOverArmedAt, Date().timeIntervalSince(t) < 5 { voiceOverArmedAt = nil; onComplete() }
            else { voiceOverArmedAt = Date() }
        }
    }

    private func flash(_ text: String, seconds: Double = 2) {
        messageWork?.cancel()
        message = text
        let w = DispatchWorkItem { message = nil }
        messageWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func cancel() { gesture.cancel(); pressing = false; progress = 0; timer = nil }
}
