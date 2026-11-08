// Physically based atmosphere: transmittance, multiple scattering, sky-view and aerial
// perspective lookup tables, after Hillaire 2020. Radiance is in relative units; exposure
// is computed on the GPU from the same tables.

inline float fromUnitToSubUV(float u, float res) { return (u + 0.5 / res) * (res / (res + 1.0)); }
inline float fromSubUVToUnit(float u, float res) { return (u - 0.5 / res) * (res / (res - 1.0)); }

inline float2 multiScatterUV(float muS, float height) {
    return float2(muS * 0.5 + 0.5, clamp(height / (kTopRadius - kBottomRadius), 0.0, 1.0));
}

struct ScatterResult {
    float3 luminance;
    float3 transmittance;
};

/// Raymarches single scattering plus the multiple-scattering term along a ray that starts
/// inside the atmosphere. `sunIlluminance` scales the result.
inline ScatterResult integrateScattering(
    float3 origin, float3 dir, float3 sunDir, float3 sunIlluminance,
    texture2d<float> transmittanceLUT, texture2d<float> multiScatterLUT, bool useMultiScatter,
    int steps, float tLimit, bool includeGround)
{
    ScatterResult result;
    result.luminance = 0.0;
    result.transmittance = 1.0;
    float tBottom = raySphere(origin, dir, kBottomRadius);
    float tTop = raySphere(origin, dir, kTopRadius);
    float tMax;
    if (tBottom < 0.0) {
        if (tTop < 0.0) return result;
        tMax = tTop;
    } else {
        tMax = tTop > 0.0 ? min(tTop, tBottom) : tBottom;
    }
    bool groundHit = tBottom >= 0.0 && tBottom <= tLimit;
    tMax = min(tMax, tLimit);

    float cosTheta = dot(sunDir, dir);
    float phaseR = rayleighPhase(cosTheta);
    float phaseM = miePhase(cosTheta);
    float dt = tMax / float(steps);
    float3 L = 0.0, T = 1.0;
    for (int i = 0; i < steps; i++) {
        float t = (float(i) + 0.3) * dt;
        float3 p = origin + dir * t;
        float r = length(p);
        float h = r - kBottomRadius;
        MediumSample m = sampleMedium(h);
        float3 up = p / r;
        float muS = dot(sunDir, up);
        float3 sunT = sampleTransmittance(transmittanceLUT, r, muS);
        float earthShadow = raySphere(p, sunDir, kBottomRadius) >= 0.0 ? 0.0 : 1.0;
        float3 phaseScattering = m.scatteringRayleigh * phaseR + m.scatteringMie * phaseM;
        float3 ms = useMultiScatter ? multiScatterLUT.sample(kLinearClamp, multiScatterUV(muS, h)).rgb : float3(0.0);
        float3 S = sunIlluminance * (earthShadow * sunT * phaseScattering + ms * m.scattering);
        float3 sampleT = exp(-m.extinction * dt);
        float3 Sint = (S - S * sampleT) / max(m.extinction, float3(1e-9));
        L += T * Sint;
        T *= sampleT;
    }
    if (includeGround && groundHit) {
        float3 p = origin + dir * tBottom;
        float r = length(p);
        float muS = dot(sunDir, p / r);
        float3 sunT = sampleTransmittance(transmittanceLUT, r, muS);
        L += T * sunIlluminance * sunT * saturate(muS) * kGroundAlbedo / kPi;
    }
    result.luminance = L;
    result.transmittance = T;
    return result;
}

// MARK: - Transmittance (once)

kernel void transmittanceLUT(texture2d<float, access::write> out [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(kTransmittanceSize.x) || gid.y >= uint(kTransmittanceSize.y)) return;
    float2 uv = (float2(gid) + 0.5) / float2(kTransmittanceSize);
    float r, mu;
    transmittanceParams(uv, r, mu);
    float3 origin = float3(0.0, 0.0, r);
    float3 dir = float3(sqrt(max(0.0, 1.0 - mu * mu)), 0.0, mu);
    float tMax = raySphere(origin, dir, kTopRadius);
    const int steps = 40;
    float dt = max(tMax, 0.0) / float(steps);
    float3 opticalDepth = 0.0;
    for (int i = 0; i < steps; i++) {
        float3 p = origin + dir * ((float(i) + 0.5) * dt);
        opticalDepth += sampleMedium(length(p) - kBottomRadius).extinction * dt;
    }
    out.write(float4(exp(-opticalDepth), 1.0), gid);
}

// MARK: - Multiple scattering (once)

