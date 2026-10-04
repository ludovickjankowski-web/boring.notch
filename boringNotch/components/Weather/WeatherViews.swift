//
//  WeatherViews.swift
//  boringNotch
//
//  Weather in the open notch's header, with a forecast popover.
//

import Defaults
import SwiftUI

/// WMO weather interpretation codes, as used by Open-Meteo.
enum WeatherCondition {
    static func symbol(for code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: return "cloud.rain.fill"
        case 65, 67, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func description(for code: Int) -> String {
        switch code {
        case 0: return String(localized: "Clear")
        case 1: return String(localized: "Mostly clear")
        case 2: return String(localized: "Partly cloudy")
        case 3: return String(localized: "Overcast")
        case 45, 48: return String(localized: "Fog")
        case 51, 53, 55: return String(localized: "Drizzle")
        case 56, 57: return String(localized: "Freezing drizzle")
        case 61, 63, 80, 81: return String(localized: "Rain")
        case 65, 82: return String(localized: "Heavy rain")
        case 66, 67: return String(localized: "Freezing rain")
        case 71, 73, 77, 85: return String(localized: "Snow")
        case 75, 86: return String(localized: "Heavy snow")
        case 95: return String(localized: "Thunderstorm")
        case 96, 99: return String(localized: "Thunderstorm with hail")
        default: return String(localized: "Cloudy")
        }
    }
}

private func degrees(_ value: Double) -> String {
    "\(Int(value.rounded()))°"
}

struct WeatherHeaderButton: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var weather = WeatherManager.shared
    @State private var showPopover = false
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        if let snapshot = weather.snapshot {
            Button {
                withAnimation { showPopover.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: WeatherCondition.symbol(for: snapshot.code, isDay: snapshot.isDay))
                        .symbolRenderingMode(.multicolor)
                    Text(degrees(snapshot.temperature))
                        .font(.callout)
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(ScaleButtonStyle())
            .help("\(snapshot.place.isEmpty ? "" : snapshot.place + " · ")\(WeatherCondition.description(for: snapshot.code))")
            .onHover { hovering in
                isHoveringButton = hovering
                hovering ? cancelHide() : scheduleHide()
            }
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                WeatherPopover(snapshot: snapshot)
                    .onHover { hovering in
                        isHoveringPopover = hovering
                        hovering ? cancelHide() : scheduleHide()
                    }
            }
            .onChange(of: showPopover) { vm.isPopoverActive = showPopover }
            .onDisappear {
                cancelHide()
                vm.isPopoverActive = false
            }
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    /// Same behaviour as the battery popover: it closes shortly after the pointer leaves.
    private func scheduleHide() {
        guard !isHoveringButton, !isHoveringPopover else { return }
        cancelHide()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation { showPopover = false }
        }
    }
}

private struct WeatherPopover: View {
    let snapshot: WeatherSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: WeatherCondition.symbol(for: snapshot.code, isDay: snapshot.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    if !snapshot.place.isEmpty {
                        Text(snapshot.place)
                            .font(.headline)
                    }
                    Text(WeatherCondition.description(for: snapshot.code))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(degrees(snapshot.temperature))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("H \(degrees(snapshot.high))  L \(degrees(snapshot.low))", comment: "Today's high and low temperatures.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Label {
                    Text("Feels like \(degrees(snapshot.apparentTemperature))", comment: "Apparent temperature.")
                } icon: {
                    Image(systemName: "thermometer.medium")
                }
                if let chance = snapshot.precipitationChance {
                    Label {
                        Text("\(chance)%")
                    } icon: {
                        Image(systemName: "umbrella.fill")
                    }
                    .help("Chance of precipitation today")
                }
                Label {
                    Text("\(snapshot.humidity)%")
                } icon: {
                    Image(systemName: "humidity.fill")
                }
                .help("Humidity")
                Label {
                    Text(verbatim: "\(Int(snapshot.windSpeed.rounded())) \(snapshot.windUnit)")
                } icon: {
                    Image(systemName: "wind")
                }
                .help("Wind")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !snapshot.hours.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    ForEach(snapshot.hours) { hour in
                        VStack(spacing: 4) {
                            Text(hour.time.formatted(.dateTime.hour()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Image(systemName: WeatherCondition.symbol(for: hour.code, isDay: hour.isDay))
                                .symbolRenderingMode(.multicolor)
                                .frame(height: 18)
                            Text(degrees(hour.temperature))
                                .font(.caption)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if !snapshot.days.isEmpty {
                Divider()
                VStack(spacing: 6) {
                    ForEach(snapshot.days) { day in
                        HStack {
                            Text(day.date.formatted(.dateTime.weekday(.wide)))
                                .frame(width: 90, alignment: .leading)
                            Image(systemName: WeatherCondition.symbol(for: day.code))
                                .symbolRenderingMode(.multicolor)
                                .frame(width: 24)
                            if let chance = day.precipitationChance, chance >= 20 {
                                Text("\(chance)%")
                                    .font(.caption)
                                    .foregroundStyle(.cyan)
                            }
                            Spacer()
                            Text(degrees(day.low))
                                .foregroundStyle(.secondary)
                            Text(degrees(day.high))
                                .frame(width: 34, alignment: .trailing)
                        }
                        .font(.callout)
                        .monospacedDigit()
                    }
                }
            }

            Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)) · Open-Meteo", comment: "Weather data timestamp and source.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 300)
    }
}
