import XCTest
@testable import HuecastCore

/// Expected values come from the web app (js/palette.js, js/conditions.js),
/// so the Mac sky matches huecast.app colour for colour
final class PaletteTests: XCTestCase {
    func assertColor(_ c: RGB, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = RGB(hex: hex)
        // one 8-bit step of slack for floating point differences
        for (a, b) in [(c.r, e.r), (c.g, e.g), (c.b, e.b)] {
            XCTAssertEqual(a, b, accuracy: 1.5 / 255, "\(c.hex) != \(hex)", file: file, line: line)
        }
    }

    func testHexRoundTrip() {
        XCTAssertEqual(RGB(hex: "#F5FFAE").hex, "#f5ffae")
    }

    func testTemperatureColours() {
        assertColor(Palette.color(celsius: 10), "#936891")
        assertColor(Palette.color(celsius: 21), "#ff9a47")
        assertColor(Palette.color(celsius: 50), "#EA5455")   // beyond the last stop
        assertColor(Palette.color(celsius: -40), "#16224A")  // before the first
    }

    func testTimeColours() {
        assertColor(Palette.color(hour: 15), "#ffb400")
        assertColor(Palette.color(hour: 1), "#020202")
    }

    func testMix() {
        assertColor(Palette.mix(RGB(hex: "#563761"), RGB(hex: "#ffd460")), "#c66f6c")
    }

    func testSkyColoursRainyNight() {
        let c = Conditions.condition(code: 63, wind: 30)
        let sky = Palette.skyColors(hour: 21, temp: -3, isDay: false, fx: c.fx)
        assertColor(sky.time, "#2f2023")
        assertColor(sky.temp, "#394b5a")
    }

    func testSkyColoursSnowyMorning() {
        let c = Conditions.condition(code: 75, wind: 5, data: HourData(snow: 6))
        let sky = Palette.skyColors(hour: 10, temp: -8, isDay: true, fx: c.fx)
        assertColor(sky.time, "#f2f7c4")
        assertColor(sky.temp, "#6c8aaf")
    }

    func testSkyHourStretchesDaylight() {
        // a 10 hour day: 4 hours after sunrise is 40% of the way to sunset
        let hour = Sky.skyHour(12, t: 1000 + 3600 * 4, daylight: [SunTimes(rise: 1000, set: 1000 + 3600 * 10)])
        XCTAssertEqual(hour, 12.2, accuracy: 1e-9)
        // polar night: the clock hour as is
        XCTAssertEqual(Sky.skyHour(12, t: 5000, daylight: [SunTimes(rise: 1000, set: 1000)]), 12)
    }

    func testSunIntensity() {
        XCTAssertEqual(Sky.sunIntensity(42).name, "Scorching")
        XCTAssertEqual(Sky.sunIntensity(22).pulses, 2)
        XCTAssertEqual(Sky.sunIntensity(-10).name, "Mild")
    }
}

final class ConditionTests: XCTestCase {
    func testRain() {
        let c = Conditions.condition(code: 63, wind: 30)
        XCTAssertEqual(c.label, "rain")
        XCTAssertEqual(c.fx.rain, 100)
        XCTAssertEqual(c.fx.rainLevel, 3)
        XCTAssertEqual(c.fx.clouds, 11)
        XCTAssertEqual(c.fx.darken, 0.12, accuracy: 1e-9)
        XCTAssertEqual(c.fx.wind, 10)
        XCTAssertEqual(c.fx.slant, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.fx.sat, 0.481, accuracy: 1e-9)
        XCTAssertTrue(c.fx.veil)
    }

    func testBlizzardBringsWind() {
        let c = Conditions.condition(code: 75, wind: 5, data: HourData(snow: 6))
        XCTAssertEqual(c.levels.snow, 5)
        XCTAssertEqual(c.levels.wind, 4)
        XCTAssertEqual(c.fx.wind, 28)
        XCTAssertEqual(c.fx.sat, 0.7, accuracy: 1e-9)
        XCTAssertEqual(c.fx.lift, 0.3, accuracy: 1e-9)
    }

    func testThickCloud() {
        let c = Conditions.condition(code: 2, data: HourData(cloud: 90, lowCloud: 95))
        XCTAssertEqual(c.fx.clouds, 14)
        XCTAssertEqual(c.fx.thick, 14)
        XCTAssertEqual(c.fx.darken, 0.1, accuracy: 1e-9)
        XCTAssertEqual(c.fx.sat, 0.53, accuracy: 1e-9)
    }

    func testFogCodeIsAtLeastFog() {
        let c = Conditions.condition(code: 45, data: HourData(vis: 20000))
        XCTAssertEqual(c.levels.fog, 2)
    }

    func testMarks() {
        XCTAssertNil(Conditions.marks(Levels()))
        var l = Levels()
        l.snow = 5
        XCTAssertEqual(Conditions.marks(l)?.count, 3)
        XCTAssertEqual(Conditions.marks(l)?.snow, true)
    }

    func testAllCodesHaveLabels() {
        for code in Conditions.codes {
            XCTAssertFalse(Conditions.condition(code: code).label.isEmpty)
        }
    }
}

final class ForecastParsingTests: XCTestCase {
    func testParse() throws {
        // two local days of hours (UTC+1), now at 10:30 on day one
        let start = 1_700_000_000.0 - 1_700_000_000.0.truncatingRemainder(dividingBy: 86400) - 3600
        let hours = (0..<48).map { start + Double($0) * 3600 }
        let now = start + 10.5 * 3600
        func list(_ v: (Int) -> String) -> String { "[" + (0..<48).map(v).joined(separator: ",") + "]" }
        let json = """
        {
          "utc_offset_seconds": 3600,
          "current": {"time": \(now), "temperature_2m": 12.5, "apparent_temperature": 10, "weather_code": 61, "is_day": 1, "wind_speed_10m": 8},
          "hourly": {
            "time": \(list { "\(hours[$0])" }),
            "temperature_2m": \(list { "\($0)" }),
            "apparent_temperature": \(list { _ in "null" }),
            "weather_code": \(list { _ in "3" }),
            "is_day": \(list { "\($0 % 24 >= 7 && $0 % 24 < 19 ? 1 : 0)" }),
            "wind_speed_10m": \(list { _ in "5" }),
            "rain": \(list { _ in "0.5" }),
            "showers": \(list { _ in "0.25" })
          },
          "daily": {
            "time": [\(start), \(start + 86400)],
            "sunrise": [\(start + 7 * 3600), \(start + 31 * 3600)],
            "sunset": [\(start + 19 * 3600), \(start + 43 * 3600)],
            "temperature_2m_min": [0, 24],
            "temperature_2m_max": [23, 47],
            "weather_code": [3, 61]
          }
        }
        """
        let f = try WeatherAPI.parseForecast(Data(json.utf8))
        XCTAssertEqual(f.offset, 3600)
        XCTAssertEqual(f.next.count, 25)
        XCTAssertTrue(f.next[0].isNow)
        XCTAssertEqual(f.next[0].code, 61)
        XCTAssertEqual(f.next[0].data.rain, 0.75)
        XCTAssertEqual(f.next[1].time, start + 11 * 3600)
        XCTAssertNil(f.next[1].feels)
        XCTAssertEqual(f.days.count, 1)
        XCTAssertEqual(f.days[0].hours.count, 24)
        XCTAssertEqual(f.days[0].max, 47)
        XCTAssertEqual(f.daylight.count, 2)
    }
}
