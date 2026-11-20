// Data sources - all free, HTTPS and keyless (port of js/weather.js):
//  - Open-Meteo forecast   https://open-meteo.com
//  - Open-Meteo geocoding  (city search)
//  - BigDataCloud          (reverse geocoding: coords -> city name)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Place: Codable, Hashable, Sendable, Identifiable {
    public var lat: Double
    public var lon: Double
    public var label: String

    public var id: String { String(format: "%.3f,%.3f", lat, lon) }

    public init(lat: Double, lon: Double, label: String) {
        self.lat = lat; self.lon = lon; self.label = label
    }

    /// Same place give or take a few hundred metres
    public func isSame(as other: Place) -> Bool {
        abs(lat - other.lat) < 0.01 && abs(lon - other.lon) < 0.01
    }
}

public struct SunTimes: Codable, Hashable, Sendable {
    public var rise: Double
    public var set: Double
    public init(rise: Double, set: Double) { self.rise = rise; self.set = set }
}

public struct Hour: Codable, Hashable, Sendable {
    public var time: Double      // unix seconds
    public var temp: Double
    public var feels: Double?
    public var code: Int
    public var isDay: Bool
    public var wind: Double
    public var data: HourData
    public var isNow = false

    public init(time: Double, temp: Double, feels: Double?, code: Int, isDay: Bool, wind: Double, data: HourData, isNow: Bool = false) {
        self.time = time; self.temp = temp; self.feels = feels; self.code = code
        self.isDay = isDay; self.wind = wind; self.data = data; self.isNow = isNow
    }
}

public struct Day: Codable, Hashable, Sendable {
    public var time: Double
    public var min: Double?
    public var max: Double?
    public var code: Int?
    public var hours: [Hour]
}

public struct Forecast: Codable, Hashable, Sendable {
    /// seconds east of UTC at the location
    public var offset: Double
    /// the next 24 hours, starting with the current conditions
    public var next: [Hour]
    /// the coming days after today, each with its 24 local hours
    public var days: [Day]
    public var daylight: [SunTimes]
}

public struct SearchResult: Hashable, Sendable, Identifiable {
    public var name: String
    public var region: String
    public var label: String
    public var lat: Double
    public var lon: Double
    public var id: String { "\(lat),\(lon)" }
    public var place: Place { Place(lat: lat, lon: lon, label: label) }
}

public enum WeatherError: LocalizedError {
    case http(Int, String)
    public var errorDescription: String? {
        switch self {
        case let .http(status, reason): return "HTTP \(status)" + (reason.isEmpty ? "" : " · \(reason)")
        }
    }
}

public enum WeatherAPI {
    static let forecastURL = "https://api.open-meteo.com/v1/forecast"
    static let searchURL = "https://geocoding-api.open-meteo.com/v1/search"
    static let reverseURL = "https://api.bigdatacloud.net/data/reverse-geocode-client"

    public static func forecast(lat: Double, lon: Double) async throws -> Forecast {
        let data = try await get(forecastURL, [
            "latitude": "\(lat)",
            "longitude": "\(lon)",
            "current": "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m",
            "hourly": "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m,wind_gusts_10m,rain,showers,snowfall,visibility,cloud_cover,cloud_cover_low,cloud_cover_mid",
            "daily": "sunrise,sunset,temperature_2m_min,temperature_2m_max,weather_code",
            "forecast_days": "7",
            "timezone": "auto",
            "timeformat": "unixtime",
        ])
        return try parseForecast(data)
    }

    /// Builds a Forecast from an Open-Meteo response (public for tests)
    public static func parseForecast(_ data: Data) throws -> Forecast {
        let r = try JSONDecoder().decode(ForecastResponse.self, from: data)
        let offset = r.utc_offset_seconds ?? 0
        let c = r.current
        let h = r.hourly

        func at(_ a: [Double?]?, _ i: Int) -> Double? {
            guard let a, i < a.count else { return nil }
            return a[i]
        }
        func amounts(_ i: Int) -> HourData {
            let rain = at(h.rain, i), showers = at(h.showers, i)
            return HourData(
                rain: rain == nil && showers == nil ? nil : (rain ?? 0) + (showers ?? 0),
                snow: at(h.snowfall, i),
                vis: at(h.visibility, i),
                gust: at(h.wind_gusts_10m, i),
                cloud: at(h.cloud_cover, i),
                lowCloud: thick(at(h.cloud_cover_low, i), at(h.cloud_cover_mid, i)))
        }
        func hour(_ i: Int) -> Hour {
            Hour(time: h.time[i],
                 temp: at(h.temperature_2m, i) ?? 0,
                 feels: at(h.apparent_temperature, i),
                 code: Int(at(h.weather_code, i) ?? 0),
                 isDay: (at(h.is_day, i) ?? 1) != 0,
                 wind: at(h.wind_speed_10m, i) ?? 0,
                 data: amounts(i))
        }

        // the hourly row covering "now" gives the current amounts
        let nowRow = h.time.firstIndex { $0 <= c.time && c.time < $0 + 3600 }
        let now = Hour(time: c.time, temp: c.temperature_2m ?? 0, feels: c.apparent_temperature,
                       code: c.weather_code ?? 0, isDay: (c.is_day ?? 1) != 0, wind: c.wind_speed_10m ?? 0,
                       data: nowRow.map(amounts) ?? HourData(), isNow: true)

        var next = [now]
        for i in h.time.indices where next.count < 25 && h.time[i] > c.time {
            next.append(hour(i))
        }

        // the coming days after today; days missing hours (clock changes) are left out
        var days: [Day] = []
        if let d = r.daily {
            let dayOf: (Double) -> Int = { Int(floor(($0 + offset) / 86400)) }
            var byDay: [Int: [Hour]] = [:]
            for i in h.time.indices { byDay[dayOf(h.time[i]), default: []].append(hour(i)) }
            for j in d.time.indices.dropFirst() {
                let hours = byDay[dayOf(d.time[j])] ?? []
                guard hours.count >= 23 else { continue }
                days.append(Day(time: d.time[j],
                                min: at(d.temperature_2m_min, j),
                                max: at(d.temperature_2m_max, j),
                                code: at(d.weather_code, j).map { Int($0) },
                                hours: hours))
            }
        }

        var daylight: [SunTimes] = []
        if let rise = r.daily?.sunrise, let set = r.daily?.sunset {
            daylight = zip(rise, set).compactMap { a, b in
                guard let a, let b else { return nil }
                return SunTimes(rise: a, set: b)
            }
        }
        return Forecast(offset: offset, next: next, days: days, daylight: daylight)
    }

