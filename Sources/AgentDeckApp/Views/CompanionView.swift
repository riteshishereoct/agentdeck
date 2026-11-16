import AppKit
import SwiftUI
import AgentDeckCore

/// Live companion drawn with Canvas only (no images). `animated` is decided by the caller via `CompanionPolicy`;
/// when false (or Reduce Motion) it draws one static frame, so nothing ticks and idle CPU stays at zero.
struct CompanionView: View {
    let style: CompanionStyle
    let mood: CompanionMood
    let animated: Bool
    let size: CGFloat
    var accent: Color = .accentColor
    /// Pointer in this view's local space, nil when the pointer is elsewhere.
    var pointer: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let active = animated && !reduceMotion && style != .off
        TimelineView(.animation(minimumInterval: CompanionPolicy.frameInterval(for: mood), paused: !active)) { tl in
            let t = active ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : CompanionArt.staticTime
            Canvas { ctx, sz in
                var c = ctx
                CompanionArt.draw(&c, size: sz, style: style, mood: mood, t: t, pointer: pointer, accent: accent, dark: scheme == .dark)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AgentDeck companion: \(mood.label)")
    }
}

/// Pointer position in the deck's root space, observed only by the companion so the deck body never re-renders on mouse moves.
final class PointerTracker: ObservableObject {
    @Published var point: CGPoint?
}

/// Owns hover + "recent mood change" state and applies the energy policy; the deck just places it.
struct CompanionHost: View {
    static let space = "AgentDeckRoot"
    @ObservedObject var tracker: PointerTracker
    let style: CompanionStyle
    let mood: CompanionMood
    let enabled: Bool
    let visible: Bool
    let accent: Color
    let size: CGFloat
    @State private var changedAt = Date.distantPast
    @State private var tick = false

    var body: some View {
        let _ = tick   // re-evaluate once when the reaction window ends
        let animated = CompanionPolicy.shouldAnimate(style: style, mood: mood, visible: visible, enabled: enabled,
                                                     hovering: tracker.point != nil, secondsSinceMoodChange: Date().timeIntervalSince(changedAt))
        GeometryReader { g in
            let o = g.frame(in: .named(Self.space)).origin
            CompanionView(style: style, mood: mood, animated: animated, size: size, accent: accent,
                          pointer: tracker.point.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) })
        }
        .frame(width: size, height: size)
        .onChange(of: mood) { _, _ in changedAt = Date() }
        .task(id: changedAt) {
            guard changedAt != .distantPast else { return }
            try? await Task.sleep(nanoseconds: UInt64((CompanionPolicy.reactionSeconds + 0.1) * 1e9))
            tick.toggle()
        }
    }
}

