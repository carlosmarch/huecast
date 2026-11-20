// Background colours. Port of js/palette.js: the 2016 palette, blended
// between stops in OKLCH so in-between colours stay clean (purple -> yellow
// passes through pink, not olive). Colour values are the tokens in
// css/tokens.css.

import Foundation

/// An sRGB colour, components 0...1
public struct RGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// "#RRGGBB" or "RRGGBB"
    public init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(s, radix: 16) ?? 0
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }

    public var hex: String {
        let c = [r, g, b].map { Int(($0 * 255).rounded()).clamped(0, 255) }
        return String(format: "#%02x%02x%02x", c[0], c[1], c[2])
    }

    public static let white = RGB(r: 1, g: 1, b: 1)
    public static let black = RGB(r: 0, g: 0, b: 0)
}

/// css/tokens.css
public enum Tokens {
    public static let timeNight = RGB(hex: "#000000")
    public static let timeDawn = RGB(hex: "#563761")
    public static let timeMorning = RGB(hex: "#F5FFAE")
    public static let timeNoon = RGB(hex: "#FFB400")
    public static let timeDusk = RGB(hex: "#56132A")
    public static let timeEvening = RGB(hex: "#1F1F1F")

    public static let tempPolar = RGB(hex: "#16224A")
    public static let tempIce = RGB(hex: "#24508C")
    public static let tempGlacier = RGB(hex: "#3A78AB")
    public static let tempFrost = RGB(hex: "#6AA2C4")
    public static let tempChilly = RGB(hex: "#4A5A6A")
    public static let tempCold = RGB(hex: "#48466D")
    public static let tempWarm = RGB(hex: "#F8A79B")
    public static let tempHot = RGB(hex: "#FFD460")
    public static let tempVeryHot = RGB(hex: "#EB586F")
    public static let tempDamnHot = RGB(hex: "#EA5455")

    public static let bg = RGB(hex: "#1b1b1b")
    public static let bgRaised = RGB(hex: "#2f2f2f")
    public static let veil = RGB(hex: "#333333")
    public static let inkDark = RGB(hex: "#2a2a2a")
}

public enum Palette {
    /// [celsius, colour]: midpoints of the original temperature buckets
    public static let tempStops: [(Double, RGB)] = [
        (-20, Tokens.tempPolar),
        (-10, Tokens.tempIce),
        (-5, Tokens.tempGlacier),
        (0, Tokens.tempFrost),
        (4, Tokens.tempChilly),
        (8, Tokens.tempCold),
        (12.5, Tokens.tempWarm),
        (17.5, Tokens.tempHot),
        (25, Tokens.tempVeryHot),
        (35, Tokens.tempDamnHot),
    ]

    /// [sky hour, colour] (cyclic). Sky hours put sunrise at 07:00 and
    /// sunset at 20:00 (see skyHour)
    public static let timeStops: [(Double, RGB)] = [
        (3, Tokens.timeNight),
        (7, Tokens.timeDawn),     // sunrise
        (9.5, Tokens.timeMorning),
        (13, Tokens.timeNoon),
        (17.5, Tokens.timeNoon),  // afternoon stays bright
        (20, Tokens.timeDusk),    // sunset
        (22, Tokens.timeEvening),
        (27, Tokens.timeNight),   // = 3h next day
    ]

    public static func color(celsius: Double) -> RGB {
        interpolate(tempStops, celsius)
    }

    public static func color(hour: Double) -> RGB {
        interpolate(timeStops, hour < 3 ? hour + 24 : hour)
    }

    /// Bad weather drains colour from the sky: sat 1 = untouched, 0 = grey
    public static func desaturate(_ c: RGB, _ sat: Double) -> RGB {
        if sat >= 1 { return c }
        let (l, ch, h) = OKLCH.from(c)
        return OKLCH.rgb(l * (0.92 + 0.08 * sat), ch * sat, h)
    }

    /// Night: darken toward the night colour but keep most of the hue
    public static func nightShade(_ c: RGB, _ night: RGB, _ t: Double = 0.55) -> RGB {
        let (l, ch, h) = OKLCH.from(c)
        let (ln, _, _) = OKLCH.from(night)
        return OKLCH.rgb(l + (ln - l) * t, ch * (1 - 0.45 * t), h)
    }

    /// Lift toward white: snowy skies are bright, not grey
    public static func lift(_ c: RGB, _ amount: Double) -> RGB {
        if amount == 0 { return c }
        let (l, ch, h) = OKLCH.from(c)
        return OKLCH.rgb(l + (1 - l) * amount, ch * (1 - amount * 0.4), h)
    }

    /// The two sky colours for an hour: time of day and temperature,
    /// adjusted for night and weather
    public static func skyColors(hour: Double, temp: Double, isDay: Bool, fx: Effects) -> (time: RGB, temp: RGB) {
        let hourColor = color(hour: hour)
        var tempColor = color(celsius: temp)
        if !isDay { tempColor = nightShade(tempColor, hourColor, 0.55) }
        let timeColor = desaturate(hourColor, fx.sat)
        tempColor = desaturate(tempColor, fx.sat)
        let up = fx.lift * (isDay ? 1 : 0.4)
        return (lift(timeColor, up), lift(tempColor, up))
    }

    /// Relative luminance (WCAG)
    public static func luminance(_ c: RGB) -> Double {
        0.2126 * toLinear(c.r) + 0.7152 * toLinear(c.g) + 0.0722 * toLinear(c.b)
    }

