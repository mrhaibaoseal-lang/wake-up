import CoreLocation

/// 只抓一次目前位置（設定天氣位置用），不做持續定位
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { "沒有定位權限，請到 設定 > 起床 > 位置 允許「使用 App 期間」" }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    @MainActor
    func request() async throws -> CLLocation {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            proceed()
        }
    }

    private func proceed() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()  // 結果回到 didChangeAuthorization
        case .denied, .restricted: finish(.failure(Failure.denied))
        default: manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil, manager.authorizationStatus != .notDetermined else { return }
        proceed()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { finish(.success(location)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }
}
