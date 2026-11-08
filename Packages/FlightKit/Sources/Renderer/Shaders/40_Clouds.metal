// Volumetric clouds from the METAR's layers. A 3D noise texture (Perlin-Worley base, Worley
// detail) is made once and its base channel equalized, so "keep the noise above 1 - coverage"
// covers that fraction of the layer. Each frame a compute pass marches the layers at half the
// render resolution (stopping at the scene's depth), and a full-screen pass blends the result into
// the HDR image with the atmosphere between camera and cloud. Layer heights follow the Earth's
// curvature; the field drifts with the wind. Lit by the sun (self-shadowed toward it, with
// multiple-scattering octaves after Wrenninge) and the sky.

struct CloudLayerGPU {
    float4 shape;   // x: base (m above sea level), y: top, z: coverage 0-1,
                    // w: kind (0 stratus, 1 cumulus, 2 cumulonimbus, 3 cirrus)
    float4 style;   // x: extinction at full density (1/m), y: shape noise scale (m), z: detail scale (m)
};

struct CloudUniforms {
    CloudLayerGPU layers[3];
    float4 camera;  // xy: camera position in the scene frame (m), w: camera height above sea level (m)
    float4 wind;    // xy: accumulated wind drift (m), z: layer count, w: jitter seed
    float4 size;    // xy: cloud target size (px), zw: 1/size
    float4 bounds;  // x: lowest base, y: highest top (m above sea level), z: march range (m),
                    // w: weight of last frame's clouds (0 after a cut)
};

constant float kEarthRadiusM = 6371000.0;

// MARK: Noise generation

inline float3 cloudHash(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

/// Tileable Worley noise: 1 at a feature point, falling toward 0; `cells` cells per period.
inline float cloudWorley(float3 p, float cells) {
    float3 q = p * cells;
    float3 i = floor(q), f = fract(q);
    float d = 1.0;
    for (int z = -1; z <= 1; z++)
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++) {
                float3 o = float3(x, y, z);
                float3 cell = fmod(i + o + cells, cells);
                float3 pt = o + cloudHash(cell) - f;
                d = min(d, dot(pt, pt));
            }
    return 1.0 - saturate(sqrt(d));
}

/// Tileable value noise.
inline float cloudValue(float3 p, float period) {
    float3 q = p * period;
    float3 i = floor(q), f = fract(q);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n = 0.0;
    for (int z = 0; z <= 1; z++)
        for (int y = 0; y <= 1; y++)
            for (int x = 0; x <= 1; x++) {
                float3 c = fmod(i + float3(x, y, z), period);
                float w = (x ? u.x : 1.0 - u.x) * (y ? u.y : 1.0 - u.y) * (z ? u.z : 1.0 - u.z);
                n += w * cloudHash(c).x;
            }
    return n;
}

inline float cloudRemap(float v, float lo, float hi, float a, float b) {
    return a + saturate((v - lo) / max(hi - lo, 1e-5)) * (b - a);
}

kernel void cloudNoise(texture3d<float, access::write> out [[texture(0)]],
                       uint3 gid [[thread_position_in_grid]])
{
    uint n = out.get_width();
    if (any(gid >= n)) return;
    float3 p = (float3(gid) + 0.5) / float(n);
    float value = (cloudValue(p, 4) * 0.5 + cloudValue(p, 8) * 0.25 + cloudValue(p, 16) * 0.125
                   + cloudValue(p, 32) * 0.0625) / 0.9375;
    float w4 = cloudWorley(p, 4), w8 = cloudWorley(p, 8), w16 = cloudWorley(p, 16), w32 = cloudWorley(p, 32);
    float worleyFbm = w4 * 0.625 + w8 * 0.25 + w16 * 0.125;
    // Perlin-Worley (Schneider 2015): the smooth noise pushed up inside Worley cells, so it
    // reads as rounded billows with clean gaps between them.
    float pw = cloudRemap(value, worleyFbm - 1.0, 1.0, 0.0, 1.0);
    out.write(float4(pw, w8, w16, w32), gid);
}