kernel void multiScatterLUT(texture2d<float, access::write> out [[texture(0)]],
                            texture2d<float> transmittanceLUT [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(kMultiScatterSize.x) || gid.y >= uint(kMultiScatterSize.y)) return;
    float2 uv = (float2(gid) + 0.5) / float2(kMultiScatterSize);
    float muS = uv.x * 2.0 - 1.0;
    float h = max(uv.y * (kTopRadius - kBottomRadius), 0.01);
    float3 origin = float3(0.0, 0.0, kBottomRadius + h);
    float3 sunDir = float3(sqrt(max(0.0, 1.0 - muS * muS)), 0.0, muS);
    const float isotropic = 1.0 / (4.0 * kPi);

    const int directions = 64;
    const int steps = 20;
    float3 sumL = 0.0, sumF = 0.0;
    for (int d = 0; d < directions; d++) {
        // Fibonacci sphere: near-uniform directions.
        float z = 1.0 - 2.0 * (float(d) + 0.5) / float(directions);
        float phi = float(d) * 2.39996323;
        float rxy = sqrt(max(0.0, 1.0 - z * z));
        float3 dir = float3(rxy * cos(phi), rxy * sin(phi), z);

        float tBottom = raySphere(origin, dir, kBottomRadius);
        float tTop = raySphere(origin, dir, kTopRadius);
        float tMax = tBottom >= 0.0 ? tBottom : tTop;
        float dt = max(tMax, 0.0) / float(steps);
        float3 L = 0.0, F = 0.0, T = 1.0;
        for (int i = 0; i < steps; i++) {
            float3 p = origin + dir * ((float(i) + 0.3) * dt);
            float r = length(p);
            MediumSample m = sampleMedium(r - kBottomRadius);
            float mu = dot(sunDir, p / r);
            float3 sunT = sampleTransmittance(transmittanceLUT, r, mu);
            float earthShadow = raySphere(p, sunDir, kBottomRadius) >= 0.0 ? 0.0 : 1.0;
            float3 S = earthShadow * sunT * m.scattering * isotropic;
            float3 sampleT = exp(-m.extinction * dt);
            float3 inv = 1.0 / max(m.extinction, float3(1e-9));
            L += T * (S - S * sampleT) * inv;
            F += T * (m.scattering - m.scattering * sampleT) * inv;
            T *= sampleT;
        }
        if (tBottom >= 0.0) {
            float3 p = origin + dir * tBottom;
            float r = length(p);
            float mu = dot(sunDir, p / r);
            L += T * sampleTransmittance(transmittanceLUT, r, mu) * saturate(mu) * kGroundAlbedo / kPi;
        }
        sumL += L;
        sumF += F;
    }
    // Averaging over uniformly distributed directions integrates over the sphere with the
    // isotropic phase function (4*pi * avg * 1/(4*pi) = avg).
    float3 L2 = sumL / float(directions);
    float3 fms = sumF / float(directions);
    float3 psi = L2 / max(1.0 - fms, float3(1e-3));
    out.write(float4(psi, 1.0), gid);
}

// MARK: - Sky-view LUT (per frame)

inline void skyViewParams(float2 uv, float viewHeight, thread float &viewZenithCos, thread float &lightViewCos) {
    uv = float2(fromSubUVToUnit(uv.x, float(kSkyViewSize.x)), fromSubUVToUnit(uv.y, float(kSkyViewSize.y)));
    float vHorizon = sqrt(max(0.0, viewHeight * viewHeight - kBottomRadius * kBottomRadius));
    float beta = acos(clamp(vHorizon / viewHeight, -1.0, 1.0));
    float zenithHorizon = kPi - beta;
    if (uv.y < 0.5) {
        float c = 1.0 - 2.0 * uv.y;
        c = 1.0 - c * c;
        viewZenithCos = cos(zenithHorizon * c);
    } else {
        float c = uv.y * 2.0 - 1.0;
        viewZenithCos = cos(zenithHorizon + beta * c * c);
    }
    float c = uv.x * uv.x;
    lightViewCos = -(c * 2.0 - 1.0);
}

