import simd

/// A parsed AC3D (.ac) model, flattened into render-ready triangle groups.
///
/// AC3D is the format FlightGear aircraft ship in (c172p, A320 family, E-jets), so the M1 test
/// aircraft and the M6 fleet pipeline both read it. Coordinates are kept in the file's own
/// frame (meters); `AC3DModel.flightGearToModel` converts to our model frame.
public struct AC3DModel: Sendable {
    public struct Material: Sendable, Equatable {
        public var name: String
        public var diffuse: SIMD3<Float>
        public var emissive: SIMD3<Float>
        public var specular: SIMD3<Float>
        public var shininess: Float
        /// 0 = opaque, 1 = fully transparent (AC3D "trans").
        public var transparency: Float
    }

    /// Triangles sharing one texture and one material.
    public struct Group: Sendable {
        public var texture: String?
        public var materialIndex: Int
        public var twoSided: Bool
        public var positions: [SIMD3<Float>] = []
        public var normals: [SIMD3<Float>] = []
        public var uvs: [SIMD2<Float>] = []
        public var triangleCount: Int { positions.count / 3 }
    }

    public var materials: [Material] = []
    public var groups: [Group] = []

    public var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    public var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    public var triangleCount: Int { groups.reduce(0) { $0 + $1.triangleCount } }
}

public enum AC3DError: Error, Equatable {
    case notAC3D
    case unexpectedEnd(line: Int)
    case malformed(line: Int, String)
}

/// Parser for the AC3D text format (header "AC3Db"). Polygons are triangulated as fans,
/// line surfaces are skipped, and smooth-shaded surfaces get averaged normals within the
/// object's crease angle.
public enum AC3DParser {
    public static func parse(_ text: String) throws -> AC3DModel {
        var reader = LineReader(text)
        guard let header = reader.next(), header.hasPrefix("AC3D") else { throw AC3DError.notAC3D }
        var model = AC3DModel()
        var groupIndex: [GroupKey: Int] = [:]

        while let line = reader.peek() {
            if line.hasPrefix("MATERIAL") {
                _ = reader.next()
                model.materials.append(try parseMaterial(line, lineNumber: reader.lineNumber))
            } else if line.hasPrefix("OBJECT") {
                try parseObject(&reader, parent: matrix_identity_float4x4, model: &model, groupIndex: &groupIndex)
            } else {
                _ = reader.next()
            }
        }
        return model
    }

    // MARK: Materials

    static func parseMaterial(_ line: Substring, lineNumber: Int) throws -> AC3DModel.Material {
        // MATERIAL "name" rgb r g b amb r g b emis r g b spec r g b shi n trans t
        let name = line.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        let tokens = line.split(separator: " ")
        func vec(_ key: String) -> SIMD3<Float>? {
            guard let i = tokens.firstIndex(where: { $0 == key }), i + 3 < tokens.count,
                  let a = Float(tokens[i + 1]), let b = Float(tokens[i + 2]), let c = Float(tokens[i + 3])
            else { return nil }
            return SIMD3(a, b, c)
        }
        func scalar(_ key: String) -> Float? {
            guard let i = tokens.firstIndex(where: { $0 == key }), i + 1 < tokens.count else { return nil }
            return Float(tokens[i + 1])
        }
        guard let rgb = vec("rgb") else { throw AC3DError.malformed(line: lineNumber, "material without rgb") }
        return AC3DModel.Material(
            name: name,
            diffuse: rgb,
            emissive: vec("emis") ?? .zero,
            specular: vec("spec") ?? .zero,
            shininess: scalar("shi") ?? 0,
            transparency: scalar("trans") ?? 0
        )
    }

    // MARK: Objects

    struct GroupKey: Hashable {
        var texture: String?
        var material: Int
        var twoSided: Bool
    }

    private struct Surface {
        var flags: UInt32 = 0
        var material = 0
        var refs: [(index: Int, uv: SIMD2<Float>)] = []
        var isPolygon: Bool { flags & 0x0F == 0 }
        var smooth: Bool { flags & 0x10 != 0 }
        var twoSided: Bool { flags & 0x20 != 0 }
    }

