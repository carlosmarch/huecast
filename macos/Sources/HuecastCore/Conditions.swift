// Maps a forecast hour (WMO weather code + measured amounts) to a label and
// the effects that draw it. Port of js/conditions.js.
//
// Rain, snow, fog, storms and wind each go through intensity steps based on
// real amounts (mm/h, cm/h, visibility, km/h). When an amount is missing, a
// typical value for the weather code is used instead. Effect values are
// intensities for a ~1440x900 screen; the scene scales them to the window.

import Foundation

/// Measured amounts for one hour; any may be missing
public struct HourData: Codable, Hashable, Sendable {
    public var rain: Double?     // mm/h (rain + showers)
    public var snow: Double?     // cm/h
    public var vis: Double?      // m
    public var gust: Double?     // km/h
    public var cloud: Double?    // %
    public var lowCloud: Double? // % of low and mid cloud

    public init(rain: Double? = nil, snow: Double? = nil, vis: Double? = nil,
                gust: Double? = nil, cloud: Double? = nil, lowCloud: Double? = nil) {
        self.rain = rain; self.snow = snow; self.vis = vis
        self.gust = gust; self.cloud = cloud; self.lowCloud = lowCloud
    }
}

public struct Effects: Hashable, Sendable {
    public var clouds = 0
    public var thick = 0
    public var darken = 0.0
    public var rain = 0
    public var rainLevel = 0
    public var snow = 0
    public var snowLevel = 0
    public var lift = 0.0
    public var fog = 0
    public var fogLevel = 0
    public var thunder = 0
    public var flash = 0.0
    public var wind = 0
    public var windLevel = 0
    public var slant = 0.0
    public var sat = 1.0
    public var veil = false

    public init() {}
}

public struct Levels: Hashable, Sendable {
    public var rain = 0, snow = 0, storm = 0, wind = 0, fog = 0
}

public struct Condition: Hashable, Sendable {
    public let label: String
    public let fx: Effects
    public let levels: Levels
}

public enum Conditions {
    static let labels: [Int: String] = [
        0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast",
        45: "fog", 48: "rime fog",
        51: "light drizzle", 53: "drizzle", 55: "dense drizzle",
        56: "freezing drizzle", 57: "dense freezing drizzle",
        61: "light rain", 63: "rain", 65: "heavy rain",
        66: "freezing rain", 67: "heavy freezing rain",
        71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains",
        80: "rain showers", 81: "heavy showers", 82: "violent showers",
        85: "snow showers", 86: "heavy snow showers",
        95: "thunderstorm", 96: "thunderstorm with hail", 99: "heavy hail storm",
    ]

    public static var codes: [Int] { labels.keys.sorted() }

    public static func label(_ code: Int) -> String { labels[code] ?? labels[0]! }

    // Typical amounts per code, used when the forecast has no measurement
    static let typicalRain: [Int: Double] = [51: 0.2, 53: 0.4, 55: 0.8, 56: 0.3, 57: 0.8, 61: 1.2, 63: 4, 65: 10, 66: 1.5, 67: 8,
                                             80: 1.5, 81: 5, 82: 25, 95: 4, 96: 6, 99: 15]
    static let typicalSnow: [Int: Double] = [48: 0.1, 56: 0.1, 57: 0.2, 66: 0.2, 67: 0.4, 71: 0.3, 73: 1.5, 75: 3.5, 77: 0.5,
                                             85: 0.8, 86: 3, 96: 0.3, 99: 0.6]
    static let typicalVis: [Int: Double] = [45: 600, 48: 400]
    static let typicalCloud: [Int: Double] = [0: 0, 1: 20, 2: 45, 3: 100]

    public static let overcast = 80.0
    public static let calmWind = 12.0
    public static let mistVisibility = 5000.0
    public static let haloBelow = -5.0

    struct Step { var name: String; var max = Double.infinity; var min = 0.0
                  var count = 0; var clouds = 0; var darken = 0.0; var lift = 0.0; var wind = 0
                  var flash = 0.0 }