kernel void cloudNoiseHistogram(texture3d<float, access::read> raw [[texture(0)]],
                                device atomic_uint *bins [[buffer(0)]],
                                uint3 gid [[thread_position_in_grid]])
{
    if (any(gid >= raw.get_width())) return;
    uint b = min(uint(raw.read(gid).r * 255.0 + 0.5), 255u);
    atomic_fetch_add_explicit(&bins[b], 1u, memory_order_relaxed);
}

/// Replaces the base channel with its rank (cumulative histogram), so it is uniform on 0-1.
kernel void cloudNoiseEqualize(texture3d<float, access::read> raw [[texture(0)]],
                               texture3d<float, access::write> out [[texture(1)]],
                               device const uint *bins [[buffer(0)]],
                               uint3 gid [[thread_position_in_grid]])
{
    uint n = raw.get_width();
    if (any(gid >= n)) return;
    float4 v = raw.read(gid);
    uint b = min(uint(v.r * 255.0 + 0.5), 255u);
    uint below = 0;
    for (uint i = 0; i < b; i++) below += bins[i];
    v.r = (float(below) + 0.5 * float(bins[b])) / float(n * n * n);
    out.write(v, gid);
}

// MARK: Density

/// Extinction (1/m) at a camera-relative point. `heightFraction` gets the point's height within
/// the layer it is in (0 base, 1 top).
inline float cloudDensity(float3 p, constant CloudUniforms &c, texture3d<float> noise, bool detailed,
                          thread float &heightFraction)
{
    constexpr sampler s(filter::linear, address::repeat);
    float h = p.z + c.camera.w + dot(p.xy, p.xy) * (0.5 / kEarthRadiusM);
    if (h <= c.bounds.x || h >= c.bounds.y) return 0.0;
    float2 xy = p.xy + c.camera.xy + c.wind.xy;
    float density = 0.0;
    int count = int(c.wind.z);
    for (int i = 0; i < count; i++) {
        float4 L = c.layers[i].shape, S = c.layers[i].style;
        float t = (h - L.x) / max(L.y - L.x, 1.0);
        if (t <= 0.0 || t >= 1.0) continue;
        heightFraction = t;
        int kind = int(L.w + 0.5);
        float scale = S.y;
        float2 wxy = xy / scale;
        // Large-scale weather: coverage wanders between patches tens of kilometres across, so the
        // shape noise's tiling never shows and a scattered sky has gaps and clumps.
        float weather = noise.sample(s, float3(wxy * 0.113, 0.23 + 0.31 * float(i))).r * 0.65
                      + noise.sample(s, float3(wxy * 0.041, 0.67)).r * 0.35;
        // No spread at 0 (clear) or 1 (overcast); widest for scattered.
        float cov = saturate(L.z + (weather - 0.5) * 3.6 * L.z * (1.0 - L.z));
        float3 q;
        float profile;
        if (kind == 3) {
            // Cirrus: thin, streaked along the drift.
            q = float3(xy.x / (scale * 5.0), xy.y / scale, t * 0.2);
            profile = smoothstep(0.0, 0.4, t) * (1.0 - smoothstep(0.6, 1.0, t));
        } else {
            // Deep layers (towering cumulus, cumulonimbus) stretch the noise upward into columns.
            float vertical = scale * max(1.0, (L.y - L.x) / (0.5 * scale));
            q = float3(wxy, h / vertical);
            if (kind == 0) {
                profile = smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.55, 1.0, t));
            } else if (kind == 1) {
                // Cumulus: flat, sharp base, rounded top that narrows with height.
                profile = smoothstep(0.0, 0.07, t) * (1.0 - smoothstep(0.2, 1.0, t) * 0.85);
                profile *= 1.0 - smoothstep(0.75, 1.0, t);
            } else {
                // Cumulonimbus: a tower that spreads into an anvil near the top.
                profile = smoothstep(0.0, 0.04, t) * (1.0 - smoothstep(0.92, 1.0, t));
                profile *= mix(0.85, 1.25, smoothstep(0.75, 0.9, t));
                // The anvil: the top spreads far wider than the tower.
                cov = saturate(cov * (1.0 + 1.6 * smoothstep(0.78, 0.92, t)));
            }
        }
        float base = noise.sample(s, q).r;
        float shape = cloudRemap(base * profile, 1.0 - cov, 1.0, 0.0, 1.0);
        // An overcast deck has texture underneath but no thin spots.
        shape = max(shape, profile * saturate(cov - 0.8) * 3.0);
        if (shape <= 0.0) continue;
        if (detailed) {
            float4 d = noise.sample(s, q * (scale / S.z));
            float detail = d.g * 0.625 + d.b * 0.25 + d.a * 0.125;
            // Wispy (inverted Worley) near the base, billowy above.
            detail = mix(1.0 - detail, detail, saturate(t * 5.0));
            shape = cloudRemap(shape, detail * 0.35, 1.0, 0.0, 1.0);
        }
        density += shape * S.x;
    }
    return density;
}

