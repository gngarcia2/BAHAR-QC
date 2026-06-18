//
//  LocationManager.swift
//  BAHAR QC
//
//  Thin CoreLocation wrapper. Publishes the latest fix, authorization status,
//  and any error so SwiftUI views can react. Uses the legacy delegate API
//  rather than CLLocationUpdate so authorization changes also flow through
//  one path.
//

import Combine
import CoreLocation
import SwiftUI

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var lastLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        authorizationStatus = manager.authorizationStatus
    }

    func start() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestAlwaysAuthorization()
            #endif
            return
        }
        if status == .authorizedAlways { manager.startUpdatingLocation(); return }
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        if status == .authorizedWhenInUse { manager.startUpdatingLocation() }
        #endif
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        let status = manager.authorizationStatus
        if status == .authorizedAlways {
            manager.startUpdatingLocation()
            return
        }
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        if status == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
        #endif
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            lastLocation = loc
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
    }
}