    static let rainSteps = [
        Step(name: "Drizzle", max: 0.5, count: 25, clouds: 6),
        Step(name: "Light", max: 2.5, count: 55, clouds: 8),
        Step(name: "Moderate", max: 7.6, count: 100, clouds: 11, darken: 0.12),
        Step(name: "Heavy", max: 20, count: 150, clouds: 14, darken: 0.2),
        Step(name: "Very heavy", max: 50, count: 210, clouds: 15, darken: 0.28),
        Step(name: "Violent", count: 280, clouds: 15, darken: 0.35),
    ]
    // snow brightens the sky (lift) instead of greying it
    static let snowSteps = [
        Step(name: "Flurries", max: 0.2, count: 25, clouds: 5, lift: 0.06),
        Step(name: "Light", max: 1, count: 50, clouds: 8, lift: 0.12),
        Step(name: "Moderate", max: 2.5, count: 90, clouds: 11, lift: 0.18),
        Step(name: "Heavy", max: 5, count: 240, clouds: 14, lift: 0.24),
        Step(name: "Blizzard", count: 360, clouds: 15, lift: 0.3, wind: 4),
    ]
    // visibility in metres: lower is thicker
    static let fogSteps = [
        Step(name: "Mist", min: 1000, count: 3, clouds: 3),
        Step(name: "Fog", min: 200, count: 5, clouds: 5, darken: 0.1),
        Step(name: "Dense fog", min: 0, count: 8, clouds: 6, darken: 0.18),
    ]
    static let stormSteps = [
        Step(name: "Distant thunder", count: 1, flash: 0.3),
        Step(name: "Thunderstorm", count: 2, flash: 0.55),
        Step(name: "With hail", count: 3, flash: 0.6),
        Step(name: "Severe", count: 4, flash: 0.75),
    ]
    static let windSteps = [
        Step(name: "Breeze", max: 25, count: 4),
        Step(name: "Fresh", max: 39, count: 10),
        Step(name: "Strong", max: 50, count: 18),
        Step(name: "Gale", max: 75, count: 28),
        Step(name: "Storm", count: 40),
    ]

    /// Step index (1-based) for an amount, 0 when there's nothing
    static func level(_ steps: [Step], below value: Double) -> Int {
        (steps.firstIndex { value < $0.max } ?? steps.count - 1) + 1
    }

    public static func rainLevel(_ mm: Double) -> Int { mm > 0.05 ? level(rainSteps, below: mm) : 0 }
    public static func snowLevel(_ cm: Double) -> Int { cm > 0.02 ? level(snowSteps, below: cm) : 0 }
    public static func windLevel(_ kmh: Double) -> Int { kmh >= calmWind ? level(windSteps, below: kmh) : 0 }
    public static func fogLevel(_ vis: Double) -> Int {
        guard vis < mistVisibility else { return 0 }
        return (fogSteps.firstIndex { vis >= $0.min } ?? fogSteps.count - 1) + 1
    }
    public static func stormLevel(_ code: Int, rain: Double) -> Int {
        switch code {
        case 99: return 4
        case 96: return 3
        case 95: return rain < 1 ? 1 : 2
        default: return 0
        }
    }

    /// The wind the scene draws: gusts count, softened
    public static func windSpeed(_ wind: Double, gust: Double?) -> Double {
        max(wind.isFinite ? wind : 0, (gust ?? 0) * 0.6)
    }

    /// Cloud cover (%) -> cloud bands, for the codes without rain, snow or
    /// fog. Only low and mid cloud greys the sky and hides the sun
    static func cloudFx(_ cover: Double, thick: Double?) -> Effects {
        let t = min(thick ?? cover, cover)
        var fx = Effects()
        fx.clouds = Int((cover * 0.15).rounded())
        fx.thick = Int((t * 0.15).rounded())
        if t > overcast { fx.darken = ((t - overcast) / (100 - overcast)) * 0.2 }
        return fx
    }