inline float cloudPhase(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * kPi * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 1e-4), 1.5));
}

/// Sorted roots of a t^2 + b t + c = 0, or (huge, -huge) when there are none.
inline float2 cloudRoots(float a, float b, float c) {
    float disc = b * b - 4.0 * a * c;
    if (disc < 0.0) return float2(1e30, -1e30);
    float sq = sqrt(disc);
    float q = -0.5 * (b + (b >= 0.0 ? sq : -sq));
    float r1 = q / a;
    float r2 = abs(q) > 1e-20 ? c / q : r1;
    return float2(min(r1, r2), max(r1, r2));
}

// MARK: March

kernel void cloudMarch(texture2d<float, access::write> radiance [[texture(0)]],
                       texture2d<float, access::write> distanceOut [[texture(1)]],
                       texture3d<float> noise [[texture(2)]],
                       depth2d<float, access::read> sceneDepth [[texture(3)]],
                       constant FrameUniforms &u [[buffer(0)]],
                       constant CloudUniforms &c [[buffer(1)]],
                       const device LightingState &light [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(c.size.x) || gid.y >= uint(c.size.y)) return;
    float2 uv = (float2(gid) + 0.5) * c.size.zw;
    float4 clip = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.5, 1.0);
    float4 w4 = u.invViewProjNoJitter * clip;
    float3 dir = normalize(w4.xyz / w4.w);

    // Stop at whatever the scene drew (reverse-Z: 0 is the sky).
    float tMax = c.bounds.z;
    uint2 dpx = min(uint2(uv * u.renderSize.xy), uint2(u.renderSize.xy) - 1);
    float depth = sceneDepth.read(dpx);
    if (depth > 0.0) {
        float4 sp = u.invViewProjNoJitter * float4(clip.xy, depth, 1.0);
        tMax = min(tMax, length(sp.xyz / sp.w));
    }

    // Where the ray is between the lowest base and the highest top. Height along the ray is
    // camH + t dz + t^2 (1 - dz^2) / 2R (the curved Earth), a parabola in t, so the in-slab part
    // is up to two segments: [enter top, reach base] and [leave base, leave top].
    float a = max((1.0 - dir.z * dir.z) * (0.5 / kEarthRadiusM), 1e-12);
    float camH = c.camera.w;
    float2 hiR = cloudRoots(a, dir.z, camH - c.bounds.y);
    float2 loR = cloudRoots(a, dir.z, camH - c.bounds.x);
    bool hasLo = loR.x <= loR.y;
    float2 segA = float2(hiR.x, hasLo ? loR.x : hiR.y);
    float2 segB = hasLo ? float2(loR.y, hiR.y) : float2(1e30, -1e30);
    segA = float2(max(segA.x, 0.0), min(segA.y, tMax));
    segB = float2(max(segB.x, 0.0), min(segB.y, tMax));
    float2 seg = segA.y > segA.x ? segA : segB;

    float3 L = 0.0;
    float T = 1.0;
    float weightedDistance = 0.0, weight = 0.0;
    int count = int(c.wind.z);
    if (count > 0 && seg.y > seg.x) {
        float span = seg.y - seg.x;
        int steps = clamp(int(ceil(span / 30.0)), 8, 64);
        float dt = span / float(steps);
        // A different random start each frame; the resolve pass averages them out.
        float jitter = cloudHash(float3(float2(gid) * 1.37, c.wind.w * 0.731 + 0.5)).x;
        float3 sunDir = u.sunDirection.xyz;
        float cosTheta = dot(dir, sunDir);
        float3 sun = light.sunAtCamera.rgb;
        // Sun below the horizon still lights high clouds a little (twilight), never negatively.
        float3 sky = light.skyIrradiance.rgb;
        float3 groundBounce = 0.25 * (sun * saturate(sunDir.z) + sky);
        // Phase for each multiple-scattering octave: forward lobe and a weaker back lobe,
        // flattening with each octave.
        float phases[3];
        for (int o = 0; o < 3; o++) {
            float g = 0.8 * pow(0.5, float(o));
            phases[o] = mix(cloudPhase(cosTheta, g), cloudPhase(cosTheta, -0.3 * pow(0.5, float(o))), 0.3);
        }
        float fadeStart = c.bounds.z * 0.6;
        for (int k = 0; k < steps; k++) {
            float t = seg.x + (float(k) + jitter) * dt;
            float3 p = dir * t;
            float hf = 0.0;
            float sigma = cloudDensity(p, c, noise, true, hf);
            if (sigma <= 0.0) continue;
            sigma *= 1.0 - smoothstep(fadeStart, c.bounds.z, t);
            // Optical depth toward the sun, through six growing segments (about 2.5 km).
            float od = 0.0, segLen = 40.0, along = 0.0;
            for (int j = 0; j < 6; j++) {
                float3 q = p + sunDir * (along + segLen * 0.5);
                float unused = 0.0;
                od += cloudDensity(q, c, noise, false, unused) * segLen;
                along += segLen;
                segLen *= 2.0;
            }
            float scatter = 0.0, aw = 1.0, bw = 1.0;
            for (int o = 0; o < 3; o++) {
                scatter += aw * phases[o] * exp(-od * bw);
                aw *= 0.5; bw *= 0.25;
            }
            // Dark edges facing the viewer ("powder"): thin fringes scatter less back at you.
            float powder = 1.0 - 0.55 * exp(-sigma * 120.0);
            float3 ambient = (sky * mix(0.35, 1.0, hf) + groundBounce * (1.0 - hf)) / (2.0 * kPi);
            // Light that has diffused through the cloud (many scatterings) emerges far more
            // evenly than single scattering suggests: diffuse transmission of a slab of optical
            // depth od with asymmetry 0.85 is about 1 / (1 + 0.75 od (1 - g)).
            float diffuse = 1.0 / (1.0 + 0.11 * od);
            float3 S = sun * (scatter * 1.5 + 0.18 * diffuse) * powder + ambient;
            float sampleT = exp(-sigma * dt);
            L += T * S * (1.0 - sampleT);
            weightedDistance += T * (1.0 - sampleT) * t;
            weight += T * (1.0 - sampleT);
            T *= sampleT;
            if (T < 0.01) break;
        }
    }
    radiance.write(float4(L, T), gid);
    distanceOut.write(float4(weight > 1e-4 ? weightedDistance / weight : 1e9, 0, 0, 0), gid);
}

