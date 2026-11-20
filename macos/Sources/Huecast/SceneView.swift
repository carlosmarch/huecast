import SwiftUI
import HuecastCore

/// Environment renderer, port of js/scene.js. Everything is drawn into one
/// Canvas: square stars, 1px rain, round snow, thin translucent cloud bands,
/// wide fog bands, wind streaks and thunder flashes.
///
/// Changing the weather never rebuilds the scene: each layer keeps the
/// particles it has, fades in the ones it needs and fades out the rest, so
/// scrubbing through the forecast morphs from hour to hour.
struct SceneState: Equatable {
    var fx: Effects
    var stars: Int
    var timeColor: RGB
}

struct SceneView: View {
    var state: SceneState?
    /// the sun's vertical extent, where cloud bands cross it
    var anchor: ClosedRange<CGFloat>

    @State private var engine = SceneEngine()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                engine.draw(ctx, size: size, time: timeline.date.timeIntervalSinceReferenceDate, still: reduceMotion)
            }
            .ignoresSafeArea()
        }
        .onChange(of: state, initial: true) { _, new in
            engine.anchor = anchor
            engine.set(new, instant: reduceMotion)
        }
        .onChange(of: anchor) { _, new in engine.anchor = new }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

final class SceneEngine {
    struct Particle {
        var x: Double = 0, y: Double = 0
        var size: Double = 0     // star side, cloud / fog band height, snow radius
        var len: Double = 0      // rain drop, wind streak
        var v: Double = 0        // speed, px/s
        var a: Double = 0        // alpha
        var phase: Double = 0
        var speed: Double = 0
        var tinted = false
        var life: Double = 1
        var dying = false
    }

    enum Layer: CaseIterable { case stars, clouds, fog, rain, snow, wind }

    static let refArea = 1440.0 * 900
    static let fade = 0.8

    /// where the sun is, for the cloud bands. It's known only after layout,
    /// so the clouds made before it move there when it arrives
    var anchor: ClosedRange<CGFloat> = 0...0 {
        didSet {
            guard anchor != oldValue, var clouds = layers[.clouds] else { return }
            for i in clouds.indices { clouds[i].y = cloudY() }
            layers[.clouds] = clouds
        }
    }

    /// a cloud band's height: across the sun, or mid sky until it's placed
    private func cloudY() -> Double {
        var top = Double(anchor.lowerBound), bottom = Double(anchor.upperBound)
        if bottom - top < 1 {
            top = Double(size.height) * 0.3
            bottom = Double(size.height) * 0.45
        }
        return rand(top, max(bottom, top + 1))
    }
    private var state: SceneState?
    private var layers: [Layer: [Particle]] = [:]
    private var thunder: [(cycle: Double, start: Double)] = []
    private var flashFade = 0.0
    private var tint = Color.white
    private var size = CGSize.zero
    private var last = 0.0
    private var now = 0.0

    func set(_ next: SceneState?, instant: Bool) {
        state = next
        update(instant: instant)
    }

    private func scale(_ n: Int) -> Int {
        let f = min(max(Double(size.width * size.height) / Self.refArea, 0.45), 1.6)
        return Int((Double(n) * f).rounded())
    }

    private func update(instant: Bool) {
        guard let state, size.width > 0 else { return }
        let fx = state.fx
        let want: [Layer: Int] = [
            .stars: scale(state.stars),
            .clouds: fx.clouds,
            .fog: fx.fog,
            .rain: scale(fx.rain),
            .snow: scale(fx.snow),
            .wind: scale(fx.wind),
        ]
        let life = instant ? 1.0 : 0.0
        for layer in Layer.allCases {
            var list = layers[layer] ?? []
            var alive = 0
            for i in list.indices where !list[i].dying {
                alive += 1
                if alive > want[layer]! { list[i].dying = true }
            }
            if alive < want[layer]! {
                for _ in alive..<want[layer]! {
                    var p = make(layer)
                    p.life = life
                    list.append(p)
                }
            }
            layers[layer] = list
        }
        // tinted stars: lifted toward white, or they vanish into a black sky
        tint = Color(Palette.mix(state.timeColor, .white, 0.65))
        // [cycle s, delay s] from the original thunder keyframes, timed from now
        let keys: [(Double, Double)] = [(3, 0), (10.5, 8.5), (6.2, 20.2), (7.4, 4.1)]
        thunder = keys
            .prefix(fx.thunder)
            .map { (cycle: $0.0, start: now + $0.1) }
    }

