// One-shot location lookup used by Settings to fill in the operator's
// Maidenhead grid. Kept as its own object so the main-actor controller
// doesn't have to host CLLocationManager's non-isolated delegate.

import CoreLocation

final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((String?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Requests authorization if needed and returns a 6-char grid, or nil.
    func fetchGrid(_ completion: @escaping (String?) -> Void) {
        // A second request supersedes the first — resolve the old caller
        // (its spinner would otherwise hang forever) before replacing it.
        if let previous = self.completion {
            DispatchQueue.main.async { previous(nil) }
        }
        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            finish(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if completion != nil { manager.requestLocation() }
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { finish(nil); return }
        finish(Maidenhead.grid(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ grid: String?) {
        let block = completion
        completion = nil
        DispatchQueue.main.async { block?(grid) }
    }
}