    /// Low and mid cloud: the layers that grey the sky (high cloud is thin)
    static func thick(_ low: Double?, _ mid: Double?) -> Double? {
        if low == nil && mid == nil { return nil }
        return max(low ?? 0, mid ?? 0)
    }

    public static func reverseGeocode(lat: Double, lon: Double) async -> String {
        do {
            let data = try await get(reverseURL, ["latitude": "\(lat)", "longitude": "\(lon)", "localityLanguage": "en"])
            let d = try JSONDecoder().decode(ReverseResponse.self, from: data)
            let city = [d.city, d.locality, d.principalSubdivision].compactMap { $0 }.first { !$0.isEmpty }
            let country = [d.countryCode, d.countryName].compactMap { $0 }.first { !$0.isEmpty }
            return [city, country].compactMap { $0 }.joined(separator: ", ")
        } catch {
            return ""
        }
    }

    public static func search(_ query: String) async throws -> [SearchResult] {
        let data = try await get(searchURL, ["name": query, "count": "6", "language": "en", "format": "json"])
        let d = try JSONDecoder().decode(SearchResponse.self, from: data)
        return (d.results ?? []).map { r in
            let country = r.country_code ?? r.country ?? ""
            return SearchResult(
                name: r.name,
                region: [r.admin1, r.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                label: country.isEmpty ? r.name : "\(r.name), \(country)",
                lat: r.latitude,
                lon: r.longitude)
        }
    }

    static func get(_ base: String, _ params: [String: String]) async throws -> Data {
        var comps = URLComponents(string: base)!
        comps.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Open-Meteo explains bad requests: {"error": true, "reason": "..."}
            let reason = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.reason ?? ""
            throw WeatherError.http(http.statusCode, reason)
        }
        return data
    }
}

// MARK: - Response shapes

// swiftlint:disable identifier_name
struct ForecastResponse: Decodable {
    struct Current: Decodable {
        var time: Double
        var temperature_2m: Double?
        var apparent_temperature: Double?
        var weather_code: Int?
        var is_day: Int?
        var wind_speed_10m: Double?
    }
    struct Hourly: Decodable {
        var time: [Double]
        var temperature_2m: [Double?]?
        var apparent_temperature: [Double?]?
        var weather_code: [Double?]?
        var is_day: [Double?]?
        var wind_speed_10m: [Double?]?
        var wind_gusts_10m: [Double?]?
        var rain: [Double?]?
        var showers: [Double?]?
        var snowfall: [Double?]?
        var visibility: [Double?]?
        var cloud_cover: [Double?]?
        var cloud_cover_low: [Double?]?
        var cloud_cover_mid: [Double?]?
    }
    struct Daily: Decodable {
        var time: [Double]
        var sunrise: [Double?]?
        var sunset: [Double?]?
        var temperature_2m_min: [Double?]?
        var temperature_2m_max: [Double?]?
        var weather_code: [Double?]?
    }
    var utc_offset_seconds: Double?
    var current: Current
    var hourly: Hourly
    var daily: Daily?
}

struct ReverseResponse: Decodable {
    var city: String?
    var locality: String?
    var principalSubdivision: String?
    var countryCode: String?
    var countryName: String?
}

struct SearchResponse: Decodable {
    struct Result: Decodable {
        var name: String
        var admin1: String?
        var country: String?
        var country_code: String?
        var latitude: Double
        var longitude: Double
    }
    var results: [Result]?
}

struct ErrorResponse: Decodable {
    var reason: String?
}
// swiftlint:enable identifier_name