    private func make(_ layer: Layer) -> Particle {
        let W = Double(size.width), H = Double(size.height)
        let fx = state?.fx ?? Effects()
        var p = Particle()
        switch layer {
        case .stars:
            p.x = rand(0, W); p.y = rand(0, H / 3)
            p.size = floor(rand(1, 4))
            p.tinted = Bool.random()
            p.a = rand(0.15, 1)
            p.phase = rand(0, .pi * 2)
            p.speed = rand(0.5, 1.3) // each star breathes at its own pace
        case .clouds:
            p.y = cloudY(); p.size = rand(1, 30); p.a = rand(0.01, 0.08); p.phase = rand(0, 10)
        case .fog:
            // thicker fog reaches higher and is denser
            let lvl = Double(fx.fogLevel == 0 ? 2 : fx.fogLevel)
            let top = H * (0.62 - lvl * 0.1)
            p.y = rand(top, max(top + 1, H - 300)); p.size = rand(100, 450)
            p.a = rand(0.01, 0.07) * (0.6 + lvl * 0.25); p.phase = rand(0, 5)
        case .rain:
            // heavier rain: longer, faster drops
            let k = 0.75 + Double(fx.rainLevel == 0 ? 3 : fx.rainLevel) * 0.1
            p.x = rand(-W * 0.3, W); p.y = rand(-H, H); p.len = rand(5, 11) * k; p.v = rand(900, 1500) * k
        case .snow:
            // heavier snow: bigger flakes, and heavy / blizzard fall faster
            let lvl = Double(fx.snowLevel == 0 ? 3 : fx.snowLevel)
            let k = 0.8 + lvl * 0.1
            let fast = 1 + max(0, lvl - 3) * 0.25
            p.x = rand(0, W); p.y = rand(-H, H); p.size = rand(0.5, 2.2) * k; p.v = rand(35, 90) * fast
            p.phase = rand(0, .pi * 2)
        case .wind:
            p.x = rand(-W, W); p.y = rand(0, H); p.len = rand(40, 130); p.v = rand(500, 1100); p.a = rand(0.06, 0.18)
        }
        return p
    }

    private func age(_ dt: Double) {
        let step = dt / Self.fade
        for layer in Layer.allCases {
            guard var list = layers[layer] else { continue }
            for i in list.indices {
                if list[i].dying { list[i].life -= step } else if list[i].life < 1 { list[i].life = min(1, list[i].life + step) }
            }
            list.removeAll { $0.dying && $0.life <= 0 }
            layers[layer] = list
        }
    }

