// Shared definitions. ShaderLibrary concatenates the .metal files in this folder in name
// order and compiles them as one source, so this file comes first.
#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

// MARK: - Frame uniforms (must match FrameUniforms in RendererTypes.swift field for field)

struct FrameUniforms {
    float4x4 viewProj;              // camera-relative world -> clip, jittered
    float4x4 viewProjNoJitter;
    float4x4 prevViewProjNoJitter;  // previous frame, relative to the previous camera
    float4x4 invViewProjNoJitter;   // clip -> camera-relative direction (for sky rays)
    float4x4 shadowViewProj;        // camera-relative world -> shadow clip
    float4x4 worldShadowViewProj;   // camera-relative world -> world (buildings) shadow clip
    float4 cameraDelta;             // xyz: camera position change since last frame (m, world)
    float4 sunDirection;            // xyz: unit vector to the sun (world ENU, z up)
    float4 sunIlluminance;          // rgb: sun illuminance outside the atmosphere (relative units)
    float4 atmosphere;              // x: camera altitude above ground (km), y: ground elevation (km),
                                    // z: aerial perspective range (km), w: time (s)
    float4 noiseOrigin;             // xy: camera world position modulo 1024 m (stable procedural noise)
    float4 renderSize;              // xy: render target size (px), zw: 1/size
    float4 jitter;                  // xy: sub-pixel jitter applied this frame (px)
    float4 shadowParams;            // x: enabled, y: depth bias, z: 1/shadow map size
    float4 worldShadowParams;       // x: enabled, y: depth bias, z: 1/map size, w: texel size (m)
    float4 debug;                   // x: show ground (1/0)
    float4 cloudShadow;             // x: enabled, y: 1/map extent (1/m), zw: map centre from the camera (m)
    float4 cloudShadowShift;        // x: map reference height, y: lowest cloud base (m above sea level),
                                    // zw: horizontal shift toward the sun per metre of height
    float4 cloudLight;              // x: sky fraction covered by cloud, y: mean sun transmittance,
                                    // z: camera height above sea level, w: highest cloud top (m)
    float4 fog;                     // x: extinction at the field (1/m), y: scale height (m),
                                    // z: field height, w: camera height (m above sea level)
    float4 weather;                 // x: how wet the ground is (0-1)
    float4 moonDirection;           // xyz: unit vector to the Moon (world), w: its angular radius (rad)
    float4 moonLight;               // x: moonlight on level ground (scene units, perceptually scaled)
};

/// Optical depth of low-level fog, mist or haze from the camera along a unit direction to a
/// distance (m). Its density falls off exponentially with height above the field, so the
/// integral has a closed form.
inline float fogDepth(float3 dir, float dist, constant FrameUniforms &u) {
    if (u.fog.x <= 0.0) return 0.0;
    float H = u.fog.y;
    float atCamera = u.fog.x * exp(-clamp(u.fog.w - u.fog.z, -200.0, 20.0 * H) / H);
    float k = clamp(dir.z * dist / H, -60.0, 60.0);
    if (abs(k) < 1e-3) return atCamera * dist;
    return atCamera * H * (1.0 - exp(-k)) / dir.z;
}

// MARK: - Atmosphere model (Earth, after Hillaire 2020 "A Scalable and Production Ready Sky
// and Atmosphere Rendering Technique"). Units: kilometres.

constant float kBottomRadius = 6360.0;
constant float kTopRadius = 6460.0;
constant float3 kRayleighScattering = float3(5.802, 13.558, 33.1) * 1e-3;
constant float kRayleighScaleHeight = 8.0;
constant float kMieScattering = 3.996e-3;
constant float kMieExtinction = 4.440e-3;
constant float kMieScaleHeight = 1.2;
constant float kMieG = 0.8;
constant float3 kOzoneAbsorption = float3(0.650, 1.881, 0.085) * 1e-3;
constant float3 kGroundAlbedo = float3(0.3);
constant float kPi = 3.14159265358979;

