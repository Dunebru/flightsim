import Foundation
import Testing
import simd
@testable import Aircraft

struct AC3DTests {
    /// Two materials; a parent offset by loc; a textured child quad with texrep; a smooth
    /// triangle pair; and a line surface that must be ignored.
    static let sample = """
    AC3Db
    MATERIAL "paint" rgb 1 0 0  amb 1 1 1  emis 0 0 0  spec 0.5 0.5 0.5  shi 32  trans 0
    MATERIAL "glass" rgb 0.2 0.2 0.2  amb 1 1 1  emis 0 0 0  spec 1 1 1  shi 128  trans 0.6
    OBJECT world
    kids 1
    OBJECT group
    name "fuselage"
    loc 10 0 0
    kids 2
    OBJECT poly
    name "panel"
    data 11
    hello
    world
    texture "skin.png"
    texrep 2 2
    numvert 4
    0 0 0
    1 0 0
    1 1 0
    0 1 0
    numsurf 2
    SURF 0x20
    mat 0
    refs 4
    0 0 0
    1 0.5 0
    2 0.5 0.5
    3 0 0.5
    SURF 0x2
    mat 0
    refs 2
    0 0 0
    1 1 0
    kids 0
    OBJECT poly
    name "window"
    loc 0 0 5
    crease 45
    numvert 4
    0 0 0
    1 0 0
    0 1 0
    1 1 0.2
    numsurf 2
    SURF 0x10
    mat 1
    refs 3
    0 0 0
    1 0 0
    2 0 0
    SURF 0x10
    mat 1
    refs 3
    1 0 0
    3 0 0
    2 0 0
    kids 0
    """

    @Test func parsesMaterials() throws {
        let m = try AC3DParser.parse(Self.sample)
        #expect(m.materials.count == 2)
        #expect(m.materials[0].name == "paint")
        #expect(m.materials[0].diffuse == SIMD3(1, 0, 0))
        #expect(m.materials[1].shininess == 128)
        #expect(m.materials[1].transparency == 0.6)
    }

    @Test func triangulatesAndGroups() throws {
        let m = try AC3DParser.parse(Self.sample)
        // Quad -> 2 triangles; the line surface is skipped; two window triangles.
        #expect(m.triangleCount == 4)
        #expect(m.groups.count == 2)
        let skin = try #require(m.groups.first { $0.texture == "skin.png" })
        #expect(skin.triangleCount == 2)
        #expect(skin.twoSided)
        let window = try #require(m.groups.first { $0.texture == nil })
        #expect(window.materialIndex == 1)
    }

    @Test func appliesNestedLocationsAndTexrep() throws {
        let m = try AC3DParser.parse(Self.sample)
        let skin = try #require(m.groups.first { $0.texture == "skin.png" })
        // Parent loc (10,0,0) moves the quad; texrep 2 doubles its UVs.
        #expect(skin.positions.contains(SIMD3(11, 1, 0)))
        #expect(skin.uvs.contains(SIMD2(1, 1)))
        let window = try #require(m.groups.first { $0.texture == nil })
        // Parent loc + own loc (0,0,5).
        #expect(window.positions.contains(SIMD3(10, 0, 5)))
        #expect(m.boundsMin == SIMD3(10, 0, 0))
        #expect(m.boundsMax == SIMD3(11, 1, 5.2))
    }

    @Test func smoothNormalsAverageWithinCrease() throws {
        let m = try AC3DParser.parse(Self.sample)
        let window = try #require(m.groups.first { $0.texture == nil })
        // Shared vertex (1,0,0)+loc appears in both triangles; smooth shading averages their
        // normals (about 11 degrees apart, under the 45 degree crease), so both copies match.
        let shared = SIMD3<Float>(11, 0, 5)
        let normals = zip(window.positions, window.normals).filter { $0.0 == shared }.map(\.1)
        #expect(normals.count == 2)
        #expect(simd_distance(normals[0], normals[1]) < 1e-5)
        for n in window.normals { #expect(abs(simd_length(n) - 1) < 1e-5) }
    }

    @Test func rejectsNonAC3D() {
        #expect(throws: AC3DError.notAC3D) { try AC3DParser.parse("solid cube\n") }
    }

    /// The real FlightGear C172P model, when scripts/fetch-assets.sh has run. A Cessna 172 is
    /// about 8.3 m long, 11.0 m in span and 2.7 m tall.
    static let c172URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../../Data/Bundle/Aircraft/c172p/c172-common.ac")
        .standardized

    @Test(.enabled(if: FileManager.default.fileExists(atPath: c172URL.path)))
    func parsesRealC172() throws {
        let text = try String(contentsOf: Self.c172URL, encoding: .isoLatin1)
        let clock = ContinuousClock()
        var model: AC3DModel?
        let elapsed = try clock.measure { model = try AC3DParser.parse(text) }
        let m = try #require(model)
        let size = m.boundsMax - m.boundsMin
        let sorted = [size.x, size.y, size.z].sorted()
        print("c172: \(m.triangleCount) triangles, \(m.groups.count) groups, extent \(size), parsed in \(elapsed)")
        #expect(m.triangleCount > 10_000)
        #expect(abs(sorted[2] - 11.0) < 0.6)   // span
        #expect(abs(sorted[1] - 8.3) < 0.8)    // length
        #expect(abs(sorted[0] - 2.7) < 0.6)    // height
    }
}
