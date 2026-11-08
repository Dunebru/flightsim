public import simd

/// A parking stand with a lead-in line, in the airport frame: where an aircraft stops, which way
/// it faces, the line it taxis in along, and what fits there.
public struct StandSlot: Sendable {
    public var ref: String?
    /// The stop position (metres east and north of the airport reference) and the heading
    /// (radians from north) of an aircraft parked on it.
    public var position: SIMD2<Double>
    public var heading: Double
    /// The lead-in line from the taxilane to the stop.
    public var line: [SIMD2<Double>]
    /// Room for a widebody (spacing to the next stand of 62 m or more).
    public var fitsWidebody: Bool
    /// A fixed per-stand random number in 0..<1 (the same every launch).
    public var seed: Double
    /// About three in four stands have a parked aircraft (those with seed under 0.75).
    public var occupied: Bool { seed < 0.75 }
    /// The parked aircraft is a widebody.
    public var parkedWidebody: Bool { fitsWidebody && seed < 0.4 }
}

extension AirportSite {
    /// Airliner stands: lead-in lines spaced at least 30 m apart (closer is general aviation).
    public var airlinerStands: [StandSlot] {
        let stops = layout.stands.filter { $0.line.count >= 2 }.map { (s: $0, p: xy($0.position)) }
        return stops.compactMap { stand, p -> StandSlot? in
            let spacing = stops.filter { $0.p != p }.map { simd_distance($0.p, p) }.min() ?? 100
            guard spacing >= 30 else { return nil }
            // A fixed hash of the stand's position (hashValue changes every launch).
            let ix = Int64((p.x * 10).rounded()), iy = Int64((p.y * 10).rounded())
            var h = UInt64(bitPattern: (ix &* 73_856_093) ^ (iy &* 19_349_663))
            h = (h ^ (h >> 31)) &* 0x9E37_79B9_7F4A_7C15
            h ^= h >> 29
            let line = stand.line.map(xy)
            let a = line[line.count - 2], b = line[line.count - 1]
            return StandSlot(ref: stand.ref, position: p, heading: atan2(b.x - a.x, b.y - a.y), line: line,
                             fitsWidebody: spacing >= 62, seed: Double(h % 10_000) / 10_000)
        }
    }
}