// MARK: Shadow map

/// Sun transmittance through the clouds for rays leaving the map's reference height, on a grid
/// around the camera (u texel coordinates run east, v north). The scene reads it for cloud shadows.
kernel void cloudShadowMap(texture2d<float, access::write> out [[texture(0)]],
                           texture3d<float> noise [[texture(1)]],
                           constant FrameUniforms &u [[buffer(0)]],
                           constant CloudUniforms &c [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    uint n = out.get_width();
    if (gid.x >= n || gid.y >= n) return;
    float2 xy = u.cloudShadow.zw + ((float2(gid) + 0.5) / float(n) - 0.5) / u.cloudShadow.y;
    float refH = u.cloudShadowShift.x;
    float3 toSun = normalize(float3(u.sunDirection.xy, max(u.sunDirection.z, 0.08)));
    float3 p0 = float3(xy, refH - c.camera.w);
    float s0 = max((c.bounds.x - refH) / toSun.z, 0.0);
    // Through at most 8 km of cloud (a cumulonimbus is opaque long before that).
    float s1 = min(max((c.bounds.y - refH) / toSun.z, 0.0), s0 + 8000.0);
    const int steps = 24;
    float ds = (s1 - s0) / float(steps);
    float od = 0.0, unused = 0.0;
    for (int k = 0; k < steps; k++) {
        float3 p = p0 + toSun * (s0 + (float(k) + 0.5) * ds);
        od += cloudDensity(p, c, noise, false, unused) * ds;
    }
    out.write(float4(exp(-od), 0.0, 0.0, 0.0), gid);
}

// MARK: Temporal resolve

/// Blends this frame's (noisy, jittered) march with last frame's result reprojected to where the
/// cloud now is, clamped to this frame's neighbourhood so moving cloud edges do not smear.
kernel void cloudResolve(texture2d<float, access::read> current [[texture(0)]],
                         texture2d<float, access::read> currentDistance [[texture(1)]],
                         texture2d<float> history [[texture(2)]],
                         texture2d<float> historyDistance [[texture(3)]],
                         texture2d<float, access::write> outColour [[texture(4)]],
                         texture2d<float, access::write> outDistance [[texture(5)]],
                         constant FrameUniforms &u [[buffer(0)]],
                         constant CloudUniforms &c [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]])
{
    int2 size = int2(c.size.xy);
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    float4 cur = current.read(gid);
    float d = currentDistance.read(gid).r;
    float4 lo = cur, hi = cur;
    float nearest = d;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            uint2 q = uint2(clamp(int2(gid) + int2(x, y), int2(0), size - 1));
            float4 v = current.read(q);
            lo = min(lo, v);
            hi = max(hi, v);
            nearest = min(nearest, currentDistance.read(q).r);
        }
    float2 uv = (float2(gid) + 0.5) * c.size.zw;
    float4 clip = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.5, 1.0);
    float4 w4 = u.invViewProjNoJitter * clip;
    float3 dir = normalize(w4.xyz / w4.w);
    float dist = nearest < 1e8 ? nearest : c.bounds.z;
    float4 pc = u.prevViewProjNoJitter * float4(dir * dist + u.cameraDelta.xyz, 1.0);
    float blend = c.bounds.w;
    float2 puv = float2(0.0);
    if (pc.w <= 0.0) {
        blend = 0.0;
    } else {
        puv = float2(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5);
        if (any(puv < 0.0) || any(puv > 1.0)) blend = 0.0;
    }
    float4 h = clamp(history.sample(kLinearClamp, puv), lo, hi);
    outColour.write(mix(cur, h, blend), gid);
    float hd = historyDistance.sample(kLinearClamp, puv).r;
    outDistance.write(float4(blend > 0.0 && hd < 1e8 && d < 1e8 ? mix(d, hd, blend) : d, 0, 0, 0), gid);
}

