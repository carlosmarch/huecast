import SwiftUI
import HuecastCore

extension Color {
    init(_ c: RGB, opacity: Double = 1) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
    }
}

/// Gradient stops blended in OKLCH, like `linear-gradient(... in oklch)`:
/// SwiftUI blends in sRGB, so the in-between colours are added as stops
func oklchStops(_ from: RGB, _ to: RGB, count: Int = 9) -> [Gradient.Stop] {
    (0..<count).map { i in
        let t = Double(i) / Double(count - 1)
        return Gradient.Stop(color: Color(Palette.mix(from, to, t)), location: t)
    }
}

/// Start and end points of a CSS `linear-gradient(<angle>deg, ...)` in a
/// box of this size: the line runs through the centre and is long enough
/// for the corners to get the end colours
func cssGradientPoints(angle degrees: Double, size: CGSize) -> (UnitPoint, UnitPoint) {
    let a = degrees * .pi / 180
    let dx = sin(a), dy = -cos(a)
    let w = max(size.width, 1), h = max(size.height, 1)
    let half = (abs(w * dx) + abs(h * dy)) / 2
    let start = UnitPoint(x: 0.5 - dx * half / w, y: 0.5 - dy * half / h)
    let end = UnitPoint(x: 0.5 + dx * half / w, y: 0.5 + dy * half / h)
    return (start, end)
}

struct CSSGradient: View {
    var from: RGB
    var to: RGB
    var angle: Double = -65

    var body: some View {
        GeometryReader { g in
            let (start, end) = cssGradientPoints(angle: angle, size: g.size)
            LinearGradient(stops: oklchStops(from, to), startPoint: start, endPoint: end)
        }
    }
}

struct SkyPaint: Equatable {
    var time: RGB
    var temp: RGB
}

/// Two gradient layers that cross-fade, plus the grey veil of bad weather.
/// Same recipe as the original: -65deg, time of day -> temperature
struct SkyView: View {
    var paint: SkyPaint?
    var darken: Double

    @State private var layers: [SkyPaint?] = [nil, nil]
    @State private var active = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CSSGradient(from: Tokens.bgRaised, to: Tokens.bg)
                .ignoresSafeArea()
            ForEach(0..<2, id: \.self) { i in
                if let p = layers[i] {
                    CSSGradient(from: p.time, to: p.temp)
                        .opacity(active == i ? 1 : 0)
                        .ignoresSafeArea()
                }
            }
            // every layer reaches under the title bar, or the top shows a band
            Color(Tokens.veil).opacity(darken)
                .ignoresSafeArea()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 2), value: active)
        .animation(reduceMotion ? nil : .easeInOut(duration: 2), value: darken)
        .onChange(of: paint, initial: true) { _, new in
            guard let new, new != layers[active] else { return }
            let next = active ^ 1
            layers[next] = new
            active = next
        }
        .ignoresSafeArea()
    }
}