    /// Perceptual mix in OKLCH (shortest way round the hue circle)
    public static func mix(_ a: RGB, _ b: RGB, _ t: Double = 0.5) -> RGB {
        let (l1, c1, h1) = OKLCH.from(a)
        let (l2, c2, h2) = OKLCH.from(b)
        // a grey has no meaningful hue: borrow the other colour's
        let ha = c1 < 0.02 ? h2 : h1
        let hb = c2 < 0.02 ? h1 : h2
        var dh = hb - ha
        if dh > 180 { dh -= 360 }
        if dh < -180 { dh += 360 }
        return OKLCH.rgb(l1 + (l2 - l1) * t, c1 + (c2 - c1) * t, ha + dh * t)
    }

    static func interpolate(_ stops: [(Double, RGB)], _ value: Double) -> RGB {
        if value <= stops[0].0 { return stops[0].1 }
        for i in 1..<stops.count {
            let (v1, c1) = stops[i]
            if value <= v1 {
                let (v0, c0) = stops[i - 1]
                // ease so most of each bucket keeps its original colour
                return mix(c0, c1, smoothstep((value - v0) / (v1 - v0)))
            }
        }
        return stops[stops.count - 1].1
    }

    static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}

// MARK: - Sun, stars, sky hour

public struct SunIntensity: Sendable, Hashable {
    public let name: String
    public let pulses: Int
    public let big: Bool
    public let shining: Bool
    public let blazing: Bool
    public let duration: Double

    public static let none = SunIntensity(name: "", pulses: 0, big: false, shining: false, blazing: false, duration: 3)
}

public enum Sky {
    static let sunSteps: [(min: Double, step: SunIntensity)] = [
        (40, SunIntensity(name: "Scorching", pulses: 5, big: true, shining: true, blazing: true, duration: 2)),
        (30, SunIntensity(name: "Very hot", pulses: 4, big: true, shining: true, blazing: false, duration: 2.5)),
        (20, SunIntensity(name: "Hot", pulses: 2, big: true, shining: true, blazing: false, duration: 2.5)),
        (15, SunIntensity(name: "Warm", pulses: 1, big: false, shining: false, blazing: false, duration: 3)),
        (-.infinity, SunIntensity(name: "Mild", pulses: 0, big: false, shining: false, blazing: false, duration: 3)),
    ]

    public static func sunIntensity(_ celsius: Double) -> SunIntensity {
        sunSteps.first { celsius >= $0.min }?.step ?? .none
    }

    static let sunriseHour = 7.0
    static let sunsetHour = 20.0

    public static func isDayHour(_ hour: Double) -> Bool {
        hour >= sunriseHour && hour < sunsetHour
    }

    /// The hour the colours are picked for: the real sunrise lands on 07:00
    /// and the real sunset on 20:00, with the hours between stretched to
    /// fit. t: unix seconds. Polar day or night uses the clock hour as is
    public static func skyHour(_ hour: Double, t: Double, daylight: [SunTimes]) -> Double {
        let ok: (SunTimes) -> Bool = { $0.set - $0.rise > 1800 && $0.set - $0.rise < 86400 - 1800 }
        guard let first = daylight.first, let last = daylight.last, daylight.allSatisfy(ok) else { return hour }
        var events = [first.set - 86400]
        for d in daylight { events.append(d.rise); events.append(d.set) }
        events.append(last.rise + 86400)
        guard let i = events.firstIndex(where: { $0 > t }), i >= 1 else { return hour }
        let f = (t - events[i - 1]) / (events[i] - events[i - 1])
        let isDay = i % 2 == 0 // after a sunrise, before a sunset
        return isDay
            ? sunriseHour + f * (sunsetHour - sunriseHour)
            : (sunsetHour + f * (24 - sunsetHour + sunriseHour)).truncatingRemainder(dividingBy: 24)
    }

    /// Stars, from the original returnColorByCurrentTime side effects
    public static func stars(hour: Double) -> Int {
        if hour >= 19 || hour < 6 { return 80 }
        if hour >= 16 { return 50 }
        return 0
    }
}

// MARK: - sRGB <-> OKLCH (https://bottosson.github.io/posts/oklab/)

enum OKLCH {
    static func from(_ c: RGB) -> (Double, Double, Double) {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(B, A) * 180 / .pi
        if h < 0 { h += 360 }
        return (L, (A * A + B * B).squareRoot(), h)
    }

    static func rgb(_ L: Double, _ C: Double, _ H: Double) -> RGB {
        let a = C * cos(H * .pi / 180)
        let b = C * sin(H * .pi / 180)
        let l = pow3(L + 0.3963377774 * a + 0.2158037573 * b)
        let m = pow3(L - 0.1055613458 * a - 0.0638541728 * b)
        let s = pow3(L - 0.0894841775 * a - 1.2914855480 * b)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        // quantise to 8 bits like the web version's hex strings
        let q: (Double) -> Double = { (min(max(toGamma($0), 0), 1) * 255).rounded() / 255 }
        return RGB(r: q(r), g: q(g), b: q(bb))
    }

    private static func pow3(_ x: Double) -> Double { x * x * x }
}

func toLinear(_ v: Double) -> Double {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

func toGamma(_ v: Double) -> Double {
    v <= 0.0031308 ? 12.92 * v : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
