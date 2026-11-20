import SwiftUI
import AppKit
import HuecastCore

/// Everything the sky shows for one forecast hour. Shared by the big sky
/// and the timeline bars, so each bar is a small copy of that hour's sky
struct HourSky: Equatable {
    var hour: Hour
    var local: DateComponents   // local time at the location
    var clockHour: Double
    var skyHour: Double
    var condition: Condition
    var timeColor: RGB
    var tempColor: RGB

    var inkDark: Bool { Palette.luminance(Palette.mix(timeColor, tempColor)) > 0.55 }
}

enum TempUnit: String { case c = "C", f = "F" }

enum Status: Equatable {
    case locating
    case loading
    case ready
    case failed(String, detail: String)
}

@MainActor
@Observable
final class AppModel {
    var place: Place?
    var forecast: Forecast?
    /// the day on the timeline (its start time), nil for the next 24 hours
    var viewDay: Double?
    var selected = 0
    var status: Status = .locating
    /// +1 / -1 while scrubbing, for the direction numbers roll
    var rollDirection = 0
    var unit: TempUnit = TempUnit(rawValue: UserDefaults.standard.string(forKey: Keys.unit) ?? "") ?? .c {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: Keys.unit) }
    }
    var pins: [Place] = AppModel.load([Place].self, Keys.pins) ?? [] {
        didSet { AppModel.save(pins, Keys.pins) }
    }
    /// updated every minute so "now" follows the clock
    var clock = Date()

    // overlays
    var showSearch = false
    var showDays = false
    var wallpaper = false
    var toast: String?
    /// the temperature next to the menu bar icon
    var menuBarTemperature = UserDefaults.standard.object(forKey: "menuBarTemperature") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuBarTemperature, forKey: "menuBarTemperature") }
    }

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timers: [Task<Void, Never>] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private let location: LocationProvider

    enum Keys {
        static let unit = "unit"
        static let pins = "pins"
        static let place = "place"
    }

    init() {
        location = LocationProvider()
        timers = [
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.clock = Date()
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15 * 60))
                    await self?.refresh()
                }
            },
        ]
    }

    // MARK: - Derived

    /// The hours on the timeline: the next 24, or the day being viewed
    var hours: [Hour] {
        guard let f = forecast else { return [] }
        if let viewDay, let day = f.days.first(where: { $0.time == viewDay }) { return day.hours }
        return f.next
    }

    var current: HourSky? {
        let h = hours
        guard !h.isEmpty else { return nil }
        return sky(for: h[min(selected, h.count - 1)])
    }

    var range: (min: Double, max: Double) {
        let t = hours.map(\.temp)
        return (t.min() ?? 0, t.max() ?? 0)
    }

    var isPinned: Bool { place.map { p in pins.contains { $0.isSame(as: p) } } ?? false }

    func sky(for h: Hour) -> HourSky {
        let offset = forecast?.offset ?? 0
        let ts = h.isNow ? clock.timeIntervalSince1970 : h.time
        let local = Self.utc.dateComponents([.year, .month, .day, .hour, .minute, .weekday],
                                            from: Date(timeIntervalSince1970: ts + offset))
        let clockHour = Double(local.hour ?? 0) + Double(local.minute ?? 0) / 60
        let skyHour = Sky.skyHour(clockHour, t: ts, daylight: forecast?.daylight ?? [])
        let cond = Conditions.condition(code: h.code, wind: h.wind, data: h.data)
        let colors = Palette.skyColors(hour: skyHour, temp: h.temp, isDay: h.isDay, fx: cond.fx)
        return HourSky(hour: h, local: local, clockHour: clockHour, skyHour: skyHour,
                       condition: cond, timeColor: colors.time, tempColor: colors.temp)
    }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func toUnit(_ celsius: Double) -> Int {
        Int((unit == .f ? celsius * 9 / 5 + 32 : celsius).rounded())
    }

    // MARK: - Loading

    @ObservationIgnored private var started = false

    /// Called by the window and by the menu bar icon, whichever comes first.
    /// `-lat 40.4 -lon -3.7 -name Madrid` opens a fixed place
    func start() {
        guard !started else { return }
        started = true
        if let lat = Self.argument("-lat").flatMap({ Double($0) }), let lon = Self.argument("-lon").flatMap({ Double($0) }) {
            open(Place(lat: lat, lon: lon, label: Self.argument("-name") ?? ""))
        } else {
            locate(initial: true)
        }
    }

    func locate(initial: Bool = false) {
        if forecast == nil { status = .locating } else { showToast("Locating…") }
        loadTask?.cancel()
        loadTask = Task {
            do {
                let coords = try await location.current()
                await load(Place(lat: coords.latitude, lon: coords.longitude, label: ""), remember: true)
            } catch {
                if Task.isCancelled { return }
                if initial, let saved = Self.load(Place.self, Keys.place) {
                    await load(saved)
                } else {
                    showToast(initial ? "No location · random city" : "Location unavailable")
                    if initial { await load(randomCity()) }
                }
            }
        }
    }

    func open(_ place: Place) {
        loadTask?.cancel()
        loadTask = Task { await load(place) }
    }

    func openRandomCity() { open(randomCity()) }

    func retry() {
        if let place { open(place) } else { locate(initial: true) }
    }

    private func randomCity() -> Place {
        var c: City
        repeat { c = cities.randomElement()! } while place.map({ $0.label.hasPrefix(c.name + ",") }) ?? false
        return Place(lat: c.lat, lon: c.lon, label: c.label)
    }

    private func load(_ newPlace: Place, remember: Bool = false) async {
        place = newPlace
        status = .loading
        do {
            async let f = Self.forecastRetrying(newPlace)
            async let name = Self.name(for: newPlace)
            let (forecast, label) = try await (f, name)
            guard !Task.isCancelled, place == newPlace else { return }
            var p = newPlace
            p.label = label.isEmpty ? String(format: "%.2f, %.2f", p.lat, p.lon) : label
            place = p
            self.forecast = forecast
            viewDay = nil
            selected = 0
            rollDirection = 0
            clock = Date()
            status = .ready
            if remember { Self.save(p, Keys.place) }
            if Snapshots.directory != nil { Snapshots.run(self) }
        } catch {
            guard !Task.isCancelled, place == newPlace else { return }
            let message = (error as? URLError)?.code == .notConnectedToInternet ? "offline" : "no signal"
            status = .failed(message, detail: String(error.localizedDescription.prefix(120)))
            if Snapshots.directory != nil { Snapshots.run(self) }
        }
    }

    /// the value after a launch argument (read by hand: UserDefaults takes
    /// a negative number like `-3.7` for the next option)
    nonisolated static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// the place's own label, or its name from the coordinates
    nonisolated private static func name(for p: Place) async -> String {
        if !p.label.isEmpty { return p.label }
        return await WeatherAPI.reverseGeocode(lat: p.lat, lon: p.lon)
    }

    /// one more try after a timeout or a dropped connection
    nonisolated private static func forecastRetrying(_ p: Place) async throws -> Forecast {
        do {
            return try await WeatherAPI.forecast(lat: p.lat, lon: p.lon)
        } catch let error as URLError where [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
            try await Task.sleep(for: .seconds(1))
            return try await WeatherAPI.forecast(lat: p.lat, lon: p.lon)
        }
    }

    func refresh() async {
        guard let p = place, status == .ready else { return }
        guard let f = try? await WeatherAPI.forecast(lat: p.lat, lon: p.lon), place?.isSame(as: p) == true else { return }
        forecast = f
        // the day being viewed is gone: back to the next 24 hours
        if let viewDay, !f.days.contains(where: { $0.time == viewDay }) { self.viewDay = nil }
        selected = min(selected, max(hours.count - 1, 0))
        clock = Date()
    }

    // MARK: - Timeline

    func select(_ i: Int) {
        let i = min(max(i, 0), max(hours.count - 1, 0))
        guard i != selected else { return }
        rollDirection = i > selected ? 1 : -1
        selected = i
    }

    func showDay(_ time: Double?) {
        guard let f = forecast, time != viewDay else { return }
        viewDay = time
        rollDirection = 0
        if let time {
            // a day opens at midday
            selected = hours.firstIndex { sky(for: $0).local.hour == 12 } ?? 0
            let d = Self.utc.dateComponents([.weekday], from: Date(timeIntervalSince1970: time + f.offset))
            showToast("\(Format.weekday(d.weekday)) · right click the timeline to go back")
        } else {
            selected = 0
        }
    }

    // MARK: - Pins, units, toasts

    func togglePin() {
        guard let p = place else { return }
        if isPinned {
            pins.removeAll { $0.isSame(as: p) }
            showToast("Unpinned")
        } else {
            pins.insert(p, at: 0)
            showToast("Pinned to search")
        }
    }

    func toggleUnit() { unit = unit == .c ? .f : .c }

    /// A huecast.app link to this place, on the clipboard
    func copyLink() {
        guard let p = place else { return }
        var c = URLComponents(string: "https://huecast.app/")!
        c.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", p.lat)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", p.lon)),
            URLQueryItem(name: "name", value: p.label),
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.url?.absoluteString ?? "", forType: .string)
        showToast("Link copied")
    }

    func showToast(_ text: String, seconds: Double = 2.5) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Storage

    nonisolated static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    nonisolated static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum Format {
    static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func weekday(_ w: Int?) -> String { days[((w ?? 1) - 1 + 7) % 7] }
    static func month(_ m: Int?) -> String { months[((m ?? 1) - 1 + 12) % 12] }

    /// "Friday, 20 Nov"
    static func date(_ c: DateComponents) -> String {
        "\(weekday(c.weekday)), \(c.day ?? 1) \(month(c.month))"
    }

    static func pad(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
}
