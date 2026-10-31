import CoreLocation
import Foundation

/// Position enregistrée avec une photo ou une vidéo.
struct LocationStamp: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var accuracy: Double
    var timestamp: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        accuracy = location.horizontalAccuracy
        timestamp = location.timestamp
    }

    var location: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: altitude,
                   horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: timestamp)
    }

    /// Format ISO 6709 des vidéos QuickTime : « +48.8566+002.3522+035.000/ ».
    var iso6709: String {
        String(format: "%+08.4f%+09.4f%+.3f/", latitude, longitude, altitude)
    }
}

/// Position de l'iPhone, seulement si l'option « Lieu » est activée (et autorisée).
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var denied = false

    private let manager = CLLocationManager()
    private var wanted = false
    private var active = false
    private let lock = NSLock()
    private var lastValue: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
    }

    /// Position récente (moins de 5 minutes), ou nil.
    var stamp: LocationStamp? {
        guard wanted, let last = lock.withLock({ lastValue }), -last.timestamp.timeIntervalSinceNow < 300 else { return nil }
        return LocationStamp(last)
    }

    func setEnabled(_ enabled: Bool) {
        wanted = enabled
        update()
    }

    func setActive(_ isActive: Bool) {
        active = isActive
        update()
    }

    private func update() {
        guard wanted, active else {
            manager.stopUpdatingLocation()
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            denied = false
            manager.startUpdatingLocation()
        default:
            denied = true
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        update()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        lock.withLock { lastValue = last }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
