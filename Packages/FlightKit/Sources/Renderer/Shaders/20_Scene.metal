// Scene passes: ground, runway, markings, aircraft, sky, shadow. Everything is shaded in the
// same way: sun through the atmosphere, sky and ground-bounce ambient, sky reflections, then
// aerial perspective. Output: HDR colour and motion vectors for temporal upscaling.

struct MeshVertex {
    float4 position;   // xyz model space
    float4 normal;     // xyz model space
    float2 uv;
    float2 pad;
};

struct DrawUniforms {
    float4x4 model;        // model -> camera-relative world, this frame
    float4x4 prevModel;    // model -> world relative to the previous frame's camera
    float4 baseColor;      // rgb albedo (multiplies the texture), a: opacity
    float4 material;       // x: roughness, y: metallic, z: textured (1/0), w: surface kind
    float4 emissive;       // rgb
};

// Surface kinds (material.w).
constant float kKindAircraft = 0.0;
constant float kKindRunway = 1.0;
constant float kKindMarking = 2.0;
constant float kKindGround = 3.0;
constant float kKindTerrain = 4.0;
constant float kKindPavement = 5.0;
constant float kKindBuilding = 6.0;
constant float kKindSign = 7.0;

constexpr sampler kTerrainSampler(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));

// Mean Earth radius for the ground plane's curvature, metres.
constant float kEarthRadiusMetres = 6371000.0;

struct VertexOut {
    float4 position [[position]];
    float3 worldPos;        // camera-relative, metres
    float3 normal;
    float2 uv;
    float4 currentClip;     // unjittered
    float4 previousClip;
    float seed [[flat]];    // per-building variation (city buildings), 0 otherwise
};

struct GBufferOut {
    float4 color [[color(0)]];
    float2 motion [[color(1)]];
};

vertex VertexOut sceneVertex(uint vid [[vertex_id]],
                             const device MeshVertex *vertices [[buffer(0)]],
                             constant FrameUniforms &u [[buffer(1)]],
                             constant DrawUniforms &d [[buffer(2)]])
{
    MeshVertex v = vertices[vid];
    float4 world = d.model * float4(v.position.xyz, 1.0);
    float4 prevWorld = d.prevModel * float4(v.position.xyz, 1.0);
    if (d.material.w == kKindGround) {
        // The ground plane follows the camera; drop it with Earth's curvature measured from the
        // scene origin (camera ENU position in emissive.xy) so it falls away to the horizon.
        float2 enu = world.xy + d.emissive.xy;
        float drop = dot(enu, enu) / (2.0 * kEarthRadiusMetres);
        world.z -= drop;
        prevWorld.z -= drop;
    }
    VertexOut o;
    o.position = u.viewProj * world;
    o.worldPos = world.xyz;
    o.normal = normalize((d.model * float4(v.normal.xyz, 0.0)).xyz);
    o.uv = v.uv;
    o.currentClip = u.viewProjNoJitter * world;
    o.previousClip = u.prevViewProjNoJitter * prevWorld;
    o.seed = 0.0;
    return o;
}

/// Terrain vertices, 20 bytes: position relative to the tile centre, a snorm8 normal and a
/// unorm16 texture coordinate (the index buffer is shared by every tile).
struct TerrainVertex {
    packed_float3 position;
    packed_char4 normal;
    packed_ushort2 uv;
};

vertex VertexOut terrainVertex(uint vid [[vertex_id]],
                               const device TerrainVertex *vertices [[buffer(0)]],
                               constant FrameUniforms &u [[buffer(1)]],
                               constant DrawUniforms &d [[buffer(2)]])
{
    TerrainVertex v = vertices[vid];
    float4 local = float4(float3(v.position), 1.0);
    float4 world = d.model * local;
    float4 prevWorld = d.prevModel * local;
    VertexOut o;
    o.position = u.viewProj * world;
    o.worldPos = world.xyz;
    o.normal = normalize(float3(char3(v.normal.xyz)) / 127.0);
    o.uv = float2(ushort2(v.uv)) / 65535.0;
    o.currentClip = u.viewProjNoJitter * world;
    o.previousClip = u.prevViewProjNoJitter * prevWorld;
    o.seed = 0.0;
    return o;
}

