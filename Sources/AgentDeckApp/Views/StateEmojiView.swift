import SwiftUI
import AgentDeckCore

/// Transform-only motion (scale/rotation/offset): cheap per frame, nothing blurs or shadows.
struct StateEmojiView: View {
    let state: SessionState
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var looping = false

    private struct Frame { var scale = 1.0, angle = 0.0, x = 0.0, y = 0.0 }

    var body: some View {
        let e = StateEmoji.for(state)
        let text = Text(e.emoji).font(.system(size: 14)).accessibilityLabel(e.label)
        if !animated || reduceMotion || e.motion == .none {
            text
        } else if e.continuous {
            // Capped at 15 fps for loopSeconds after each state change, then rests on the static glyph.
            Group {
                if looping {
                    TimelineView(.animation(minimumInterval: StateEmoji.loopInterval)) { tl in
                        let p = StateEmoji.loopPose(e.motion, at: tl.date.timeIntervalSinceReferenceDate)
                        text.scaleEffect(p.scale).rotationEffect(.degrees(p.angle))
                    }
                } else { text }
            }
            .task(id: state) {
                looping = true
                try? await Task.sleep(nanoseconds: UInt64(StateEmoji.loopSeconds * 1e9))
                looping = false
            }
        } else {
            text.keyframeAnimator(initialValue: Frame(), trigger: state) { v, f in
                v.scaleEffect(f.scale).rotationEffect(.degrees(f.angle)).offset(x: f.x, y: f.y)
            } keyframes: { _ in
                // Same tracks for every motion; amplitudes are zero where a motion doesn't use them.
                let bounce = e.motion == .bounce, shake = e.motion == .shake, float = e.motion == .float
                KeyframeTrack(\.scale) { CubicKeyframe(bounce ? 1.5 : 1, duration: 0.15); SpringKeyframe(1, duration: 0.35, spring: .bouncy) }
                KeyframeTrack(\.y) {
                    CubicKeyframe(bounce ? -5 : float ? -3 : 0, duration: float ? 0.4 : 0.15)
                    CubicKeyframe(0, duration: float ? 0.4 : 0.35)
                }
                KeyframeTrack(\.x) {
                    let a = shake ? 3.0 : 0
                    LinearKeyframe(-a, duration: 0.07); LinearKeyframe(a, duration: 0.07); LinearKeyframe(-a, duration: 0.07)
                    LinearKeyframe(a, duration: 0.07); LinearKeyframe(0, duration: 0.07)
                }
            }
        }
    }
}
