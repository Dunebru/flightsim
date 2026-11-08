public import simd

/// Ground equipment around parked airliners: what serves an A320 at the gate, placed in the
/// aircraft's own frame (x forward, y left, from the nose wheel) so it sits where it would.
/// uv.y carries the paint: 0 white body, 1 safety yellow, 2 black (tyres, cab glass), 3 blue
/// tarpaulin, 4 orange, 5 grey steel; uv.x the metres along for detail.
public enum StandEquipment {
    public static let white = 0.0, yellow = 1.0, black = 2.0, tarp = 3.0, orange = 4.0, steel = 5.0

    /// Equipment at every occupied airliner stand except `excluding` (the one the flight
    /// starts at), in the airport frame.
    public static func build(_ site: AirportSite, excluding: String?) -> MeshData {
        var m = MeshData()
        for slot in site.airlinerStands where slot.occupied && slot.ref != excluding {
            let p = slot.position
            let f = SIMD2(sin(slot.heading), cos(slot.heading)), l = SIMD2(-f.y, f.x)
            let z0 = site.z(p)
            // Body-frame point (forward, left, up) to the airport frame.
            func w(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
                let q = p + f * x + l * y
                return SIMD3(q.x, q.y, z0 + z)
            }
            let r = slot.seed
            // A box: centre (x, y), along the aircraft (length), across (width), up (height),
            // standing on `base`, turned `yaw` radians from the aircraft's heading.
            func box(_ x: Double, _ y: Double, length: Double, width: Double, height: Double, base: Double = 0,
                     yaw: Double = 0, paint: Double) {
                let c = SIMD2(x, y)
                let a = SIMD2(cos(yaw), sin(yaw)), b = SIMD2(-sin(yaw), cos(yaw))
                let corners = [c + a * length / 2 + b * width / 2, c - a * length / 2 + b * width / 2,
                               c - a * length / 2 - b * width / 2, c + a * length / 2 - b * width / 2]
                func world(_ q: SIMD2<Double>, _ z: Double) -> SIMD3<Double> { w(q.x, q.y, z) }
                func dir(_ q: SIMD2<Double>) -> SIMD3<Double> { let d = f * q.x + l * q.y; return SIMD3(d.x, d.y, 0) }
                for i in 0..<4 {
                    let c0 = corners[i], c1 = corners[(i + 1) % 4]
                    let mid = (c0 + c1) / 2 - c
                    let n = simd_normalize(dir(mid))
                    let span = simd_distance(c0, c1)
                    m.add(world(c0, base), n, SIMD2(0, paint)); m.add(world(c1, base), n, SIMD2(span, paint))
                    m.add(world(c1, base + height), n, SIMD2(span, paint))
                    m.add(world(c0, base), n, SIMD2(0, paint)); m.add(world(c1, base + height), n, SIMD2(span, paint))
                    m.add(world(c0, base + height), n, SIMD2(0, paint))
                }
                let up = SIMD3<Double>(0, 0, 1)
                m.add(world(corners[0], base + height), up, SIMD2(0, paint)); m.add(world(corners[1], base + height), up, SIMD2(0, paint))
                m.add(world(corners[2], base + height), up, SIMD2(0, paint))
                m.add(world(corners[0], base + height), up, SIMD2(0, paint)); m.add(world(corners[2], base + height), up, SIMD2(0, paint))
                m.add(world(corners[3], base + height), up, SIMD2(0, paint))
            }
            func wheels(_ x: Double, _ y: Double, length: Double, width: Double) {
                for (dx, dy) in [(1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0)] {
                    box(x + dx * length * 0.35, y + dy * width / 2, length: 0.6, width: 0.25, height: 0.6, paint: black)
                }
            }
            // Ground power unit by the nose, its cable on the ground.
            box(4.0, -4.2, length: 2.0, width: 1.2, height: 1.3, base: 0.3, paint: yellow)
            wheels(4.0, -4.2, length: 2.0, width: 1.2)
            // Belt loader at the forward hold (right side, 4 m behind the nose wheel): chassis on
            // the apron, the belt rising to the sill.
            box(-4.2, -6.0, length: 1.6, width: 4.6, height: 0.8, base: 0.35, yaw: .pi / 2, paint: white)
            wheels(-4.2, -6.0, length: 1.6, width: 4.6)
            box(-4.2, -6.4, length: 1.0, width: 1.2, height: 1.2, base: 1.1, yaw: 0, paint: black)       // driver's seat and cage
            let rampSteps = 6
            for k in 0..<rampSteps {
                let t = Double(k) / Double(rampSteps)
                box(-4.2, -8.8 + t * 6.6, length: 0.9, width: 6.6 / Double(rampSteps), height: 0.18, base: 0.9 + t * 1.2, paint: steel)
            }
            // Tug and three baggage carts, waiting by the wing.
            let train = -9.0 - r * 3
            box(train, -9.5, length: 2.8, width: 1.6, height: 1.0, base: 0.35, paint: white)
            box(train - 0.5, -9.5, length: 1.2, width: 1.5, height: 0.9, base: 1.35, paint: black)
            wheels(train, -9.5, length: 2.8, width: 1.6)
            for k in 0..<3 {
                let x = train - 3.4 - Double(k) * 3.1
                box(x, -9.5, length: 2.5, width: 1.5, height: 0.5, base: 0.35, paint: steel)
                box(x, -9.5, length: 2.4, width: 1.45, height: 1.1, base: 0.85, paint: k == 1 ? white : tarp)
                wheels(x, -9.5, length: 2.5, width: 1.5)
            }
            // Catering truck at the rear right door at about half the stands, its box raised.
            if r < 0.5 {
                box(-27.0, -6.5, length: 7.0, width: 2.4, height: 1.2, base: 0.4, yaw: .pi / 2, paint: white)
                box(-27.0, -4.0, length: 2.4, width: 4.8, height: 2.8, base: 2.0, paint: white)
                box(-27.0, -9.5, length: 2.3, width: 2.2, height: 1.6, base: 0.6, paint: black)
                wheels(-27.0, -6.5, length: 2.4, width: 7.0)
            }
            // Hydrant fuel cart under the right wing at about a third.
            if r > 0.6 {
                box(-11.0, -8.0, length: 5.0, width: 2.2, height: 1.4, base: 0.4, paint: yellow)
                box(-9.0, -8.0, length: 1.4, width: 2.1, height: 1.2, base: 1.8, paint: black)
                wheels(-11.0, -8.0, length: 5.0, width: 2.2)
            }
            // Cones at the nose and the wingtips.
            for (x, y) in [(6.5, 0.0), (-14.0, 17.8), (-14.0, -17.8)] {
                box(x, y, length: 0.32, width: 0.32, height: 0.7, paint: orange)
            }
        }
        return m
    }
}