    func draw(_ ctx: GraphicsContext, size newSize: CGSize, time: Double, still: Bool) {
        let dt = last == 0 ? 0 : min(time - last, 0.05)
        last = time
        now = time
        if newSize != size {
            // positions depend on the window: start over, without fading
            size = newSize
            layers = [:]
            update(instant: true)
        }
        guard let state else { return }
        let fx = state.fx
        let W = Double(size.width), H = Double(size.height)
        if still {
            for layer in Layer.allCases {
                layers[layer] = layers[layer]?.filter { !$0.dying }.map { var p = $0; p.life = 1; return p }
            }
        } else {
            age(dt)
        }
        let white = { (a: Double) in Color.white.opacity(a) }

        // Stars - square like the original, each softly pulsing
        for s in layers[.stars] ?? [] {
            let pulse = still ? 1 : 0.35 + 0.65 * (0.5 + 0.5 * sin(time * s.speed + s.phase))
            let a = (s.tinted ? s.a * 0.5 : s.a) * s.life * pulse
            ctx.fill(Path(CGRect(x: s.x, y: s.y, width: s.size, height: s.size)),
                     with: .color(s.tinted ? tint.opacity(a) : white(a)))
        }

        // Cloud bands crossing the sun / moon
        for c in layers[.clouds] ?? [] {
            let bob = still ? 0 : sin((time + c.phase) * (.pi / 5)) * 3
            ctx.fill(Path(CGRect(x: 0, y: c.y + bob, width: W, height: c.size)), with: .color(white(c.a * c.life)))
        }

        // Fog bands
        for f in layers[.fog] ?? [] {
            let bob = still ? 0 : sin((time + f.phase) * (.pi / 2.5)) * 4
            ctx.fill(Path(CGRect(x: 0, y: f.y + bob, width: W, height: f.size)), with: .color(white(f.a * f.life)))
        }

        // Wind streaks - tapered, transparent at both ends
        if var wind = layers[.wind] {
            for i in wind.indices {
                if !still {
                    wind[i].x += wind[i].v * dt
                    if wind[i].x > W { wind[i].x = -wind[i].len - rand(0, W / 2); wind[i].y = rand(0, H) }
                }
                let w = wind[i]
                let g = Gradient(stops: [
                    .init(color: white(0), location: 0),
                    .init(color: white(w.a * w.life), location: 0.6),
                    .init(color: white(0), location: 1),
                ])
                ctx.fill(Path(CGRect(x: w.x, y: w.y, width: w.len, height: 1)),
                         with: .linearGradient(g, startPoint: CGPoint(x: w.x, y: w.y), endPoint: CGPoint(x: w.x + w.len, y: w.y)))
            }
            layers[.wind] = wind
        }

        // Rain - 1px drops, slanted by the wind
        let slant = fx.slant
        if var rain = layers[.rain] {
            var full = Path()
            for i in rain.indices {
                if !still {
                    rain[i].y += rain[i].v * dt
                    rain[i].x += rain[i].v * slant * dt
                    if rain[i].y > H { rain[i].y = rand(-60, -10); rain[i].x = rand(-W * 0.3, W) }
                }
                let d = rain[i]
                var p = Path()
                p.move(to: CGPoint(x: d.x, y: d.y))
                p.addLine(to: CGPoint(x: d.x + d.len * slant, y: d.y + d.len))
                if d.life >= 1 { full.addPath(p) } else { ctx.stroke(p, with: .color(white(0.55 * d.life)), lineWidth: 1) }
            }
            ctx.stroke(full, with: .color(white(0.55)), lineWidth: 1)
            layers[.rain] = rain
        }

        // Snow - round flakes swaying down
        if var snow = layers[.snow] {
            var full = Path()
            for i in snow.indices {
                if !still {
                    snow[i].y += snow[i].v * dt
                    snow[i].x += (sin(time * 1.5 + snow[i].phase) * 12 + snow[i].v * slant) * dt
                    if snow[i].y > H + 5 { snow[i].y = -5; snow[i].x = rand(0, W) }
                }
                let f = snow[i]
                let circle = Path(ellipseIn: CGRect(x: f.x - f.size, y: f.y - f.size, width: f.size * 2, height: f.size * 2))
                if f.life >= 1 { full.addPath(circle) } else { ctx.fill(circle, with: .color(white(0.9 * f.life))) }
            }
            ctx.fill(full, with: .color(white(0.9)))
            layers[.snow] = snow
        }

        // Thunder flashes (fade with the weather like everything else)
        flashFade = thunder.isEmpty ? 0 : min(1, flashFade + dt / Self.fade)
        if !still && !thunder.isEmpty {
            var flash = 0.0
            for t in thunder where time >= t.start {
                flash = max(flash, Self.thunderCurve((time - t.start).truncatingRemainder(dividingBy: t.cycle) / t.cycle))
            }
            if flash > 0 {
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(white(flash * (fx.flash == 0 ? 0.55 : fx.flash) * flashFade)))
            }
        }
    }

    /// Opacity curve copied from the original thunderAnim keyframes
    static func thunderCurve(_ p: Double) -> Double {
        let k: [(Double, Double)] = [(0.50, 0), (0.51, 1), (0.52, 0), (0.54, 0), (0.55, 1), (0.56, 0.5),
                                     (0.57, 1), (0.58, 0), (0.80, 0), (0.81, 1), (0.85, 0)]
        if p < k[0].0 || p > k[k.count - 1].0 { return 0 }
        for i in 1..<k.count where p <= k[i].0 {
            let (p0, v0) = k[i - 1], (p1, v1) = k[i]
            return v0 + (v1 - v0) * ((p - p0) / (p1 - p0))
        }
        return 0
    }
}

private func rand(_ lo: Double, _ hi: Double) -> Double {
    lo + Double.random(in: 0..<1) * (hi - lo)
}
