import Foundation

/// A decoded METAR (surface weather observation).
public struct Metar: Sendable, Equatable {
    public enum Cover: String, Sendable { case few = "FEW", scattered = "SCT", broken = "BKN", overcast = "OVC", verticalVisibility = "VV" }

    public struct CloudLayer: Sendable, Equatable {
        public var cover: Cover
        /// Base above the field, feet.
        public var baseFeet: Int
        /// "CB" (cumulonimbus) or "TCU" (towering cumulus), when reported.
        public var type: String?
        /// Sky fraction covered: FEW 1-2/8, SCT 3-4/8, BKN 5-7/8, OVC 8/8.
        public var coverage: Double {
            switch cover {
            case .few: 0.19
            case .scattered: 0.44
            case .broken: 0.75
            case .overcast, .verticalVisibility: 1
            }
        }
    }

    public var station: String
    /// Day of month and time (UTC).
    public var day: Int, hour: Int, minute: Int
    /// Direction the wind blows from (degrees true); nil when variable.
    public var windDirection: Int?
    public var windKnots: Int
    public var gustKnots: Int?
    /// Prevailing visibility, metres (10 SM or more reads as 16,093).
    public var visibilityMetres: Double
    public var weather: [String]
    public var clouds: [CloudLayer]
    /// "CLR", "SKC", "NSC" or "CAVOK": no cloud reported.
    public var clear: Bool
    public var temperatureC: Double?
    public var dewpointC: Double?
    public var altimeterHPa: Double?
    public var raw: String

    /// The lowest broken, overcast or obscured layer (the ceiling), feet.
    public var ceilingFeet: Int? {
        clouds.filter { $0.cover == .broken || $0.cover == .overcast || $0.cover == .verticalVisibility }.map(\.baseFeet).min()
    }
}

