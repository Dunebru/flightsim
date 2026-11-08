import simd

/// Matrix helpers. World and view space are right-handed; cameras look down -Z; clip depth is
/// Metal's 0...1. The main camera uses reverse-Z (near = 1, infinity = 0).
enum MatrixMath {
    /// Reverse-Z infinite perspective. `jitter` is an NDC offset (already scaled by 2/size).
    static func perspectiveReverseZ(fovY: Float, aspect: Float, near: Float, jitter: SIMD2<Float> = .zero) -> simd_float4x4 {
        let f = 1 / tan(fovY / 2)
        // clip.z = near, clip.w = -z_view  =>  depth = near / -z_view.
        // Column 2 carries the jitter: clip.xy += -jitter * z_view = jitter * w.
        return simd_float4x4(columns: (
            SIMD4(f / aspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(-jitter.x, -jitter.y, 0, -1),
            SIMD4(0, 0, near, 0)
        ))
    }

    /// View matrix for a camera at the origin looking along `forward` with world `up`.
    static func lookDirection(_ forward: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 0, 1)) -> simd_float4x4 {
        let f = simd_normalize(forward)
        var r = simd_cross(f, up)
        if simd_length_squared(r) < 1e-8 { r = SIMD3(1, 0, 0) }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        return simd_float4x4(rows: [
            SIMD4(r, 0),
            SIMD4(u, 0),
            SIMD4(-f, 0),
            SIMD4(0, 0, 0, 1),
        ])
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 0, 1)) -> simd_float4x4 {
        lookDirection(target - eye, up: up) * translation(-eye)
    }

    /// Orthographic projection to Metal clip space with depth 0 (near) ... 1 (far).
    /// The four side planes (left, right, bottom, top) of a view-projection's frustum, as
    /// (normal, distance) with the normal pointing inward. Near and far are left out: the
    /// projection is reverse-Z with an infinite far plane.
    static func frustumPlanes(_ m: simd_float4x4) -> [SIMD4<Float>] {
        func row(_ i: Int) -> SIMD4<Float> { SIMD4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i]) }
        let r0 = row(0), r1 = row(1), r3 = row(3)
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1].map { p in p / simd_length(SIMD3(p.x, p.y, p.z)) }
    }

    /// Whether a sphere (camera-relative centre) touches the frustum.
    static func sphereVisible(centre: SIMD3<Float>, radius: Float, planes: [SIMD4<Float>]) -> Bool {
        for p in planes where simd_dot(SIMD3(p.x, p.y, p.z), centre) + p.w < -radius { return false }
        return true
    }

    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(1 / halfWidth, 0, 0, 0),
            SIMD4(0, 1 / halfHeight, 0, 0),
            SIMD4(0, 0, -1 / (far - near), 0),
            SIMD4(0, 0, -near / (far - near), 1)
        ))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// Rotation about +Z (counter-clockwise seen from above).
    static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)
        ))
    }

    /// Rotation about +X.
    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)
        ))
    }

    /// Rotation about +Y.
    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)
        ))
    }

    /// Halton low-discrepancy sequence, used for sub-pixel jitter.
    static func halton(_ index: Int, base: Int) -> Float {
        var f: Float = 1, r: Float = 0, i = index
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r
    }
}