    static func parseObject(
        _ reader: inout LineReader,
        parent: simd_float4x4,
        model: inout AC3DModel,
        groupIndex: inout [GroupKey: Int]
    ) throws {
        _ = reader.next() // OBJECT <type>
        var texture: String?
        var texrep = SIMD2<Float>(1, 1)
        var texoff = SIMD2<Float>(0, 0)
        var rotation = matrix_identity_float3x3
        var location = SIMD3<Float>.zero
        var crease: Float = 61
        var vertices: [SIMD3<Float>] = []
        var surfaces: [Surface] = []

        while let line = reader.next() {
            let tokens = line.split(separator: " ")
            guard let keyword = tokens.first else { continue }
            switch keyword {
            case "name", "url", "subdiv", "hidden", "locked", "folded":
                continue
            case "data":
                // A block of exactly N characters follows, possibly across lines.
                guard tokens.count > 1, let count = Int(tokens[1]) else { continue }
                reader.skipCharacters(count)
            case "texture":
                texture = line.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
            case "texrep":
                if tokens.count >= 3, let u = Float(tokens[1]), let v = Float(tokens[2]) { texrep = SIMD2(u, v) }
            case "texoff":
                if tokens.count >= 3, let u = Float(tokens[1]), let v = Float(tokens[2]) { texoff = SIMD2(u, v) }
            case "crease":
                if tokens.count >= 2, let c = Float(tokens[1]) { crease = c }
            case "rot":
                let m = tokens.dropFirst().compactMap { Float($0) }
                if m.count == 9 {
                    // AC3D stores the matrix row by row.
                    rotation = simd_float3x3(rows: [
                        SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8]),
                    ])
                }
            case "loc":
                let v = tokens.dropFirst().compactMap { Float($0) }
                if v.count == 3 { location = SIMD3(v[0], v[1], v[2]) }
            case "numvert":
                guard tokens.count > 1, let n = Int(tokens[1]) else {
                    throw AC3DError.malformed(line: reader.lineNumber, "numvert")
                }
                vertices.reserveCapacity(n)
                for _ in 0..<n {
                    guard let vLine = reader.next() else { throw AC3DError.unexpectedEnd(line: reader.lineNumber) }
                    let c = vLine.split(separator: " ").compactMap { Float($0) }
                    guard c.count >= 3 else { throw AC3DError.malformed(line: reader.lineNumber, "vertex") }
                    vertices.append(SIMD3(c[0], c[1], c[2]))
                }
            case "numsurf":
                guard tokens.count > 1, let n = Int(tokens[1]) else {
                    throw AC3DError.malformed(line: reader.lineNumber, "numsurf")
                }
                surfaces.reserveCapacity(n)
                for _ in 0..<n { surfaces.append(try parseSurface(&reader)) }
            case "kids":
                let local = transform(rotation: rotation, location: location)
                let world = parent * local
                emit(vertices: vertices, surfaces: surfaces, transform: world, texture: texture,
                     texrep: texrep, texoff: texoff, crease: crease, model: &model, groupIndex: &groupIndex)
                let kids = tokens.count > 1 ? Int(tokens[1]) ?? 0 : 0
                for _ in 0..<kids {
                    guard let next = reader.peek(), next.hasPrefix("OBJECT") else {
                        throw AC3DError.malformed(line: reader.lineNumber, "expected \(kids) child objects")
                    }
                    try parseObject(&reader, parent: world, model: &model, groupIndex: &groupIndex)
                }
                return
            default:
                continue
            }
        }
        throw AC3DError.unexpectedEnd(line: reader.lineNumber)
    }

    private static func parseSurface(_ reader: inout LineReader) throws -> Surface {
        var surface = Surface()
        guard let head = reader.next(), head.hasPrefix("SURF") else {
            throw AC3DError.malformed(line: reader.lineNumber, "expected SURF")
        }
        let flagText = head.split(separator: " ").dropFirst().first ?? "0"
        surface.flags = UInt32(flagText.hasPrefix("0x") ? flagText.dropFirst(2) : flagText, radix: flagText.hasPrefix("0x") ? 16 : 10) ?? 0
        while let line = reader.next() {
            let tokens = line.split(separator: " ")
            if tokens.first == "mat", tokens.count > 1 {
                surface.material = Int(tokens[1]) ?? 0
            } else if tokens.first == "refs", tokens.count > 1, let n = Int(tokens[1]) {
                surface.refs.reserveCapacity(n)
                for _ in 0..<n {
                    guard let r = reader.next() else { throw AC3DError.unexpectedEnd(line: reader.lineNumber) }
                    let p = r.split(separator: " ")
                    guard let i = p.first.flatMap({ Int($0) }) else {
                        throw AC3DError.malformed(line: reader.lineNumber, "ref")
                    }
                    let u = p.count > 1 ? Float(p[1]) ?? 0 : 0
                    let v = p.count > 2 ? Float(p[2]) ?? 0 : 0
                    surface.refs.append((i, SIMD2(u, v)))
                }
                return surface
            }
        }
        throw AC3DError.unexpectedEnd(line: reader.lineNumber)
    }

    private static func transform(rotation r: simd_float3x3, location l: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(l, 1)
        ))
    }

    // MARK: Triangles

    private static func emit(
        vertices: [SIMD3<Float>], surfaces: [Surface], transform: simd_float4x4,
        texture: String?, texrep: SIMD2<Float>, texoff: SIMD2<Float>, crease: Float,
        model: inout AC3DModel, groupIndex: inout [GroupKey: Int]
    ) {
        guard !vertices.isEmpty, !surfaces.isEmpty else { return }
        let world = vertices.map { v -> SIMD3<Float> in
            let p = transform * SIMD4(v, 1)
            return SIMD3(p.x, p.y, p.z)
        }

        // Face normals, computed after transforming (so no normal matrix is needed) and, for
        // smooth shading, the faces touching each vertex.
        var faceNormals = [SIMD3<Float>](repeating: .zero, count: surfaces.count)
        var facesAtVertex = [[Int]](repeating: [], count: world.count)
        for (f, s) in surfaces.enumerated() where s.isPolygon && s.refs.count >= 3 {
            faceNormals[f] = polygonNormal(s.refs.map { world[min($0.index, world.count - 1)] })
            if s.smooth {
                for r in s.refs where r.index < world.count { facesAtVertex[r.index].append(f) }
            }
        }
        let cosCrease = cos(crease * .pi / 180)

        for (f, s) in surfaces.enumerated() where s.isPolygon && s.refs.count >= 3 {
            let key = GroupKey(texture: texture, material: s.material, twoSided: s.twoSided)
            let g: Int
            if let existing = groupIndex[key] {
                g = existing
            } else {
                g = model.groups.count
                groupIndex[key] = g
                model.groups.append(AC3DModel.Group(texture: texture, materialIndex: s.material, twoSided: s.twoSided))
            }
            let n0 = faceNormals[f]
            func corner(_ r: (index: Int, uv: SIMD2<Float>)) -> (SIMD3<Float>, SIMD3<Float>, SIMD2<Float>) {
                let i = min(r.index, world.count - 1)
                var n = n0
                if s.smooth {
                    var sum = SIMD3<Float>.zero
                    for other in facesAtVertex[i] where simd_dot(faceNormals[other], n0) >= cosCrease {
                        sum += faceNormals[other]
                    }
                    if simd_length_squared(sum) > 0 { n = simd_normalize(sum) }
                }
                return (world[i], n, r.uv * texrep + texoff)
            }
            let first = corner(s.refs[0])
            for k in 1..<(s.refs.count - 1) {
                for c in [first, corner(s.refs[k]), corner(s.refs[k + 1])] {
                    model.groups[g].positions.append(c.0)
                    model.groups[g].normals.append(c.1)
                    model.groups[g].uvs.append(c.2)
                    model.boundsMin = simd_min(model.boundsMin, c.0)
                    model.boundsMax = simd_max(model.boundsMax, c.0)
                }
            }
        }
    }

    /// Newell's method: robust for slightly non-planar polygons.
    static func polygonNormal(_ p: [SIMD3<Float>]) -> SIMD3<Float> {
        var n = SIMD3<Float>.zero
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        }
        let len = simd_length(n)
        return len > 0 ? n / len : SIMD3(0, 1, 0)
    }
}

/// Line cursor over the file text that never copies the whole file into an array of strings.
struct LineReader {
    private let text: Substring
    private var position: Substring.Index
    private(set) var lineNumber = 0

    init(_ text: String) {
        self.text = Substring(text)
        self.position = self.text.startIndex
    }

    mutating func next() -> Substring? {
        guard position < text.endIndex else { return nil }
        let end = text[position...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) ?? text.endIndex
        let line = text[position..<end]
        position = end < text.endIndex ? text.index(after: end) : end
        lineNumber += 1
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        return trimmed.isEmpty ? next() : trimmed
    }

    func peek() -> Substring? {
        var copy = self
        return copy.next()
    }

    /// Skips exactly `count` characters (an AC3D data block), then the rest of that line.
    mutating func skipCharacters(_ count: Int) {
        position = text.index(position, offsetBy: count, limitedBy: text.endIndex) ?? text.endIndex
        if position < text.endIndex, let nl = text[position...].firstIndex(where: { $0.isNewline }) {
            position = text.index(after: nl)
        }
    }
}
