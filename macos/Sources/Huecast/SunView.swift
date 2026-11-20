import SwiftUI
import HuecastCore

/// What the circle shows
struct SunState: Hashable {
    enum Kind: Hashable { case loading, empty, sun, moon }
    var kind: Kind
    var veiled = false
    var intensity = SunIntensity.none
    var halo = 0.0
    var edge = false // a hairline on very pale skies
}

/// The sun or the moon, with the original pulses, glow and ice halo
struct SunView: View {
    var state: SunState
    var size: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch state.kind {
            case .loading: loader
            case .empty:
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            case .sun: sun
            case .moon: moon
            }
        }
        .frame(width: size, height: size)
        // the halo and glow reach far outside the circle without sizing it
        .background { if state.halo > 0 { halo } }
        .id(state) // a new look pops in, like the web version's popIn
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: state)
    }

    private var sun: some View {
        let i = state.intensity
        return ZStack {
            if !reduceMotion && i.pulses > 0 {
                TimelineView(.animation) { t in
                    let now = t.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<i.pulses, id: \.self) { n in
                            let p = ((now + Double(n) * i.duration / Double(i.pulses)) / i.duration)
                                .truncatingRemainder(dividingBy: 1)
                            let pulse = Self.pulse(p, big: i.big)
                            Circle().fill(.white)
                                .frame(width: size, height: size)
                                .scaleEffect(pulse.scale)
                                .opacity(pulse.opacity)
                        }
                    }
                }
            }
            Circle()
                .fill(.white.opacity(state.veiled ? 0.78 : 1))
                .blur(radius: state.veiled ? 1.5 : 0)
                .overlay(Circle().strokeBorder(.black.opacity(state.edge ? 0.05 : 0), lineWidth: 1))
        }
        .frame(width: size, height: size)
        .background {
            if i.shining {
                // glow as a radial gradient around the disc
                let k: CGFloat = i.blazing ? 4 : 3.2
                Circle()
                    .fill(RadialGradient(stops: [
                        .init(color: .white.opacity(0.65), location: 0.3),
                        .init(color: .white.opacity(0.22), location: 0.55),
                        .init(color: .white.opacity(0), location: 1),
                    ], center: .center, startRadius: 0, endRadius: size * k / 2))
                    .frame(width: size * k, height: size * k)
                    .allowsHitTesting(false)
            }
        }
    }

    private var moon: some View {
        TimelineView(.animation(paused: reduceMotion)) { t in
            // opacityMoon: 1 -> 0.9 -> 0.6 -> 1 every 3s
            let p = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
            let o = reduceMotion ? 1 : Self.keyframes(p, [(0, 1), (0.5, 0.9), (0.6, 0.6), (1, 1)])
            Circle()
                .fill(.white.opacity(0.2))
                .overlay(Circle().strokeBorder(.white, lineWidth: max(1.5, size * 0.058)))
                .opacity(o)
        }
    }

    /// Very cold: a thin ring well outside the circle (warm inner edge,
    /// white, cool outer edge), breathing slowly
    private var halo: some View {
        let d = size * 2.9
        return TimelineView(.animation(paused: reduceMotion)) { t in
            let breathe = reduceMotion ? 1 : 0.85 + 0.15 * cos(t.date.timeIntervalSinceReferenceDate * .pi / 7)
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: .clear, location: 0.8),
                    .init(color: Color(red: 1, green: 214 / 255, blue: 196 / 255, opacity: 0.24), location: 0.85),
                    .init(color: .white.opacity(0.34), location: 0.885),
                    .init(color: Color(red: 196 / 255, green: 220 / 255, blue: 1, opacity: 0.2), location: 0.92),
                    .init(color: .clear, location: 0.96),
                ], center: .center, startRadius: 0, endRadius: d / 2))
                .frame(width: d, height: d)
                .opacity(state.halo * breathe)
        }
        .allowsHitTesting(false)
    }

    /// The app icon at the size of the sun, its sun breathing
    private var loader: some View {
        TimelineView(.animation(paused: reduceMotion)) { t in
            let now = t.date.timeIntervalSinceReferenceDate
            let breathe = 1 + 0.06 * sin(now * 2 * .pi / 2.4)
            let drift = sin(now * .pi / 3) * size * 0.04
            ZStack {
                LinearGradient(colors: [Color(Tokens.timeNoon), Color(Tokens.tempVeryHot)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                Rectangle().fill(.white.opacity(0.18)).frame(height: size * 0.02)
                    .offset(x: drift, y: size * (0.461 + 0.01 - 0.5))
                Rectangle().fill(.white.opacity(0.12)).frame(height: size * 0.043)
                    .offset(x: -drift, y: size * (0.527 + 0.0215 - 0.5))
                Circle().fill(.white).frame(width: size * 0.375, height: size * 0.375).scaleEffect(breathe)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }

    /// pulseAnim / pulseAnim2x: scale 0 -> 0.9 -> 1.4 (2.4), opacity 0 -> 0.5 -> 0
    static func pulse(_ p: Double, big: Bool) -> (scale: Double, opacity: Double) {
        let easeOut = { (t: Double) in 1 - (1 - t) * (1 - t) }
        if p < 0.45 {
            let t = easeOut(p / 0.45)
            return (0.9 * t, 0.5 * t)
        }
        let t = easeOut((p - 0.45) / 0.55)
        return (0.9 + ((big ? 2.4 : 1.4) - 0.9) * t, 0.5 * (1 - t))
    }

    static func keyframes(_ p: Double, _ k: [(Double, Double)]) -> Double {
        for i in 1..<k.count where p <= k[i].0 {
            let (p0, v0) = k[i - 1], (p1, v1) = k[i]
            return v0 + (v1 - v0) * (p - p0) / (p1 - p0)
        }
        return k.last!.1
    }
}
