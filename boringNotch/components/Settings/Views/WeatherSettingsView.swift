//
//  WeatherSettingsView.swift
//  boringNotch
//

import CoreLocation
import Defaults
import SwiftUI

struct WeatherSettingsView: View {
    @Default(.showWeather) var showWeather
    @Default(.weatherUseCurrentLocation) var useCurrentLocation
    @Default(.weatherCityName) var cityName
    @Default(.weatherUnit) var unit
    @ObservedObject var weather = WeatherManager.shared

    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var searchFailed = false

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showWeather) {
                    Text("Show weather in the open notch")
                }
                if showWeather {
                    status
                }
            } header: {
                Text("General")
            } footer: {
                Text(
                    "The current temperature appears next to the battery. Click it for the forecast. Weather data comes from Open-Meteo.",
                    comment: "Footer explaining the weather feature."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                Picker("Location", selection: $useCurrentLocation) {
                    Text("Current location").tag(true)
                    Text("A city").tag(false)
                }
                if !useCurrentLocation {
                    if !cityName.isEmpty {
                        LabeledContent("City") { Text(cityName) }
                    }
                    TextField("Search for a city", text: $query)
                        .onChange(of: query) { search() }
                    if searchFailed {
                        Text("Couldn't search right now.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(results) { place in
                        Button {
                            choose(place)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(place.name)
                                if !place.detail.isEmpty {
                                    Text(place.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Picker("Units", selection: $unit) {
                    Text("System").tag(WeatherUnit.system)
                    Text("Celsius").tag(WeatherUnit.celsius)
                    Text("Fahrenheit").tag(WeatherUnit.fahrenheit)
                }
            } header: {
                Text("Location")
            }
            .disabled(!showWeather)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Weather")
    }

    @ViewBuilder
    private var status: some View {
        if let snapshot = weather.snapshot {
            Label {
                Text(verbatim: "\(snapshot.place.isEmpty ? "" : snapshot.place + " · ")\(Int(snapshot.temperature.rounded()))° · \(WeatherCondition.description(for: snapshot.code))")
            } icon: {
                Image(systemName: WeatherCondition.symbol(for: snapshot.code, isDay: snapshot.isDay))
                    .symbolRenderingMode(.multicolor)
            }
            .font(.caption)
        } else if let error = weather.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if weather.isLoading {
            ProgressView().controlSize(.small)
        }
    }

    private func search() {
        searchTask?.cancel()
        let text = query
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let places = try await WeatherManager.searchPlaces(text)
                guard !Task.isCancelled else { return }
                results = places
                searchFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                searchFailed = true
            }
        }
    }

    private func choose(_ place: WeatherPlace) {
        cityName = place.name
        Defaults[.weatherLatitude] = place.latitude
        Defaults[.weatherLongitude] = place.longitude
        query = ""
        results = []
    }
}