/// City buildings, 24 bytes: position, snorm8 normal with the building's seed in w, float uv.
struct CompactVertex {
    packed_float3 position;
    packed_char4 normal;
    packed_float2 uv;
};

vertex VertexOut compactVertex(uint vid [[vertex_id]],
                               const device CompactVertex *vertices [[buffer(0)]],
                               constant FrameUniforms &u [[buffer(1)]],
                               constant DrawUniforms &d [[buffer(2)]])
{
    CompactVertex v = vertices[vid];
    float4 local = float4(float3(v.position), 1.0);
    float4 world = d.model * local;
    float4 prevWorld = d.prevModel * local;
    VertexOut o;
    o.position = u.viewProj * world;
    o.worldPos = world.xyz;
    o.normal = normalize((d.model * float4(float3(char3(v.normal.xyz)) / 127.0, 0.0)).xyz);
    o.uv = float2(v.uv);
    o.currentClip = u.viewProjNoJitter * world;
    o.previousClip = u.prevViewProjNoJitter * prevWorld;
    o.seed = float(v.normal.w) / 127.0 * 0.5 + 0.5;
    return o;
}

inline float2 motionVector(float4 currentClip, float4 previousClip, constant FrameUniforms &u) {
    float2 cur = currentClip.xy / currentClip.w;
    float2 prev = previousClip.xy / previousClip.w;
    // NDC delta to pixels, pointing from this frame to the previous one (MetalFX convention).
    return (prev - cur) * float2(0.5, -0.5) * u.renderSize.xy;
}

// MARK: - Lighting

// LightingState is defined in 10_Atmosphere.metal.

inline float shadowFactor(float3 worldPos, constant FrameUniforms &u, depth2d<float> shadowMap) {
    if (u.shadowParams.x < 0.5) return 1.0;
    float4 sc = u.shadowViewProj * float4(worldPos, 1.0);
    float3 p = sc.xyz / sc.w;
    float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || p.z > 1.0) return 1.0;
    constexpr sampler cmp(filter::linear, address::clamp_to_edge, compare_func::less_equal);
    float texel = u.shadowParams.z;
    float sum = 0.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            sum += shadowMap.sample_compare(cmp, uv + float2(x, y) * texel, p.z - u.shadowParams.y);
    return sum / 9.0;
}

inline float3 fresnelSchlick(float cosTheta, float3 f0) {
    return f0 + (1.0 - f0) * pow(1.0 - saturate(cosTheta), 5.0);
}

