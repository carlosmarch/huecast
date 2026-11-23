import Foundation

/// Usage analytics for the Mac app: Google Analytics 4 through the
/// Measurement Protocol, into the same property as huecast.app, so the
/// website and the app can be seen side by side (`platform` = macos).
///
/// Off unless the app bundle's Info.plist has `GAMeasurementID` and
/// `GAAPISecret`. build-app.sh writes them from the GA_MEASUREMENT_ID and
/// GA_API_SECRET environment variables (repository secrets in CI), so they
/// are never in the source. Also off for `swift run`, `-demo`, screenshot
/// runs, and after `defaults write app.huecast.mac analytics -bool false`.
///
/// Events never include coordinates or place names. Event names follow the
/// web app's (js/track.js) where the action is the same.
@MainActor
enum Analytics {
    private static let info = Bundle.main.infoDictionary ?? [:]
    private static let measurementID = (info["GAMeasurementID"] as? String) ?? ""
    private static let apiSecret = (info["GAAPISecret"] as? String) ?? ""

    static let enabled: Bool = {
        guard !measurementID.isEmpty, !apiSecret.isEmpty,
              Bundle.main.bundleURL.pathExtension == "app",
              !CommandLine.arguments.contains("-demo"),
              AppModel.argument("-snapshots") == nil else { return false }
        return UserDefaults.standard.object(forKey: "analytics") as? Bool ?? true
    }()

    /// a random id for this Mac, kept between launches (GA's client id)
    private static let clientID: String = {
        let key = "analyticsClientID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "\(UInt32.random(in: 1...UInt32.max)).\(Int(Date().timeIntervalSince1970))"
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// one session per launch
    private static let sessionID = String(Int(Date().timeIntervalSince1970))
    private static var once = Set<String>()

    private static let version = (info["CFBundleShortVersionString"] as? String) ?? "dev"
    private static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Record an event. Params: a few short strings or numbers
    static func track(_ name: String, _ params: [String: Any] = [:]) {
        guard enabled else { return }
        var p = params
        p["session_id"] = sessionID
        p["engagement_time_msec"] = 100
        p["platform"] = "macos"
        p["app_version"] = version
        let body: [String: Any] = [
            "client_id": clientID,
            "events": [["name": name, "params": p]],
            "device": [
                "category": "desktop",
                "operating_system": "macOS",
                "operating_system_version": osVersion,
                "language": Locale.preferredLanguages.first ?? "",
            ],
        ]
        send(body)
    }

    /// The same, at most once per launch (e.g. the first timeline scrub)
    static func trackOnce(_ name: String, _ params: [String: Any] = [:]) {
        guard once.insert(name).inserted else { return }
        track(name, params)
    }

    private static func send(_ body: [String: Any]) {
        var c = URLComponents(string: "https://www.google-analytics.com/mp/collect")!
        c.queryItems = [
            URLQueryItem(name: "measurement_id", value: measurementID),
            URLQueryItem(name: "api_secret", value: apiSecret),
        ]
        guard let url = c.url, let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()   // fire and forget
    }
}