// MARK: Composite

/// Blended over the HDR image as colour * alpha + rgb: cloud light plus the atmosphere between
/// camera and cloud, with the scene's own colour kept by the cloud's transmittance. Pixels nearer
/// than the cloud keep their colour.
fragment float4 cloudCompositeFragment(FullscreenOut in [[stage_in]],
                                       constant FrameUniforms &u [[buffer(1)]],
                                       texture2d<float> clouds [[texture(0)]],
                                       texture2d<float> cloudDistance [[texture(1)]],
                                       depth2d<float, access::read> sceneDepth [[texture(2)]],
                                       texture3d<float> aerial [[texture(3)]],
                                       const device LightingState &light [[buffer(2)]])
{
    float4 cl = clouds.sample(kLinearClamp, in.uv);
    if (cl.a > 0.999) return float4(0.0, 0.0, 0.0, 1.0);
    float dist = cloudDistance.sample(kLinearClamp, in.uv).r;
    float depth = sceneDepth.read(uint2(in.position.xy));
    if (depth > 0.0) {
        float4 clip = float4(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0, depth, 1.0);
        float4 w = u.invViewProjNoJitter * clip;
        if (length(w.xyz / w.w) < dist * 0.9) return float4(0.0, 0.0, 0.0, 1.0);
    }
    float slice = sqrt(saturate(dist * 0.001 / u.atmosphere.z));
    float4 ap = aerial.sample(kLinearClamp, float3(in.uv, slice));
    float opacity = 1.0 - cl.a;
    float3 colour = cl.rgb * ap.a + ap.rgb * opacity;
    // Mist between camera and cloud.
    float4 w4 = u.invViewProjNoJitter * float4(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0, 0.5, 1.0);
    float fogT = exp(-fogDepth(normalize(w4.xyz / w4.w), min(dist, 1e6), u));
    colour = colour * fogT + light.fogColour.rgb * opacity * (1.0 - fogT);
    return float4(colour, cl.a);
}