inline float3 envBRDF(float3 f0, float roughness, float NdotV) {
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
    float2 ab = float2(-1.04, 1.04) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

inline float ggxSpecular(float NdotH, float NdotV, float NdotL, float roughness) {
    float a = roughness * roughness, a2 = a * a;
    float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    float D = a2 / (kPi * d * d);
    float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    float G = (NdotV / (NdotV * (1.0 - k) + k)) * (NdotL / (NdotL * (1.0 - k) + k));
    return D * G / max(4.0 * NdotV * NdotL, 1e-4);
}

inline float3 shadeSurface(float3 albedo, float roughness, float metallic, float3 N, float3 worldPos,
                           float shadow, constant FrameUniforms &u, const device LightingState &light,
                           texture2d<float> skyView)
{
    float3 V = normalize(-worldPos);
    float3 L = u.sunDirection.xyz;
    float3 H = normalize(V + L);
    float NdotL = saturate(dot(N, L));
    float NdotV = max(dot(N, V), 1e-3);
    float NdotH = saturate(dot(N, H));
    float3 f0 = mix(float3(0.04), albedo, metallic);
    float3 F = fresnelSchlick(saturate(dot(H, V)), f0);
    float3 diffuseColor = albedo * (1.0 - metallic);

    float3 sun = light.sunAtCamera.rgb;
    float3 direct = (diffuseColor / kPi * (1.0 - F) + F * ggxSpecular(NdotH, NdotV, NdotL, roughness)) * sun * NdotL * shadow;

    float3 skyE = light.skyIrradiance.rgb;
    float3 groundE = 0.25 * (skyE + sun * saturate(L.z));
    float up = N.z * 0.5 + 0.5;
    float3 ambientDiffuse = diffuseColor / kPi * (skyE * up + groundE * (1.0 - up));

    float3 R = reflect(-V, N);
    float viewHeight = kBottomRadius + max(u.atmosphere.x + u.atmosphere.y, 0.001);
    float3 skyRadiance = R.z > -0.02 ? skyView.sample(kLinearClamp, skyViewUV(R, L, viewHeight)).rgb : groundE / kPi;
    // Rough surfaces see a blurred sky: blend the mirror direction toward the mean sky radiance.
    float3 env = mix(skyRadiance, skyE / kPi, saturate(roughness * roughness * 1.2));
    // Split-sum environment BRDF (Karis's analytic fit): unlike bare Fresnel it falls off with
    // roughness at grazing angles, so rough ground does not turn white toward the horizon.
    float3 ambientSpecular = env * envBRDF(f0, roughness, NdotV);

    return direct + ambientDiffuse + ambientSpecular;
}

inline float3 applyAerialPerspective(float3 color, float3 worldPos, float4 screenPos,
                                     constant FrameUniforms &u, texture3d<float> aerial)
{
    float distanceKm = length(worldPos) * 0.001;
    float w = sqrt(saturate(distanceKm / u.atmosphere.z));
    float2 uv = screenPos.xy * u.renderSize.zw;
    float4 ap = aerial.sample(kLinearClamp, float3(uv, w));
    // Fade in across the first slice so the camera's immediate surroundings stay clear.
    float fade = saturate(w * float(kAerialSize.z));
    return color * mix(1.0, ap.a, fade) + ap.rgb * fade;
}

// MARK: - Surfaces

inline float3 groundAlbedo(float2 p, float distance) {
    // Sonoran desert floor around Phoenix: tan soil, darker creosote scrub, pale washes.
    float broad = fbm(p * 0.0022, 4);
    float mid = fbm(p * 0.031, 3);
    float fine = valueNoise(p * 0.9);
    float3 soil = float3(0.42, 0.34, 0.25);
    float3 scrub = float3(0.21, 0.22, 0.15);
    float3 wash = float3(0.52, 0.46, 0.38);
    float3 a = mix(soil, scrub, smoothstep(0.45, 0.70, mid) * 0.75);
    a = mix(a, wash, smoothstep(0.62, 0.78, broad) * 0.5);
    a *= 0.85 + 0.3 * broad;
    float detail = saturate(1.0 - distance / 250.0);
    a *= 1.0 + (fine - 0.5) * 0.25 * detail;
    return a;
}

inline float3 runwayAlbedo(float2 uvMetres, float2 runwaySize) {
    // uvMetres: x along the runway from its centre, y across it.
    float grain = fbm(uvMetres * float2(0.35, 0.8), 3);
    float patches = fbm(uvMetres * 0.012, 3);
    float3 asphalt = float3(0.105, 0.102, 0.098) * (0.85 + 0.3 * patches) * (0.92 + 0.16 * grain);
    // Rubber deposits on the centreline in each touchdown zone.
    float halfLen = runwaySize.x * 0.5;
    float fromEnd = halfLen - abs(uvMetres.x);
    float zone = smoothstep(120.0, 300.0, fromEnd) * (1.0 - smoothstep(700.0, 1100.0, fromEnd));
    float lane = 1.0 - smoothstep(4.0, 11.0, abs(uvMetres.y));
    float streaks = fbm(uvMetres * float2(0.04, 1.6), 2);
    float rubber = zone * lane * (0.55 + 0.45 * streaks);
    return mix(asphalt, float3(0.035, 0.034, 0.033), rubber * 0.85);
}

inline float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

/// Distance (metres) to the nearest joint of a slab grid.
inline float jointDistance(float2 p, float2 slab) {
    float2 f = fract(p / slab);
    float2 d = min(f, 1.0 - f) * slab;
    return min(d.x, d.y);
}

inline float3 concreteRunwayAlbedo(float2 uv, float2 size) {
    // Portland cement concrete: light grey, 7.6 m x 6.1 m slabs, darker joint sealant, tyre
    // rubber laid down in each touchdown zone and along the centreline.
    float2 slab = float2(7.6, 6.1);
    float tone = 0.94 + 0.12 * hash21(floor(uv / slab)) - 0.06;
    float stain = fbm(uv * 0.02, 3);
    float3 c = float3(0.34, 0.335, 0.32) * tone * (0.88 + 0.24 * stain);
    float joint = 1.0 - smoothstep(0.03, 0.09, jointDistance(uv, slab));
    c *= 1.0 - 0.3 * joint;
    float halfLen = size.x * 0.5;
    float fromEnd = halfLen - abs(uv.x);
    float zone = smoothstep(150.0, 320.0, fromEnd) * (1.0 - smoothstep(650.0, 1000.0, fromEnd));
    float lane = 1.0 - smoothstep(3.0, 12.0, abs(uv.y));
    float streaks = fbm(uv * float2(0.05, 1.4), 3);
    float rubber = zone * lane * (0.45 + 0.55 * streaks);
    return mix(c, float3(0.05, 0.05, 0.05), saturate(rubber * 0.95));
}

inline float3 pavementAlbedo(float2 uv, bool asphalt, float distance) {
    if (asphalt) {
        float g = fbm(uv * 0.3, 3), p = fbm(uv * 0.01, 3);
        return float3(0.12, 0.118, 0.112) * (0.85 + 0.3 * p) * (0.92 + 0.16 * g);
    }
    // Taxiway and apron concrete: 6 m slabs, each a slightly different tone, oil staining.
    float2 slab = float2(6.0, 6.0);
    float tone = 0.96 + 0.08 * hash21(floor(uv / slab));
    float3 c = float3(0.36, 0.35, 0.33) * tone * (0.9 + 0.2 * fbm(uv * 0.015, 3));
    float stains = smoothstep(0.62, 0.8, fbm(uv * 0.08 + 7.0, 3));
    c = mix(c, c * 0.55, stains * 0.6);
    float joint = (1.0 - smoothstep(0.02, 0.05, jointDistance(uv, slab))) * saturate(1.0 - distance / 250.0);
    return c * (1.0 - 0.22 * joint);
}

/// Generic facades: uv.x metres along the wall, uv.y metres up. Returns albedo; sets roughness
/// and the light that windows give off at night (`glow`, scene radiance).
inline float3 facadeAlbedo(float code, float2 uv, float3 N, thread float &roughness, thread float3 &glow, float seed = 0.0) {
    glow = float3(0.0);
    if (code == 9.0) {
        // City buildings: Phoenix and Los Angeles stucco, tile and membrane roofs, small windows.
        if (N.z > 0.7) {
            roughness = 0.85;
            float3 roofs[4] = { float3(0.55, 0.53, 0.50), float3(0.42, 0.22, 0.15), float3(0.30, 0.30, 0.30), float3(0.62, 0.60, 0.56) };
            return roofs[int(seed * 3.99)] * (0.88 + 0.24 * fbm(uv * 0.3, 2));
        }
        float3 walls[4] = { float3(0.62, 0.55, 0.45), float3(0.70, 0.67, 0.60), float3(0.55, 0.47, 0.38), float3(0.66, 0.62, 0.58) };
        float3 wall = walls[int(fract(seed * 7.13) * 3.99)];
        float2 w = fract(uv / float2(3.2, 3.0));
        float2 bay = floor(uv / float2(3.2, 3.0));
        // About two bays in five have a window; the rest is plain wall.
        bool window = w.x > 0.32 && w.x < 0.68 && w.y > 0.38 && w.y < 0.72 && uv.y > 0.8
            && hash21(bay + seed * 37.0) > 0.6;
        roughness = window ? 0.2 : 0.85;
        float on = step(0.6, hash21(bay + seed * 91.0));
        glow = window ? float3(1.0, 0.8, 0.52) * 1.0e-4 * on : float3(0.0);
        return window ? float3(0.06, 0.07, 0.08) : wall;
    }
    if (code == 8.0) {
        // Windsock: orange and white bands along the cone; the pole (uv.y < 0) white.
        roughness = 0.8;
        if (uv.y < -0.5) return float3(0.7, 0.7, 0.68);
        return fract(uv.x / 0.72) < 0.5 ? float3(0.85, 0.28, 0.04) : float3(0.82, 0.82, 0.80);
    }
    if (N.z > 0.7) {
        roughness = 0.9;
        return float3(0.36, 0.35, 0.33) * (0.85 + 0.3 * fbm(uv * 0.05, 3));
    }
    if (code == 7.0) {
        // Boarding bridge: light grey cladding with a band of windows.
        bool window = uv.y > 1.1 && uv.y < 2.1 && fract(uv.x / 1.4) > 0.15;
        roughness = window ? 0.15 : 0.5;
        glow = window ? float3(1.0, 0.85, 0.6) * 1.5e-4 : float3(0.0);
        return window ? float3(0.05, 0.06, 0.07) : float3(0.62, 0.63, 0.64);
    }
    if (code == 6.0) { roughness = 0.06; return float3(0.025, 0.035, 0.04); }   // tower cab glass
    if (code == 5.0) { roughness = 0.8; return float3(0.62, 0.60, 0.56); }      // tower shaft
    if (code == 1.0) {
        // Terminal: glass curtain wall, 1.5 m mullions, 4.5 m floors.
        float2 cell = fract(uv / float2(1.5, 4.5));
        bool frame = cell.x < 0.06 || cell.y < 0.08;
        roughness = frame ? 0.6 : 0.12;
        // Lit concourses: most panes glow warm at night, a few bays darker.
        float lit = 0.6 + 0.4 * hash21(floor(uv / float2(6.0, 4.5)));
        glow = frame ? float3(0.0) : float3(1.0, 0.86, 0.62) * 2.2e-4 * lit;
        return frame ? float3(0.55, 0.56, 0.57) : float3(0.05, 0.07, 0.09);
    }
    if (code == 2.0) {
        // Hangar: ribbed metal cladding.
        roughness = 0.55;
        float rib = 0.5 + 0.5 * cos(uv.x * 6.2831 / 0.3);
        return float3(0.66, 0.67, 0.68) * (0.9 + 0.1 * rib);
    }
    if (code == 4.0) {
        // Parking structure: concrete floors with open bays.
        roughness = 0.9;
        float f = fract(uv.y / 3.2);
        return f > 0.3 && f < 0.85 ? float3(0.03, 0.03, 0.03) : float3(0.55, 0.54, 0.51);
    }
    // Generic: stucco with a band of windows per storey.
    float2 w = fract(uv / float2(3.0, 3.6));
    bool window = w.x > 0.25 && w.x < 0.75 && w.y > 0.35 && w.y < 0.75 && uv.y > 1.0;
    roughness = window ? 0.15 : 0.85;
    float on = step(0.6, hash21(floor(uv / float2(3.0, 3.6)) + 5.0));
    glow = window ? float3(1.0, 0.82, 0.55) * 1.2e-4 * on : float3(0.0);
    return window ? float3(0.05, 0.06, 0.07) : float3(0.56, 0.50, 0.42) * (0.9 + 0.2 * fbm(uv * 0.2, 2));
}

/// One street light's contribution: a world-space disc that never shrinks below about a pixel,
/// with constant energy, kept only where the city is bright enough (hash against `level`).
inline float streetLight(float2 p, float2 centre, float level, float r, float salt) {
    float keep = step(hash21(centre * 0.0137 + salt), level);
    float2 d = p - centre;
    return keep * exp(-dot(d, d) / (r * r)) * (1.6 * 1.6) / (r * r);
}

/// City lights at night. `level` is NASA Black Marble brightness (about 500 m per pixel): it sets
/// how many lights there are and the faint average glow. The lights themselves follow a US street
/// grid: local streets every 201 m (1/8 mile) with a light every 46 m, arterials on the mile
/// lines, brighter, every 30 m on both sides.
inline float3 cityLights(float level, float2 p, float pixelMetres) {
    if (level < 0.02) return float3(0.0);
    float r = max(1.6, pixelMetres * 1.2);
    float dots = 0.0;
    const float S = 201.17, A = 45.7;
    float2 street = round(p / S) * S;
    dots += streetLight(p, float2(street.x + 6.0, round(p.y / A) * A), level * 1.1, r, 1.0);
    dots += streetLight(p, float2(round(p.x / A) * A, street.y + 6.0), level * 1.1, r, 2.0);
    const float M = 1609.34, B = 30.5;
    float2 artery = round(p / M) * M;
    for (int side = -1; side <= 1; side += 2) {
        dots += 2.5 * streetLight(p, float2(artery.x + 18.0 * side, round(p.y / B) * B), level * 1.6 + 0.2, r, 3.0 + side);
        dots += 2.5 * streetLight(p, float2(round(p.x / B) * B, artery.y + 18.0 * side), level * 1.6 + 0.2, r, 5.0 + side);
    }
    // Buildings and parking lots: scattered, dimmer lights on a 23 m lattice.
    const float P = 23.0;
    float2 lot = floor(p / P);
    float2 jitter = float2(hash21(lot + 11.0), hash21(lot + 17.0));
    dots += 0.55 * streetLight(p, (lot + 0.2 + jitter * 0.6) * P, level * 0.45, r, 9.0);
    // Sodium and LED mix: warm, slightly whiter on the arterials.
    float glow = level * level * 0.06;
    return float3(1.0, 0.68, 0.38) * (dots * 0.6 + glow) * 6.0e-4;
}

fragment GBufferOut sceneFragment(VertexOut in [[stage_in]],
                                  bool frontFacing [[front_facing]],
                                  constant FrameUniforms &u [[buffer(1)]],
                                  constant DrawUniforms &d [[buffer(2)]],
                                  const device LightingState &light [[buffer(3)]],
                                  texture2d<float> albedoTexture [[texture(0)]],
                                  texture2d<float> skyView [[texture(1)]],
                                  texture3d<float> aerial [[texture(2)]],
                                  depth2d<float> shadowMap [[texture(3)]],
                                  texture2d<float> nightLights [[texture(5)]])
{
    float kind = d.material.w;
    float3 N = normalize(in.normal);
    // Two-sided meshes (the aircraft) face the viewer; terrain normals (skirts included) are
    // authored pointing up and are used as they are.
    if (!frontFacing && kind != kKindTerrain) N = -N;
    float roughness = d.material.x;
    float3 albedo = d.baseColor.rgb;
    float3 windowGlow = float3(0.0);
    float distance = length(in.worldPos);

    if (kind == kKindGround) {
        albedo = groundAlbedo(in.worldPos.xy + u.noiseOrigin.xy, distance);
        N = float3(0, 0, 1);
    } else if (kind == kKindTerrain) {
        // Satellite imagery as albedo. The mosaic is colour-balanced for display, so scale it
        // toward measured surface reflectance; near the camera, break up the 10 m pixels.
        // Unsharp mask: the image plus a share of its difference from a blurrier mip, which
        // restores edges (roads, field boundaries, roofs) that filtering softens.
        float3 sharp = albedoTexture.sample(kTerrainSampler, in.uv).rgb;
        float3 soft = albedoTexture.sample(kTerrainSampler, in.uv, bias(1.5)).rgb;
        albedo = max(sharp + (sharp - soft) * 0.55, float3(0.0)) * d.baseColor.rgb;
        float detail = saturate(1.0 - distance / 1200.0);
        if (detail > 0.0) {
            float2 p = in.worldPos.xy + u.noiseOrigin.xy;
            float n = fbm(p * 0.21, 3) - 0.5;
            float fine = valueNoise(p * 1.7) - 0.5;
            // Grain within about 150 m: soil, gravel and scrub texture under the imagery's pixels.
            float grain = (valueNoise(p * 4.3) - 0.5) * saturate(1.0 - distance / 150.0);
            albedo *= 1.0 + (n * 0.26 + fine * 0.12) * detail + grain * 0.14;
        }
    } else if (kind == kKindRunway) {
        albedo = d.emissive.z > 0.5 ? concreteRunwayAlbedo(in.uv, d.emissive.xy) : runwayAlbedo(in.uv, d.emissive.xy);
        N = float3(0, 0, 1);
    } else if (kind == kKindMarking) {
        // Atlas paint (runway numbers and bars) is masked by the atlas; plain paint is solid.
        if (d.material.z > 0.5) {
            float mask = albedoTexture.sample(kLinearRepeat, in.uv).r;
            if (mask < 0.5) discard_fragment();
        }
        float wear = fbm((in.worldPos.xy + u.noiseOrigin.xy) * 0.7, 2);
        albedo = d.baseColor.rgb * (0.88 + 0.2 * wear);
        N = float3(0, 0, 1);
    } else if (kind == kKindPavement) {
        albedo = pavementAlbedo(in.uv, d.emissive.x > 0.5, distance);
        N = float3(0, 0, 1);
    } else if (kind == kKindSign) {
        albedo = albedoTexture.sample(kLinearClamp, in.uv).rgb;
    } else if (kind == kKindBuilding) {
        albedo = facadeAlbedo(d.emissive.x, in.uv, N, roughness, windowGlow, in.seed);
    } else if (d.material.z > 0.5) {
        float4 t = albedoTexture.sample(kLinearRepeat, in.uv);
        albedo *= t.rgb;
    }

    float shadow = shadowFactor(in.worldPos, u, shadowMap);
    float3 color = shadeSurface(albedo, roughness, d.material.y, N, in.worldPos, shadow, u, light, skyView);
    color += d.emissive.rgb * (kind == kKindAircraft ? 1.0 : 0.0);
    float night = smoothstep(0.05, -0.08, u.sunDirection.z);
    color += windowGlow * night;
    if (kind == kKindPavement && d.emissive.y > 0.5) {
        // Aprons under high-mast floodlights. Real aprons get about 20 lux; the renderer adapts
        // only partially to night (exposure is capped), so 20 lux would read as black where a
        // dark-adapted eye sees a lit apron. 120 is a perceptual value, not a measured one.
        color += albedo / kPi * (120.0 / 120000.0) * float3(1.0, 0.88, 0.70) * night;
    }
    if (kind == kKindSign) {
        // Signs are lit from inside at night.
        color += albedo * 4.0e-4 * smoothstep(0.05, -0.08, u.sunDirection.z);
    }
    if (kind == kKindTerrain && d.emissive.w > 0.5) {
        float dark = smoothstep(0.03, -0.10, u.sunDirection.z);
        if (dark > 0.0) {
            color += cityLights(nightLights.sample(kLinearClamp, in.uv * d.emissive.x + d.emissive.yz).r,
                                in.worldPos.xy + u.noiseOrigin.xy, length(dfdx(in.worldPos.xy))) * dark;
        }
    }
    color = applyAerialPerspective(color, in.worldPos, in.position, u, aerial);

    GBufferOut o;
    o.color = float4(color, 1.0);
    o.motion = motionVector(in.currentClip, in.previousClip, u);
    return o;
}

/// Transparent aircraft parts (windows): premultiplied alpha over the opaque scene.
fragment float4 glassFragment(VertexOut in [[stage_in]],
                              bool frontFacing [[front_facing]],
                              constant FrameUniforms &u [[buffer(1)]],
                              constant DrawUniforms &d [[buffer(2)]],
                              const device LightingState &light [[buffer(3)]],
                              texture2d<float> albedoTexture [[texture(0)]],
                              texture2d<float> skyView [[texture(1)]],
                              texture3d<float> aerial [[texture(2)]],
                              depth2d<float> shadowMap [[texture(3)]])
{
    float3 N = normalize(in.normal);
    if (!frontFacing) N = -N;
    float alpha = d.baseColor.a;
    float3 albedo = d.baseColor.rgb;
    if (d.material.z > 0.5) {
        float4 t = albedoTexture.sample(kLinearRepeat, in.uv);
        albedo *= t.rgb;
        alpha *= t.a;
    }
    float shadow = shadowFactor(in.worldPos, u, shadowMap);
    float3 color = shadeSurface(albedo, 0.05, 0.0, N, in.worldPos, shadow, u, light, skyView);
    color = applyAerialPerspective(color, in.worldPos, in.position, u, aerial);
    // Glass reflects more at grazing angles.
    float3 V = normalize(-in.worldPos);
    float fresnel = 0.04 + 0.96 * pow(1.0 - saturate(abs(dot(N, V))), 5.0);
    float a = saturate(max(alpha, fresnel));
    return float4(color * a, a);
}

// MARK: - Sky

struct SkyOut {
    float4 position [[position]];
    float2 ndc;
};

vertex SkyOut skyVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    SkyOut o;
    o.position = float4(p, 0.0, 1.0);   // reverse-Z: depth 0 is infinitely far
    o.ndc = p;
    return o;
}

