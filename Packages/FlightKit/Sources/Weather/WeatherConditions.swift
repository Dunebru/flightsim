import Foundation

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

/// A cloud layer as a volume of air: what the renderer draws for a reported layer.
public struct CloudVolume: Sendable, Equatable {
    public enum Kind: Sendable { case stratus, cumulus, cumulonimbus, cirrus }
    /// Base and top, metres above sea level.
    public var baseMetres: Double
    public var topMetres: Double
    /// Fraction of the sky covered (FEW about 0.19, OVC 1).
    public var coverage: Double
    public var kind: Kind
}

extension WeatherConditions {
    /// The reported layers as volumes over a field (elevation in metres). The METAR gives only
    /// cover, base and sometimes CB or TCU, so the rest is climatology: few and scattered low
    /// clouds are cumulus about 1.4 km deep, broken and overcast layers are stratus a few hundred
    /// metres thick, anything based above 20,000 ft is cirrus, CB towers reach 11 km, TCU about
    /// 4.5 km above the base, and an obscured sky (VV) is fog from the ground up.
    public func cloudVolumes(fieldElevationMetres field: Double) -> [CloudVolume] {
        clouds.map { layer in
            let base = field + Double(layer.baseFeet) * 0.3048
            switch (layer.cover, layer.type) {
            case (_, "CB"?):
                return CloudVolume(baseMetres: base, topMetres: max(11_000, base + 5_000), coverage: layer.coverage, kind: .cumulonimbus)
            case (_, "TCU"?):
                return CloudVolume(baseMetres: base, topMetres: base + 4_500, coverage: layer.coverage, kind: .cumulus)
            case (.verticalVisibility, _):
                return CloudVolume(baseMetres: field - 30, topMetres: base + 150, coverage: 1, kind: .stratus)
            case _ where layer.baseFeet >= 20_000:
                return CloudVolume(baseMetres: base, topMetres: base + 400, coverage: layer.coverage, kind: .cirrus)
            case (.few, _), (.scattered, _):
                // Mid-level (altocumulus) cells are shallower than fair-weather cumulus.
                let depth = layer.baseFeet >= 10_000 ? 700.0 : 1_400.0
                return CloudVolume(baseMetres: base, topMetres: base + depth, coverage: layer.coverage, kind: .cumulus)
            case (.broken, _):
                return CloudVolume(baseMetres: base, topMetres: base + 500, coverage: layer.coverage, kind: .stratus)
            case (.overcast, _):
                return CloudVolume(baseMetres: base, topMetres: base + 700, coverage: layer.coverage, kind: .stratus)
            }
        }
    }

    /// How fast the obscuration thins with height (m): fog is a shallow layer, mist deeper, haze,
    /// smoke and dust fill the lower atmosphere.
    public var fogScaleHeightMetres: Double {
        let codes = weather.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+-")) }
        if codes.contains(where: { $0.hasSuffix("FG") }) || clouds.contains(where: { $0.cover == .verticalVisibility }) { return 120 }
        if codes.contains(where: { $0.hasSuffix("BR") }) { return 400 }
        if codes.contains(where: { ["HZ", "FU", "DU", "SA", "VA"].contains($0) }) { return 1_500 }
        // Reduced by precipitation or unreported: through the depth of the rain.
        return 800
    }

    /// MIL-spec turbulence severity (JSBSim's scale, 0 none to 7 extreme) at an altitude (m above
    /// sea level): gusty or strong surface wind stirs the lowest kilometre, and cloud is rough
    /// inside: light in stratus and cirrus, moderate in cumulus, severe in a cumulonimbus.
    public func turbulenceSeverity(altitudeMetres: Double, fieldElevationMetres field: Double) -> Int {
        let spread = (gustKnots ?? windKnots) - windKnots
        var severity = spread >= 10 ? 4 : (spread >= 5 || windKnots >= 15 ? 3 : (windKnots >= 8 ? 2 : 0))
        if altitudeMetres - field > 1_000 { severity = 0 }
        for v in cloudVolumes(fieldElevationMetres: field) where altitudeMetres >= v.baseMetres && altitudeMetres <= v.topMetres {
            let inside = switch v.kind {
            case .cumulonimbus: 5
            case .cumulus: v.coverage >= 0.4 ? 3 : 2
            case .stratus, .cirrus: 1
            }
            severity = max(severity, inside)
        }
        return severity
    }

    public enum PrecipitationKind: Sendable { case rain, drizzle, snow }

    /// What is falling at the field and how hard (0.35 light, 0.65 moderate, 1 heavy), from the
    /// present weather; showers in the vicinity (VC) are not overhead.
    public var precipitation: (kind: PrecipitationKind, intensity: Double)? {
        for w in weather {
            let code = w.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            if code.hasPrefix("VC") { continue }
            let intensity = w.hasPrefix("+") ? 1.0 : (w.hasPrefix("-") ? 0.35 : 0.65)
            if ["SN", "SG", "PL"].contains(where: { code.contains($0) }) { return (.snow, intensity) }
            if ["RA", "GR", "GS", "UP"].contains(where: { code.contains($0) }) { return (.rain, intensity) }
            if code.contains("DZ") { return (.drizzle, intensity) }
        }
        return nil
    }

    /// The wind at a height above the ground, metres per second toward (east, north).
    public func windVectorMetresPerSecond(atHeightFeet h: Double) -> SIMD2<Double> {
        let w = wind(atHeightFeet: h)
        return SIMD2(w.y, w.x) * 0.514_444
    }
}
