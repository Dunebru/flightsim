import Airports
import FlightModel
public import SwiftUI

/// Free flight setup: aircraft, start position, time of day, weather. Choices persist.
public struct FreeFlightSetupView: View {
    @Bindable var settings: AppSettings
    let onStart: () -> Void
    let onBack: () -> Void

    public init(settings: AppSettings, onStart: @escaping () -> Void, onBack: @escaping () -> Void) {
        self.settings = settings
        self.onStart = onStart
        self.onBack = onBack
    }

    /// The bundled airport layouts (small JSON files), loaded once.
    private static let layouts: [AirportLayout] = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Airports"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { try? AirportLayout.load($0) }.sorted { $0.icao > $1.icao }
    }()

    private var layout: AirportLayout? { Self.layouts.first { $0.icao == settings.airport } ?? Self.layouts.first }

    /// Hours the airport's clock is ahead of UTC today (Phoenix keeps UTC-7 all year; Los
    /// Angeles observes daylight saving time).
    private var utcOffset: Double {
        Double((layout?.timeZone ?? .gmt).secondsFromGMT(for: settings.flightDate())) / 3600
    }

    private var localHour: Binding<Double> {
        Binding(
            get: {
                let utc = settings.fixedUTCHour ?? 19.5
                return (utc + utcOffset + 24).truncatingRemainder(dividingBy: 24)
            },
            set: { local in settings.fixedUTCHour = (local - utcOffset + 24).truncatingRemainder(dividingBy: 24) }
        )
    }

    private var airportBinding: Binding<String> {
        Binding(get: { settings.airport }, set: { icao in
            settings.airport = icao
            if let l = Self.layouts.first(where: { $0.icao == icao }), !l.startSpots.contains(settings.spot) {
                settings.spot = l.startSpots.first ?? settings.spot
            }
        })
    }

    private var profile: AircraftProfile {
        AircraftProfile.all.first { $0.id == settings.aircraftID } ?? .c172
    }

    public var body: some View {
        ZStack {
            WorldPlaceholder().ignoresSafeArea()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 18) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(height: 44)
                    }
                    .buttonStyle(.glass)
                    Text("Free Flight")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(profile.name + " · " + settings.airport + " · " + settings.spot.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HUDStyle.secondaryText)
                    Spacer(minLength: 0)
                    Button(action: onStart) {
                        Label("Start", systemImage: "airplane.departure")
                            .font(.system(size: 17, weight: .semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                }
                .frame(width: 240, alignment: .leading)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("Aircraft") {
                            Picker("Aircraft", selection: $settings.aircraftID) {
                                ForEach(AircraftProfile.all) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.segmented)
                            Text(profile.fidelityNote)
                                .font(.system(size: 12))
                                .foregroundStyle(HUDStyle.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        section("Airport") {
                            Picker("Airport", selection: airportBinding) {
                                ForEach(Self.layouts, id: \.icao) { Text($0.icao).tag($0.icao) }
                            }
                            .pickerStyle(.segmented)
                            if let layout {
                                Text(layout.name.capitalized)
                                    .font(.system(size: 12))
                                    .foregroundStyle(HUDStyle.secondaryText)
                            }
                        }
                        section("Start") {
                            if let spots = layout?.startSpots {
                                Picker("Start", selection: $settings.spot) {
                                    Section("Runways") {
                                        ForEach(spots.filter { if case .runway = $0 { true } else { false } }, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    Section("Approaches") {
                                        ForEach(spots.filter { if case .final = $0 { true } else { false } }, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    Section("Gates") {
                                        ForEach(spots.filter { if case .stand = $0 { true } else { false } }, id: \.self) { Text($0.label).tag($0) }
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.white)
                            }
                        }
                        section("Time of day") {
                            Toggle("Real time", isOn: Binding(
                                get: { settings.fixedUTCHour == nil },
                                set: { settings.fixedUTCHour = $0 ? nil : 19.5 }
                            ))
                            .tint(HUDStyle.engaged)
                            if settings.fixedUTCHour != nil {
                                HStack {
                                    Slider(value: localHour, in: 0...23.75, step: 0.25)
                                        .tint(.white)
                                    Text(String(format: "%02d:%02d", Int(localHour.wrappedValue), Int((localHour.wrappedValue.truncatingRemainder(dividingBy: 1)) * 60)))
                                        .font(HUDStyle.metric(17))
                                        .foregroundStyle(.white)
                                        .frame(width: 64, alignment: .trailing)
                                }
                                Text("Local time at \(settings.airport). The sun is placed from the date and time.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(HUDStyle.secondaryText)
                            }
                        }
                        section("Weather") {
                            Label("Clear, no wind", systemImage: "sun.max.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                            Text("Live METAR weather, clouds and wind arrive in M7.")
                                .font(.system(size: 12))
                                .foregroundStyle(HUDStyle.secondaryText)
                        }
                    }
                    .padding(20)
                }
                .frame(maxWidth: 460)
                .glassEffect(HUDStyle.glass, in: .rect(cornerRadius: 28, style: .continuous))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .preferredColorScheme(.dark)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HUDStyle.secondaryText)
            content()
        }
        .foregroundStyle(.white)
    }
}