public enum MetarParser {
    /// Decodes a METAR or SPECI. Unknown groups are skipped; nil only when the station or time
    /// cannot be read.
    public static func parse(_ raw: String) -> Metar? {
        var tokens = raw.uppercased().split(separator: " ").map(String.init)
        // Remarks are free text.
        if let rmk = tokens.firstIndex(of: "RMK") { tokens = Array(tokens[..<rmk]) }
        tokens.removeAll { $0 == "METAR" || $0 == "SPECI" || $0 == "AUTO" || $0 == "COR" || $0 == "$" || $0 == "=" }
        guard tokens.count >= 2, tokens[0].count == 4, tokens[0].allSatisfy(\.isLetter) else { return nil }
        let station = tokens[0]
        let time = tokens[1]
        guard time.count == 7, time.hasSuffix("Z"), let d = Int(time.prefix(2)), let h = Int(time.dropFirst(2).prefix(2)),
              let mi = Int(time.dropFirst(4).prefix(2)) else { return nil }
        var m = Metar(station: station, day: d, hour: h, minute: mi, windDirection: nil, windKnots: 0, gustKnots: nil,
                      visibilityMetres: 16_093, weather: [], clouds: [], clear: false, temperatureC: nil, dewpointC: nil,
                      altimeterHPa: nil, raw: raw)
        var i = 2
        var wholeMiles: Double?
        while i < tokens.count {
            let t = tokens[i]
            defer { i += 1 }
            // Wind: dddssKT, dddssGggKT, VRBssKT, also MPS.
            if t.hasSuffix("KT") || t.hasSuffix("MPS"), t.count >= 7 {
                let mps = t.hasSuffix("MPS")
                let body = t.dropLast(mps ? 3 : 2)
                let dir = body.prefix(3)
                let rest = body.dropFirst(3)
                let parts = rest.split(separator: "G")
                guard let speed = parts.first.flatMap({ Int($0) }) else { continue }
                let factor = mps ? 1.943_84 : 1
                m.windDirection = dir == "VRB" ? nil : Int(dir)
                m.windKnots = Int((Double(speed) * factor).rounded())
                if parts.count > 1, let g = Int(parts[1]) { m.gustKnots = Int((Double(g) * factor).rounded()) }
                continue
            }
            // Variable direction range (dddVddd): kept as the reported mean.
            if t.count == 7, t.dropFirst(3).first == "V", Int(t.prefix(3)) != nil { continue }
            // Visibility in statute miles: "10SM", "3/4SM", "1 1/2SM" (whole part in its own token), "M1/4SM".
            if t.hasSuffix("SM") {
                let v = t.dropLast(2).replacingOccurrences(of: "M", with: "").replacingOccurrences(of: "P", with: "")
                var miles: Double?
                if v.contains("/") {
                    let f = v.split(separator: "/")
                    if f.count == 2, let a = Double(f[0]), let b = Double(f[1]), b > 0 { miles = a / b + (wholeMiles ?? 0) }
                } else {
                    miles = Double(v)
                }
                if let miles { m.visibilityMetres = miles * 1_609.344 }
                wholeMiles = nil
                continue
            }
            if t.count == 1, let w = Double(t), i + 1 < tokens.count, tokens[i + 1].hasSuffix("SM") { wholeMiles = w; continue }
            // Visibility in metres: four digits (9999 = 10 km or more).
            if t.count == 4, let metres = Int(t) { m.visibilityMetres = metres == 9999 ? 10_000 : Double(metres); continue }
            if t == "CAVOK" { m.visibilityMetres = 10_000; m.clear = true; continue }
            if t == "CLR" || t == "SKC" || t == "NSC" || t == "NCD" { m.clear = true; continue }
            // Runway visual range (R08/1800FT): not used.
            if t.hasPrefix("R"), t.contains("/"), t.dropFirst().first?.isNumber == true { continue }
            // Cloud layers: FEW015, BKN250CB, VV002.
            if let cover = Metar.Cover.allCasesByPrefix(t) {
                let digits = t.dropFirst(cover.rawValue.count).prefix(3)
                if let h = Int(digits) {
                    let type = t.dropFirst(cover.rawValue.count + 3)
                    m.clouds.append(.init(cover: cover, baseFeet: h * 100, type: type.isEmpty || type == "///" ? nil : String(type)))
                }
                continue
            }
            // Temperature and dewpoint: 21/16, M05/M10, 02/M01.
            if t.contains("/"), !t.hasPrefix("A"), !t.hasPrefix("Q") {
                let f = t.split(separator: "/", omittingEmptySubsequences: false)
                func temp(_ s: Substring) -> Double? {
                    s.hasPrefix("M") ? Int(s.dropFirst()).map { -Double($0) } : Int(s).map(Double.init)
                }
                if f.count == 2, let a = temp(f[0]) { m.temperatureC = a; m.dewpointC = temp(f[1]); continue }
            }
            // Altimeter: A3002 (inHg x 100) or Q1013 (hPa).
            if t.count == 5, t.hasPrefix("A"), let a = Int(t.dropFirst()) { m.altimeterHPa = Double(a) / 100 * 33.863_9; continue }
            if t.count == 5, t.hasPrefix("Q"), let q = Int(t.dropFirst()) { m.altimeterHPa = Double(q); continue }
            // Present weather: -RA, +TSRA, BR, HZ, FG, VCSH...
            let wx = t.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            let codes = ["DZ", "RA", "SN", "SG", "PL", "GR", "GS", "UP", "BR", "FG", "FU", "VA", "DU", "SA", "HZ", "PY", "PO", "SQ", "FC", "SS", "DS", "TS", "SH", "FZ", "MI", "BC", "PR", "BL", "DR", "VC"]
            if !wx.isEmpty, wx.count.isMultiple(of: 2), stride(from: 0, to: wx.count, by: 2).allSatisfy({ k in
                codes.contains(String(wx.dropFirst(k).prefix(2)))
            }) {
                m.weather.append(t)
            }
        }
        return m
    }
}

extension Metar.Cover {
    static func allCasesByPrefix(_ t: String) -> Metar.Cover? {
        for c in [Metar.Cover.few, .scattered, .broken, .overcast] where t.hasPrefix(c.rawValue) && t.count >= 6 { return c }
        if t.hasPrefix("VV"), t.count >= 5 { return .verticalVisibility }
        return nil
    }
}