    public static func condition(code: Int, wind windKmh: Double = 0, data: HourData = HourData()) -> Condition {
        let rain = data.rain ?? typicalRain[code] ?? 0
        let snow = data.snow ?? typicalSnow[code] ?? 0
        let isFogCode = code == 45 || code == 48
        var vis = data.vis ?? typicalVis[code] ?? .infinity
        if isFogCode { vis = min(vis, 999) } // the code says fog: at least "Fog"
        let wind = windSpeed(windKmh, gust: data.gust)

        var levels = Levels()
        levels.rain = rainLevel(rain)
        levels.snow = snowLevel(snow)
        levels.storm = stormLevel(code, rain: rain)
        levels.wind = windLevel(wind)
        // low visibility is fog only when it isn't just heavy rain or snow
        if isFogCode || (levels.rain <= 1 && levels.snow <= 1) { levels.fog = fogLevel(vis) }

        let cover = code <= 3 ? (data.cloud ?? typicalCloud[code] ?? 0) : 0
        var fx = cover > 0 ? cloudFx(cover, thick: data.lowCloud) : Effects()
        // clouds that come with rain, snow, fog or storms are always thick
        func take(_ s: Step) {
            fx.clouds = max(fx.clouds, s.clouds)
            fx.thick = max(fx.thick, s.clouds)
            fx.darken = max(fx.darken, s.darken)
        }
        if levels.rain > 0 {
            let s = rainSteps[levels.rain - 1]
            fx.rain = s.count; fx.rainLevel = levels.rain; take(s)
        }
        if levels.snow > 0 {
            let s = snowSteps[levels.snow - 1]
            fx.snow = s.count; fx.snowLevel = levels.snow; take(s)
            fx.lift = s.lift
            if s.wind > 0 { levels.wind = max(levels.wind, s.wind) }
        }
        if levels.fog > 0 {
            let s = fogSteps[levels.fog - 1]
            fx.fog = s.count; fx.fogLevel = levels.fog; take(s)
        }
        if levels.storm > 0 {
            let s = stormSteps[levels.storm - 1]
            fx.thunder = s.count; fx.flash = s.flash
            fx.clouds = max(fx.clouds, 12)
            fx.thick = max(fx.thick, 12)
            fx.darken = max(fx.darken, 0.2 + Double(levels.storm) * 0.03)
        }
        if levels.wind > 0 {
            fx.wind = windSteps[levels.wind - 1].count
            fx.windLevel = levels.wind
        }
        // wind slants the rain and snow
        fx.slant = min(max(wind, levels.wind >= 5 ? 50 : 0) / 60, 0.6)

        // clouds, fog and precipitation drain colour from the sky...
        let wet = fx.rain > 0 ? 0.1 : 0
        let sat = 1 - Double(fx.thick) * 0.025 - fx.darken * 1.2 - Double(fx.fog) * 0.04 - wet
        fx.sat = sat.clamped(0.4, 1)
        if levels.snow > 0 && levels.rain == 0 { fx.sat = max(fx.sat, 0.7) } // snow keeps colour
        // ...and hide the sun behind a veil
        fx.veil = fx.thick >= 10 || levels.fog >= 2

        return Condition(label: label(code), fx: fx, levels: levels)
    }

    /// Timeline marks: rain ticks or snow dots, 1-3 by step
    public static func marks(_ levels: Levels) -> (snow: Bool, count: Int)? {
        let rain = levels.rain, snow = levels.snow
        if rain == 0 && snow == 0 { return nil }
        if snow > 0 && snow >= rain { return (true, Int((Double(snow * 3) / 5).rounded(.up))) }
        return (false, Int((Double(rain) / 2).rounded(.up)))
    }

    /// Ice halo around the sun or moon on very cold, fairly clear days:
    /// 0 = none, up to 1 (faint from -5°, full at -15°)
    public static func iceHalo(temp: Double, levels: Levels) -> Double {
        if temp > haloBelow || levels.rain > 0 || levels.snow >= 3 || levels.fog >= 2 { return 0 }
        return min(1, 0.55 + (haloBelow - temp) * 0.045)
    }
}