/// UV into the sky-view LUT for a world direction (ENU, z up) seen from `viewHeight`.
inline float2 skyViewUV(float3 dir, float3 sunDir, float viewHeight) {
    float viewZenithCos = clamp(dir.z, -1.0, 1.0);
    float2 h = dir.xy, s = sunDir.xy;
    float lightViewCos = (length(h) > 1e-5 && length(s) > 1e-5) ? dot(normalize(h), normalize(s)) : 1.0;
    float vHorizon = sqrt(max(0.0, viewHeight * viewHeight - kBottomRadius * kBottomRadius));
    float beta = acos(clamp(vHorizon / viewHeight, -1.0, 1.0));
    float zenithHorizon = kPi - beta;
    bool groundHit = raySphere(float3(0, 0, viewHeight), dir, kBottomRadius) >= 0.0;
    float2 uv;
    float angle = acos(viewZenithCos);
    if (!groundHit) {
        float c = clamp(angle / zenithHorizon, 0.0, 1.0);
        uv.y = (1.0 - sqrt(1.0 - c)) * 0.5;
    } else {
        float c = clamp((angle - zenithHorizon) / beta, 0.0, 1.0);
        uv.y = sqrt(c) * 0.5 + 0.5;
    }
    uv.x = sqrt(clamp(-lightViewCos * 0.5 + 0.5, 0.0, 1.0));
    return float2(fromUnitToSubUV(uv.x, float(kSkyViewSize.x)), fromUnitToSubUV(uv.y, float(kSkyViewSize.y)));
}

inline float cameraRadius(constant FrameUniforms &u) {
    return kBottomRadius + max(u.atmosphere.x + u.atmosphere.y, 0.001);
}

kernel void skyViewLUT(texture2d<float, access::write> out [[texture(0)]],
                       texture2d<float> transmittanceLUT [[texture(1)]],
                       texture2d<float> multiScatterLUT [[texture(2)]],
                       constant FrameUniforms &u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(kSkyViewSize.x) || gid.y >= uint(kSkyViewSize.y)) return;
    float viewHeight = cameraRadius(u);
    float2 uv = (float2(gid) + 0.5) / float2(kSkyViewSize);
    float viewZenithCos, lightViewCos;
    skyViewParams(uv, viewHeight, viewZenithCos, lightViewCos);

    // Build the view and sun directions in a frame whose x axis is the sun's azimuth.
    float muS = clamp(u.sunDirection.z, -1.0, 1.0);
    float3 sunDir = float3(sqrt(max(0.0, 1.0 - muS * muS)), 0.0, muS);
    float sinV = sqrt(max(0.0, 1.0 - viewZenithCos * viewZenithCos));
    float3 dir = float3(sinV * lightViewCos, sinV * sqrt(max(0.0, 1.0 - lightViewCos * lightViewCos)), viewZenithCos);

    ScatterResult s = integrateScattering(float3(0, 0, viewHeight), dir, sunDir, u.sunIlluminance.rgb,
                                          transmittanceLUT, multiScatterLUT, true, 30, 9.0e6, true);
    out.write(float4(s.luminance, 1.0), gid);
}

// MARK: - Aerial perspective volume (per frame)

inline float aerialSliceDistance(float slice, float rangeKm) {
    float w = slice / float(kAerialSize.z);
    return rangeKm * w * w;
}

kernel void aerialPerspective(texture3d<float, access::write> out [[texture(0)]],
                              texture2d<float> transmittanceLUT [[texture(1)]],
                              texture2d<float> multiScatterLUT [[texture(2)]],
                              constant FrameUniforms &u [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(kAerialSize.x) || gid.y >= uint(kAerialSize.y)) return;
    float2 uv = (float2(gid) + 0.5) / float2(kAerialSize.xy);
    float4 clip = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.5, 1.0);
    float4 world = u.invViewProjNoJitter * clip;
    float3 dir = normalize(world.xyz / world.w);

    float3 origin = float3(0.0, 0.0, cameraRadius(u));
    float3 sunDir = u.sunDirection.xyz;
    float cosTheta = dot(sunDir, dir);
    float phaseR = rayleighPhase(cosTheta), phaseM = miePhase(cosTheta);
    float range = u.atmosphere.z;

    float3 L = 0.0, T = 1.0;
    float tPrev = 0.0;
    for (int s = 0; s < kAerialSize.z; s++) {
        float tSlice = aerialSliceDistance(float(s) + 0.5, range);
        // Two sub-steps per slice keep the nearest slices accurate.
        for (int k = 0; k < 2; k++) {
            float t0 = mix(tPrev, tSlice, float(k) / 2.0);
            float t1 = mix(tPrev, tSlice, float(k + 1) / 2.0);
            float dt = t1 - t0;
            float3 p = origin + dir * (0.5 * (t0 + t1));
            float r = length(p);
            if (r < kBottomRadius) { r = kBottomRadius + 0.001; }
            float h = r - kBottomRadius;
            MediumSample m = sampleMedium(h);
            float3 up = p / length(p);
            float muS = dot(sunDir, up);
            float3 sunT = sampleTransmittance(transmittanceLUT, r, muS);
            float earthShadow = raySphere(p, sunDir, kBottomRadius) >= 0.0 ? 0.0 : 1.0;
            float3 ms = multiScatterLUT.sample(kLinearClamp, multiScatterUV(muS, h)).rgb;
            float3 S = u.sunIlluminance.rgb * (earthShadow * sunT * (m.scatteringRayleigh * phaseR + m.scatteringMie * phaseM) + ms * m.scattering);
            float3 sampleT = exp(-m.extinction * dt);
            L += T * (S - S * sampleT) / max(m.extinction, float3(1e-9));
            T *= sampleT;
        }
        tPrev = tSlice;
        out.write(float4(L, dot(T, float3(1.0 / 3.0))), uint3(gid, uint(s)));
    }
}