constant int2 kTransmittanceSize = int2(256, 64);
constant int2 kMultiScatterSize = int2(32, 32);
constant int2 kSkyViewSize = int2(192, 108);
constant int3 kAerialSize = int3(32, 32, 32);

struct MediumSample {
    float3 scattering;
    float3 extinction;
    float3 scatteringRayleigh;
    float scatteringMie;
};

inline MediumSample sampleMedium(float height) {
    float densityRay = exp(-height / kRayleighScaleHeight);
    float densityMie = exp(-height / kMieScaleHeight);
    float densityOzone = max(0.0, 1.0 - abs(height - 25.0) / 15.0);
    MediumSample m;
    m.scatteringRayleigh = kRayleighScattering * densityRay;
    m.scatteringMie = kMieScattering * densityMie;
    m.scattering = m.scatteringRayleigh + m.scatteringMie;
    m.extinction = m.scatteringRayleigh + kMieExtinction * densityMie + kOzoneAbsorption * densityOzone;
    return m;
}

inline float rayleighPhase(float cosTheta) {
    return 3.0 / (16.0 * kPi) * (1.0 + cosTheta * cosTheta);
}

inline float miePhase(float cosTheta) {
    // Cornette-Shanks, a better fit to real aerosols than plain Henyey-Greenstein.
    float g = kMieG, g2 = g * g;
    float k = 3.0 / (8.0 * kPi) * (1.0 - g2) / (2.0 + g2);
    return k * (1.0 + cosTheta * cosTheta) / pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5);
}

/// Distance along a ray to a sphere centred at the origin, or -1 when it misses.
/// Returns the nearest positive hit.
inline float raySphere(float3 origin, float3 dir, float radius) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0) return -1.0;
    float s = sqrt(disc);
    float t0 = -b - s, t1 = -b + s;
    if (t0 >= 0.0) return t0;
    if (t1 >= 0.0) return t1;
    return -1.0;
}

// Transmittance LUT parameterisation (Bruneton 2017).
inline float2 transmittanceUV(float r, float mu) {
    float H = sqrt(kTopRadius * kTopRadius - kBottomRadius * kBottomRadius);
    float rho = sqrt(max(0.0, r * r - kBottomRadius * kBottomRadius));
    float disc = r * r * (mu * mu - 1.0) + kTopRadius * kTopRadius;
    float d = max(0.0, -r * mu + sqrt(max(disc, 0.0)));
    float dMin = kTopRadius - r, dMax = rho + H;
    return float2((d - dMin) / (dMax - dMin), rho / H);
}

inline void transmittanceParams(float2 uv, thread float &r, thread float &mu) {
    float H = sqrt(kTopRadius * kTopRadius - kBottomRadius * kBottomRadius);
    float rho = H * uv.y;
    r = sqrt(rho * rho + kBottomRadius * kBottomRadius);
    float dMin = kTopRadius - r, dMax = rho + H;
    float d = dMin + uv.x * (dMax - dMin);
    mu = d == 0.0 ? 1.0 : (H * H - rho * rho - d * d) / (2.0 * r * d);
    mu = clamp(mu, -1.0, 1.0);
}

constexpr sampler kLinearClamp(filter::linear, address::clamp_to_edge);
constexpr sampler kLinearRepeat(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));

inline float3 sampleTransmittance(texture2d<float> lut, float r, float mu) {
    return lut.sample(kLinearClamp, transmittanceUV(r, mu)).rgb;
}

// MARK: - Noise (value noise on a hash; cheap and stable)

inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i), b = hash12(i + float2(1, 0));
    float c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float fbm(float2 p, int octaves) {
    float sum = 0.0, amp = 0.5;
    for (int i = 0; i < octaves; i++) {
        sum += amp * valueNoise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        amp *= 0.5;
    }
    return sum;
}
