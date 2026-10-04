//
//  WeatherManager.swift
//  boringNotch
//
//  Current weather and a short forecast from Open-Meteo (free, no API key),
//  for the user's current location or a city chosen in Settings. Refreshed
//  every 30 minutes while enabled, and after the Mac wakes.
//

import AppKit
import Combine
import CoreLocation
import Defaults
import Foundation
import OSLog

enum WeatherUnit: String, CaseIterable, Identifiable, Defaults.Serializable {
    case system
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var usesFahrenheit: Bool {
        switch self {
        case .system: return Locale.current.measurementSystem == .us
        case .celsius: return false
        case .fahrenheit: return true
        }
    }
}

struct WeatherSnapshot: Equatable {
    struct Hour: Equatable, Identifiable {
        let time: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
        var id: Date { time }
    }

    struct Day: Equatable, Identifiable {
        let date: Date
        let high: Double
        let low: Double
        let code: Int
        let precipitationChance: Int?
        var id: Date { date }
    }

    let place: String
    let temperature: Double
    let apparentTemperature: Double
    let code: Int
    let isDay: Bool
    let high: Double
    let low: Double
    let precipitationChance: Int?
    let hours: [Hour]
    let days: [Day]
    let fetchedAt: Date
}

struct WeatherPlace: Equatable, Identifiable {
    let name: String
    let detail: String
    let latitude: Double
    let longitude: Double
    var id: String { "\(latitude),\(longitude)" }
}

@MainActor
final class WeatherManager: NSObject, ObservableObject {
    static let shared = WeatherManager()

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    private static let log = Logger(subsystem: "theboringteam.boringnotch", category: "Weather")
    private static let refreshInterval: TimeInterval = 30 * 60

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer

        Defaults.publisher(keys: .showWeather, .weatherUseCurrentLocation, .weatherLatitude, .weatherLongitude, .weatherUnit)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor in self?.restart() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    self?.restart()
                }
            }
            .store(in: &cancellables)
    }

    /// Refreshes now if the data is stale, e.g. when the notch opens.
    func refreshIfStale() {
        guard Defaults[.showWeather], !isLoading else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < Self.refreshInterval { return }
        restart()
    }

    private func restart() {
        refreshTask?.cancel()
        guard Defaults[.showWeather] else {
            snapshot = nil
            error = nil
            return
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let (latitude, longitude, place) = await resolveLocation() else { return }
            snapshot = try await Self.fetchForecast(latitude: latitude, longitude: longitude, place: place)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Weather refresh failed: \(error.localizedDescription, privacy: .public)")
            // Keep showing the last forecast through a temporary outage.
            if snapshot == nil { self.error = String(localized: "Weather is unavailable right now.") }
        }
    }

    // MARK: Location

    private func resolveLocation() async -> (Double, Double, String)? {
        if Defaults[.weatherUseCurrentLocation] {
            guard let location = await currentLocation() else {
                error = String(localized: "Allow location access in System Settings, or choose a city.")
                return nil
            }
            let name = (try? await CLGeocoder().reverseGeocodeLocation(location).first)
                .flatMap { $0.locality ?? $0.name } ?? ""
            return (location.coordinate.latitude, location.coordinate.longitude, name)
        }
        guard Defaults[.weatherLatitude] != 0 || Defaults[.weatherLongitude] != 0 else {
            error = String(localized: "Choose a city in Settings > Weather.")
            return nil
        }
        return (Defaults[.weatherLatitude], Defaults[.weatherLongitude], Defaults[.weatherCityName])
    }

    private func currentLocation() async -> CLLocation? {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
        locationContinuation?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    // MARK: Open-Meteo

    private static func fetchForecast(latitude: Double, longitude: Double, place: String) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "4"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "temperature_unit", value: Defaults[.weatherUnit].usesFahrenheit ? "fahrenheit" : "celsius"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let forecast = try JSONDecoder().decode(Forecast.self, from: data)

        let now = Date()
        let hours = zip(forecast.hourly.time.indices, forecast.hourly.time)
            .map { index, time in
                WeatherSnapshot.Hour(
                    time: Date(timeIntervalSince1970: time),
                    temperature: forecast.hourly.temperature_2m[index] ?? 0,
                    code: forecast.hourly.weather_code[index] ?? 0,
                    isDay: (forecast.hourly.is_day[index] ?? 1) == 1
                )
            }
            .filter { $0.time > now }
            .prefix(6)
        let days = forecast.daily.time.indices.map { index in
            WeatherSnapshot.Day(
                date: Date(timeIntervalSince1970: forecast.daily.time[index]),
                high: forecast.daily.temperature_2m_max[index] ?? 0,
                low: forecast.daily.temperature_2m_min[index] ?? 0,
                code: forecast.daily.weather_code[index] ?? 0,
                precipitationChance: forecast.daily.precipitation_probability_max[index]
            )
        }
        guard let today = days.first else { throw URLError(.cannotParseResponse) }

        return WeatherSnapshot(
            place: place,
            temperature: forecast.current.temperature_2m,
            apparentTemperature: forecast.current.apparent_temperature,
            code: forecast.current.weather_code,
            isDay: forecast.current.is_day == 1,
            high: today.high,
            low: today.low,
            precipitationChance: today.precipitationChance,
            hours: Array(hours),
            days: Array(days.dropFirst()),
            fetchedAt: now
        )
    }

    /// City search for Settings, via Open-Meteo's geocoding API.
    static func searchPlaces(_ query: String) async throws -> [WeatherPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        struct Response: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let country: String?
                let admin1: String?
            }
            let results: [Result]?
        }
        return (try JSONDecoder().decode(Response.self, from: data).results ?? []).map {
            WeatherPlace(
                name: $0.name,
                detail: [$0.admin1, $0.country].compactMap { $0 }.joined(separator: ", "),
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
    }

    // swiftlint:disable identifier_name
    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Hourly: Decodable {
            let time: [TimeInterval]
            let temperature_2m: [Double?]
            let weather_code: [Int?]
            let is_day: [Int?]
        }
        struct Daily: Decodable {
            let time: [TimeInterval]
            let weather_code: [Int?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Int?]
        }
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }
    // swiftlint:enable identifier_name
}

extension WeatherManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            self.locationContinuation?.resume(returning: location)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationContinuation?.resume(returning: nil)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // The first request happens before the user answers the prompt; retry once allowed.
            if status == .authorizedAlways || status == .authorized, Defaults[.weatherUseCurrentLocation], self.snapshot == nil {
                self.restart()
            }
        }
    }
}