// MARK: - Lighting state: sky irradiance, sun at the camera, auto exposure (per frame)

struct LightingState {
    float4 skyIrradiance;    // rgb, onto an upward-facing surface
    float4 sunAtCamera;      // rgb, sun illuminance after transmittance, onto a surface facing it
    float4 exposure;         // x: current exposure, y: target exposure
    float4 fogColour;        // rgb: radiance of fog or mist lit by this light
};

kernel void lightingState(device LightingState &state [[buffer(0)]],
                          constant FrameUniforms &u [[buffer(1)]],
                          constant float &adaptation [[buffer(2)]],
                          texture2d<float> skyView [[texture(0)]],
                          texture2d<float> transmittanceLUT [[texture(1)]],
                          uint gid [[thread_position_in_grid]])
{
    if (gid != 0) return;
    float viewHeight = cameraRadius(u);
    float3 sunDir = u.sunDirection.xyz;
    // Cosine-weighted integral of sky radiance over the upper hemisphere.
    float3 E = 0.0;
    const int nTheta = 8, nPhi = 16;
    float dTheta = 0.5 * kPi / float(nTheta), dPhi = 2.0 * kPi / float(nPhi);
    for (int i = 0; i < nTheta; i++) {
        float theta = (float(i) + 0.5) * dTheta;
        for (int j = 0; j < nPhi; j++) {
            float phi = (float(j) + 0.5) * dPhi;
            float3 dir = float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
            float3 L = skyView.sample(kLinearClamp, skyViewUV(dir, sunDir, viewHeight)).rgb;
            E += L * cos(theta) * sin(theta) * dTheta * dPhi;
        }
    }
    float3 sunT = sampleTransmittance(transmittanceLUT, viewHeight, sunDir.z);
    float earthShadow = raySphere(float3(0, 0, viewHeight), sunDir, kBottomRadius) >= 0.0 ? 0.0 : 1.0;
    float3 sun = u.sunIlluminance.rgb * sunT * earthShadow;

    // Exposure that maps an 18% grey, horizontal surface under this light to mid grey. Below a
    // cloud deck that light is the overcast's: mostly diffuse, about a third of a clear day's.
    float3 total = E + sun * saturate(sunDir.z);
    if (u.cloudLight.z < u.cloudShadowShift.y) {
        float grey = dot(total, float3(0.2126, 0.7152, 0.0722)) * 0.33;
        total = mix(E + sun * saturate(sunDir.z) * u.cloudLight.y, float3(grey), u.cloudLight.x);
    }
    float lum = dot(total, float3(0.2126, 0.7152, 0.0722));
    // Partial adaptation, like an eye or a camera left on auto: full compensation would make
    // dusk look like noon. Calibrated so midday (luminance ~0.94 in these units, measured)
    // maps an 18% grey surface to mid grey; dimmer scenes get only 70% of the needed boost,
    // and the cap keeps night dark instead of amplifying faint twilight to daylight.
    float lumSafe = max(lum, 1e-7);
    float target = min(kPi / lumSafe * pow(lumSafe / 0.94, 0.3), 300.0);
    float current = state.exposure.x > 0.0 ? state.exposure.x : target;
    current = exp(mix(log(current), log(target), adaptation));

    state.skyIrradiance = float4(E, 0.0);
    state.sunAtCamera = float4(sun, 0.0);
    state.exposure = float4(current, target, 0.0, 0.0);
    // Mist scatters the light falling on it about as a white wall would.
    state.fogColour = float4(total * 0.8 / kPi, 0.0);
}
