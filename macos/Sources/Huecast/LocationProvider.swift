import CoreLocation

/// One-shot location: asks for permission when needed, then returns the
/// first fix. Fails (so the app falls back to the last place or a random
/// city) when location is denied, unavailable or takes over 10 seconds
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private var timeout: Task<Void, Never>?

    struct Unavailable: Error {}

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current() async throws -> CLLocationCoordinate2D {
        finish(.failure(CancellationError())) // a newer request wins
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { self?.finish(.failure(Unavailable())) }
            }
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(Unavailable()))
            default:
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        timeout?.cancel()
        timeout = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.continuation != nil else { return }
            switch status {
            case .notDetermined: break
            case .denied, .restricted: self.finish(.failure(Unavailable()))
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in self.finish(.success(coordinate)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