/// Pure drawing, parameterised by an explicit time and pointer so tests and the snapshot harness can render any frame.
enum CompanionArt {
    static let staticTime: Double = 0.35

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, style: CompanionStyle, mood: CompanionMood, t: Double,
                     pointer: CGPoint?, accent: Color, dark: Bool) {
        let m = (mood == .sleeping && pointer != nil) ? CompanionMood.calm : mood   // hover wakes it
        let tint = Self.tint(m, accent)
        switch style {
        case .pet: pet(&ctx, size, m, t, pointer, tint, dark, asleep: mood == .sleeping && pointer == nil)
        case .geometry: geometry(&ctx, size, m, t, pointer, tint, dark, asleep: mood == .sleeping && pointer == nil)
        case .off: break
        }
    }

    // MARK: colour

    private static func rgb(_ c: Color) -> (Double, Double, Double) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        return (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
    }
    static func blend(_ a: Color, _ b: Color, _ f: Double) -> Color {
        let x = rgb(a), y = rgb(b)
        return Color(.sRGB, red: x.0 + (y.0 - x.0) * f, green: x.1 + (y.1 - x.1) * f, blue: x.2 + (y.2 - x.2) * f, opacity: 1)
    }
    private static let amber = Color(red: 1.0, green: 0.68, blue: 0.12)
    private static let red = Color(red: 0.95, green: 0.27, blue: 0.25)
    private static let mint = Color(red: 0.28, green: 0.80, blue: 0.50)
    static func tint(_ mood: CompanionMood, _ accent: Color) -> Color {
        switch mood {
        case .alert: return blend(accent, amber, 0.85)
        case .upset: return blend(accent, red, 0.85)
        case .happy: return blend(accent, mint, 0.4)
        case .sleeping: return blend(accent, .gray, 0.4)
        case .busy, .calm: return accent
        }
    }

    // MARK: pet

    private static func pet(_ ctx: inout GraphicsContext, _ s: CGSize, _ m: CompanionMood, _ t: Double, _ pointer: CGPoint?,
                            _ tint: Color, _ dark: Bool, asleep: Bool) {
        let u = min(s.width, s.height)
        var c = CGPoint(x: s.width / 2, y: s.height * 0.55)
        let r = u * 0.32
        var amp = 0.05, sp = 1.4, sx = 1.0, sy = 1.0, lift = 0.0
        switch m {
        case .sleeping: amp = 0.025; sp = 0.6; let b = sin(t * 0.9); sy += 0.04 * b; sx -= 0.025 * b
        case .calm: let b = sin(t * 1.5) * 0.05; amp = 0.035; sp = 1; sy += b; sx -= b * 0.6
        case .busy: amp = 0.08; sp = 3.2
        case .alert:
            amp = 0.05; sp = 2.5
            let h = abs(sin(t * 5.5)); lift = h; c.y -= h * u * 0.10; sy -= 0.08 * (1 - h); sx += 0.06 * (1 - h)
        case .happy:
            let p = t.truncatingRemainder(dividingBy: 1.5) / 0.75
            if p < 1 { let h = 4 * p * (1 - p); lift = h; c.y -= h * u * 0.16; sy += 0.08 * h; sx -= 0.05 * h }
        case .upset: c.x += sin(t * 46) * u * 0.012; amp = 0.03; sp = 5
        }
        let ground = s.height * 0.55 + r * 0.98
        let lt = Color.white, dk = Color.black
        let light = blend(tint, lt, 0.5), deep = blend(tint, dk, dark ? 0.35 : 0.22)

        if asleep { ctx.opacity = 0.85 }
        // contact shadow
        let sw = r * 1.5 * (1 - lift * 0.3)
        ctx.fill(Path(ellipseIn: CGRect(x: s.width / 2 - sw / 2, y: ground - r * 0.1, width: sw, height: r * 0.25)),
                 with: .color(.black.opacity((dark ? 0.35 : 0.16) * (1 - lift * 0.5))))

        // outline: closed path through sin-perturbed radii, smoothed through midpoints
        let n = 44
        let pts: [CGPoint] = (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi
            let w = 0.6 * sin(2 * a + sp * t * 1.3) + 0.4 * sin(3 * a - sp * t * 1.7) + 0.25 * sin(5 * a + sp * t * 2.3)
            let rho = r * (1 + amp * w)
            return CGPoint(x: c.x + cos(a) * rho * sx, y: c.y + sin(a) * rho * sy)
        }
        var body = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        body.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n { body.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i]) }
        body.closeSubpath()
        ctx.fill(body, with: .radialGradient(Gradient(colors: [light, tint, deep]), center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.45),
                                             startRadius: 0, endRadius: r * 1.7))
        ctx.stroke(body, with: .color(deep.opacity(0.55)), lineWidth: max(0.6, u * 0.012))
        // glossy highlight
        let hc = CGPoint(x: c.x - r * 0.36, y: c.y - r * 0.55)
        let hl = Path(ellipseIn: CGRect(x: -r * 0.28, y: -r * 0.13, width: r * 0.56, height: r * 0.26))
            .applying(CGAffineTransform(rotationAngle: -0.5).concatenating(CGAffineTransform(translationX: hc.x, y: hc.y)))
        ctx.fill(hl, with: .color(.white.opacity(0.42)))

        // face
        let ink = Color(red: 0.08, green: 0.09, blue: 0.14)
        let er = r * (m == .alert ? 0.30 : 0.24)
        let ey = c.y - r * 0.12
        let blinkPhase = t.truncatingRemainder(dividingBy: 3.7)
        let open = blinkPhase < 0.14 ? 1 - sin(.pi * blinkPhase / 0.14) : 1.0
        let target: CGPoint
        if let p = pointer { target = p }
        else if m == .busy { let k = floor(t * 2.6); target = CGPoint(x: c.x + sin(k * 12.9898) * u, y: c.y + cos(k * 78.233) * u * 0.4) }
        else { target = CGPoint(x: c.x, y: c.y + r * 0.2) }
        for side in [-1.0, 1.0] {
            let e = CGPoint(x: c.x + side * r * 0.38, y: ey)
            if asleep {
                var arc = Path(); arc.move(to: CGPoint(x: e.x - er * 0.8, y: e.y))
                arc.addQuadCurve(to: CGPoint(x: e.x + er * 0.8, y: e.y), control: CGPoint(x: e.x, y: e.y + er * 0.9))
                ctx.stroke(arc, with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: max(0.8, u * 0.022), lineCap: .round))
                continue
            }
            let eh = max(0.12, open)
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - er, y: e.y - er * eh, width: er * 2, height: er * 2 * eh)), with: .color(.white.opacity(0.96)))
            let dx = target.x - e.x, dy = target.y - e.y, len = max(0.001, hypot(dx, dy))
            let off = er * 0.5 * min(1, len / (u * 0.45))
            let pr = er * 0.58
            let pc = CGPoint(x: e.x + dx / len * off, y: e.y + dy / len * off * eh)
            ctx.fill(Path(ellipseIn: CGRect(x: pc.x - pr, y: pc.y - pr * eh, width: pr * 2, height: pr * 2 * eh)), with: .color(ink))
            if eh > 0.5 { ctx.fill(Path(ellipseIn: CGRect(x: pc.x - pr * 0.1, y: pc.y - pr * 0.6, width: pr * 0.45, height: pr * 0.45)), with: .color(.white.opacity(0.9))) }
            if m == .upset {   // worried brows, inner ends raised
                var b = Path(); b.move(to: CGPoint(x: e.x - side * er * 1.1, y: e.y - er * 1.5)); b.addLine(to: CGPoint(x: e.x + side * er * 0.9, y: e.y - er * 1.95))
                ctx.stroke(b, with: .color(ink.opacity(0.75)), style: StrokeStyle(lineWidth: max(0.8, u * 0.022), lineCap: .round))
            }
        }
        let my = c.y + r * 0.32
        var mouth = Path()
        let stroke = StrokeStyle(lineWidth: max(0.8, u * 0.022), lineCap: .round)
        switch m {
        case .happy:
            let w = r * 0.26
            mouth.move(to: CGPoint(x: c.x - w, y: my - r * 0.04)); mouth.addQuadCurve(to: CGPoint(x: c.x + w, y: my - r * 0.04), control: CGPoint(x: c.x, y: my + r * 0.5)); mouth.closeSubpath()
            ctx.fill(mouth, with: .color(ink.opacity(0.85)))
            for side in [-1.0, 1.0] { ctx.fill(Path(ellipseIn: CGRect(x: c.x + side * r * 0.62 - r * 0.12, y: my - r * 0.22, width: r * 0.24, height: r * 0.14)), with: .color(Color(red: 1, green: 0.45, blue: 0.5).opacity(0.5))) }
        case .upset:
            mouth.move(to: CGPoint(x: c.x - r * 0.2, y: my + r * 0.12)); mouth.addQuadCurve(to: CGPoint(x: c.x + r * 0.2, y: my + r * 0.12), control: CGPoint(x: c.x, y: my - r * 0.14))
            ctx.stroke(mouth, with: .color(ink.opacity(0.8)), style: stroke)
        case .alert: ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.1, y: my - r * 0.02, width: r * 0.2, height: r * 0.26)), with: .color(ink.opacity(0.8)))
        case .busy: ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.08, y: my, width: r * 0.16, height: r * (0.1 + 0.06 * abs(sin(t * 6))))), with: .color(ink.opacity(0.75)))
        case .calm, .sleeping:
            mouth.move(to: CGPoint(x: c.x - r * 0.14, y: my)); mouth.addQuadCurve(to: CGPoint(x: c.x + r * 0.14, y: my), control: CGPoint(x: c.x, y: my + r * 0.14))
            ctx.stroke(mouth, with: .color(ink.opacity(0.7)), style: stroke)
        }
        if asleep {
            ctx.opacity = 1
            for i in 0..<2 {
                let q = (t * 0.35 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                let pos = CGPoint(x: c.x + r * 0.75 + q * u * 0.16, y: c.y - r * 0.75 - q * u * 0.26)
                let tx = Text("z").font(.system(size: u * (0.13 + 0.09 * q), weight: .bold, design: .rounded))
                    .foregroundStyle(dark ? blend(tint, .white, 0.5) : deep)
                var z = ctx; z.opacity = sin(.pi * q) * 0.9
                z.draw(tx, at: pos)
            }
        }
    }

    // MARK: geometry

    private static let ico: (v: [SIMD3<Double>], e: [(Int, Int)]) = {
        let p = (1 + 5.0.squareRoot()) / 2, k = (1 + p * p).squareRoot()
        var raw: [SIMD3<Double>] = []
        for a in [-1.0, 1.0] { for b in [-p, p] { raw += [SIMD3(0, a, b), SIMD3(a, b, 0), SIMD3(b, 0, a)] } }
        let v = raw.map { $0 / k }
        var e: [(Int, Int)] = []
        for i in 0..<v.count { for j in (i + 1)..<v.count {
            let d = v[i] - v[j]
            if (d * d).sum() < 1.2 { e.append((i, j)) }
        } }
        return (v, e)
    }()

    private static func rot(_ v: SIMD3<Double>, yaw: Double, pitch: Double) -> SIMD3<Double> {
        let x1 = v.x * cos(yaw) + v.z * sin(yaw), z1 = -v.x * sin(yaw) + v.z * cos(yaw)
        return SIMD3(x1, v.y * cos(pitch) - z1 * sin(pitch), v.y * sin(pitch) + z1 * cos(pitch))
    }

    private static func geometry(_ ctx: inout GraphicsContext, _ s: CGSize, _ m: CompanionMood, _ t: Double, _ pointer: CGPoint?,
                                 _ tint: Color, _ dark: Bool, asleep: Bool) {
        let u = min(s.width, s.height)
        var c = CGPoint(x: s.width / 2, y: s.height / 2)
        var R = u * 0.26
        var speed = 0.35, bright = 0.7
        switch m {
        case .sleeping: speed = 0.08; bright = 0.3
        case .calm: speed = 0.35
        case .busy: speed = 1.4; bright = 1
        case .alert: speed = 0.9; bright = 1; R *= 1 + 0.08 * sin(t * 6)
        case .happy: speed = 0.8; bright = 0.9
        case .upset: speed = 0.4; c.x += sin(t * 51) * u * 0.01
        }
        var yaw = t * speed + 0.6, pitch = 0.45 + 0.25 * sin(t * 0.5 * max(speed, 0.2))
        if m == .upset { yaw += sin(t * 37) * 0.06; pitch += cos(t * 43) * 0.05 }
        if let p = pointer {
            yaw += max(-1.5, min(1.5, (p.x - c.x) / (u / 2))) * 0.5
            pitch += max(-1.5, min(1.5, (p.y - c.y) / (u / 2))) * 0.5
        }
        let fg = dark ? blend(tint, .white, 0.28) : blend(tint, .black, 0.12)
        if asleep { ctx.opacity = 0.6 }

        func project(_ v: SIMD3<Double>) -> (CGPoint, Double) {
            let k = 5 / (5 - v.z)
            return (CGPoint(x: c.x + v.x * R * k, y: c.y - v.y * R * k), min(1, max(0, (v.z + 1.5) / 3)))
        }
        // glow
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - R * 1.5, y: c.y - R * 1.5, width: R * 3, height: R * 3)),
                 with: .radialGradient(Gradient(colors: [fg.opacity(0.28 * bright), fg.opacity(0)]), center: c, startRadius: 0, endRadius: R * 1.5))

        struct Dot { var v: SIMD3<Double>; var size: Double; var alpha: Double }
        var dots: [Dot] = []
        let rings: [(Double, Double, Double)] = [(0.4, 0.0, 1.30), (-0.9, 0.7, 1.35), (1.3, -0.5, 1.25)]
        for (ri, ring) in rings.enumerated() { for j in 0..<3 {
            let a = t * speed * 1.6 * (ri % 2 == 0 ? 1 : -1) * (0.8 + 0.2 * Double(ri)) + Double(j) * 2.094 + Double(ri)
            var p = SIMD3(ring.2 * cos(a), 0, ring.2 * sin(a))
            p = SIMD3(p.x, p.y * cos(ring.0) - p.z * sin(ring.0), p.y * sin(ring.0) + p.z * cos(ring.0))
            p = SIMD3(p.x * cos(ring.1) - p.y * sin(ring.1), p.x * sin(ring.1) + p.y * cos(ring.1), p.z)
            dots.append(Dot(v: rot(p, yaw: yaw, pitch: pitch), size: 1, alpha: bright))
        } }
        if m == .happy {   // celebratory burst, repeats
            let q = t.truncatingRemainder(dividingBy: 1.8) / 1.8
            for i in 0..<10 {
                let ph = Double(i) * 2.399, z = 1 - 2 * (Double(i) + 0.5) / 10, rr = (1 - z * z).squareRoot()
                let d = SIMD3(rr * cos(ph), z, rr * sin(ph)) * (0.9 + q * 0.65)
                dots.append(Dot(v: d, size: 0.8, alpha: pow(1 - q, 1.5)))
            }
        }
        let dotColor = blend(fg, dark ? .white : .black, 0.25)   // once per frame, not per dot
        let projected = dots.map { ($0, project($0.v)) }          // project each dot once
        func drawDot(_ d: Dot, _ pd: (CGPoint, Double)) {
            let (p, dep) = pd
            let rad = u * 0.024 * (0.7 + 0.6 * dep) * d.size
            let a = (0.35 + 0.65 * dep) * d.alpha
            if bright > 0.8 { ctx.fill(Path(ellipseIn: CGRect(x: p.x - rad * 2.2, y: p.y - rad * 2.2, width: rad * 4.4, height: rad * 4.4)), with: .color(fg.opacity(0.18 * a))) }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)), with: .color(dotColor.opacity(a)))
        }
        for (d, pd) in projected where pd.1 < 0.5 { drawDot(d, pd) }

        let rv = ico.v.map { rot($0, yaw: yaw, pitch: pitch) }
        let pv = rv.map(project)
        let wscale = max(0.8, u / 60)
        for (i, j) in ico.e.sorted(by: { (pv[$0.0].1 + pv[$0.1].1) < (pv[$1.0].1 + pv[$1.1].1) }) {
            let d = (pv[i].1 + pv[j].1) / 2
            var path = Path(); path.move(to: pv[i].0); path.addLine(to: pv[j].0)
            ctx.stroke(path, with: .color(fg.opacity(0.14 + 0.86 * pow(d, 1.3))), style: StrokeStyle(lineWidth: (0.5 + 1.1 * d) * wscale, lineCap: .round))
        }
        for p in pv {
            let r = (0.5 + 1.0 * p.1) * wscale
            ctx.fill(Path(ellipseIn: CGRect(x: p.0.x - r, y: p.0.y - r, width: r * 2, height: r * 2)), with: .color(fg.opacity(0.3 + 0.7 * p.1)))
        }
        for (d, pd) in projected where pd.1 >= 0.5 { drawDot(d, pd) }
    }
}
