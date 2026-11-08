public import Foundation

/// The weather a flight uses: from a METAR, or clear skies when there is none (offline, or
/// weather turned off).
public struct WeatherConditions: Sendable, Equatable {
    public var windFromDegrees: Double
    public var windKnots: Double
    public var gustKnots: Double?
    public var visibilityMetres: Double
    public var clouds: [Metar.CloudLayer]
    public var temperatureC: Double
    public var dewpointC: Double?
    public var altimeterHPa: Double
    public var weather: [String]
    /// Where it came from: "KPHX 080451Z" or "Clear skies".
    public var source: String

    public static let clear = WeatherConditions(windFromDegrees: 0, windKnots: 0, gustKnots: nil, visibilityMetres: 40_000,
                                                clouds: [], temperatureC: 15, dewpointC: nil, altimeterHPa: 1013.25,
                                                weather: [], source: "Clear skies")

    public init(windFromDegrees: Double, windKnots: Double, gustKnots: Double?, visibilityMetres: Double,
                clouds: [Metar.CloudLayer], temperatureC: Double, dewpointC: Double?, altimeterHPa: Double,
                weather: [String], source: String) {
        self.windFromDegrees = windFromDegrees
        self.windKnots = windKnots
        self.gustKnots = gustKnots
        self.visibilityMetres = visibilityMetres
        self.clouds = clouds
        self.temperatureC = temperatureC
        self.dewpointC = dewpointC
        self.altimeterHPa = altimeterHPa
        self.weather = weather
        self.source = source
    }

    public init(metar m: Metar) {
        self.init(windFromDegrees: Double(m.windDirection ?? 0), windKnots: Double(m.windKnots),
                  gustKnots: m.gustKnots.map(Double.init),
                  // "10SM" means 10 miles or more: treat as a clear day's 40 km.
                  visibilityMetres: m.visibilityMetres >= 16_000 ? 40_000 : m.visibilityMetres,
                  clouds: m.clouds, temperatureC: m.temperatureC ?? 15, dewpointC: m.dewpointC,
                  altimeterHPa: m.altimeterHPa ?? 1013.25, weather: m.weather,
                  source: "\(m.station) \(String(format: "%02d%02d%02dZ", m.day, m.hour, m.minute))")
    }

    /// The wind, as the direction it blows toward (north, east), knots, at a height above the
    /// ground: the surface wind growing with the 1/7 power law to 2,000 ft, constant above (winds
    /// aloft are not used yet).
    public func wind(atHeightFeet h: Double) -> SIMD2<Double> {
        let factor = pow(max(min(h, 2_000), 33) / 33, 1.0 / 7.0)
        let speed = windKnots * factor
        let toward = (windFromDegrees + 180) * .pi / 180
        return SIMD2(cos(toward), sin(toward)) * speed
    }

    /// Temperature offset from the standard atmosphere at a field elevation (metres), Celsius.
    public func isaDeviation(fieldElevationMetres: Double) -> Double {
        temperatureC - (15 - 0.0065 * fieldElevationMetres)
    }
}

/// Live METARs from aviationweather.gov (US NWS Aviation Weather Center, public), cached for ten
/// minutes.
public actor WeatherService {
    public static let shared = WeatherService()
    private var cache: [String: (Metar, Date)] = [:]

    public init() {}

    /// The latest METAR for a station, or nil (offline, no report).
    public func metar(_ station: String) async -> Metar? {
        if let (m, fetched) = cache[station], Date().timeIntervalSince(fetched) < 600 { return m }
        guard let url = URL(string: "https://aviationweather.gov/api/data/metar?ids=\(station)&format=json") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("flightsim-personal-test", forHTTPHeaderField: "User-Agent")
        struct Record: Decodable { let rawOb: String? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let records = try? JSONDecoder().decode([Record].self, from: data),
              let raw = records.first?.rawOb, let m = MetarParser.parse(raw) else { return nil }
        cache[station] = (m, Date())
        return m
    }
}