fragment GBufferOut skyFragment(SkyOut in [[stage_in]],
                                constant FrameUniforms &u [[buffer(1)]],
                                texture2d<float> skyView [[texture(1)]],
                                texture2d<float> transmittanceLUT [[texture(4)]])
{
    float4 world = u.invViewProjNoJitter * float4(in.ndc, 0.5, 1.0);
    float3 dir = normalize(world.xyz / world.w);
    float viewHeight = kBottomRadius + max(u.atmosphere.x + u.atmosphere.y, 0.001);
    float3 sunDir = u.sunDirection.xyz;
    float3 L = skyView.sample(kLinearClamp, skyViewUV(dir, sunDir, viewHeight)).rgb;

    // Sun disk: 0.53 degrees across, limb darkened, behind the atmosphere's transmittance.
    float cosAngle = dot(dir, sunDir);
    const float cosRadius = cos(0.2665 * kPi / 180.0);
    if (cosAngle > cosRadius && raySphere(float3(0, 0, viewHeight), dir, kBottomRadius) < 0.0) {
        float3 T = sampleTransmittance(transmittanceLUT, viewHeight, dir.z);
        float solidAngle = 2.0 * kPi * (1.0 - cosRadius);
        float x = saturate((1.0 - cosAngle) / (1.0 - cosRadius));
        float limb = 1.0 - 0.6 * (1.0 - sqrt(max(0.0, 1.0 - x)));
        L += u.sunIlluminance.rgb / solidAngle * T * limb;
    }

    // Motion for a point at infinity: only camera rotation moves it.
    float4 cur = u.viewProjNoJitter * float4(dir, 0.0);
    float4 prev = u.prevViewProjNoJitter * float4(dir, 0.0);
    GBufferOut o;
    o.color = float4(L, 1.0);
    o.motion = motionVector(cur, prev, u);
    return o;
}

// MARK: - Shadow map

vertex float4 shadowVertex(uint vid [[vertex_id]],
                           const device MeshVertex *vertices [[buffer(0)]],
                           constant FrameUniforms &u [[buffer(1)]],
                           constant DrawUniforms &d [[buffer(2)]])
{
    float4 world = d.model * float4(vertices[vid].position.xyz, 1.0);
    return u.shadowViewProj * world;
}
