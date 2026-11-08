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
constant float kKindTree = 8.0;
constant float kKindParked = 9.0;

constexpr sampler kTerrainSampler(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(16));

// Mean Earth radius for the ground plane's curvature, metres.
constant float kEarthRadiusMetres = 6371000.0;

struct VertexOut {
    float4 position [[position]];
    float3 worldPos;        // camera-relative, metres
    float3 normal;
    float2 uv;
    float4 currentClip;     // unjittered
    float4 previousClip;
    float seed;             // city buildings: per-building variation; terrain: 1 on open water
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
    o.seed = float(v.normal.w) / 127.0;     // terrain: 1 on open water
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

/// Trees: a shared mesh (pairs of float4: position with the part in w, normal) placed by
/// instances (float4 position and canopy radius, float4 height, seed). A quarter are palms: a tall
/// slim trunk under a flat crown.
struct TreeInstanceGPU {
    float4 positionRadius;
    float4 params;
};

inline float3 treePoint(float4 v, TreeInstanceGPU t, thread float3 &n) {
    float r = t.positionRadius.w, h = t.params.x, seed = t.params.y;
    bool palm = seed > 0.75;
    float trunkTop = palm ? h * 0.85 : h * 0.32;
    float3 p;
    if (v.w > 0.5) {
        float tr = palm ? 0.16 : max(0.12, r * 0.07);
        p = float3(v.xy * tr, v.z * (trunkTop + 0.4));
    } else {
        float rr = palm ? r * 1.05 : r;
        float halfHeight = palm ? rr * 0.32 : (h - trunkTop) * 0.5;
        p = float3(v.xy * rr, v.z * halfHeight);
        p.z += palm ? h - halfHeight : trunkTop + halfHeight;
        n = normalize(float3(n.xy / rr, n.z / halfHeight) + float3(0, 0, 0.6));
    }
    float a = seed * 6.2831;
    float2x2 rot = float2x2(float2(cos(a), sin(a)), float2(-sin(a), cos(a)));
    p.xy = rot * p.xy;
    n.xy = rot * n.xy;
    return t.positionRadius.xyz + p;
}

vertex VertexOut treeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device float4 *mesh [[buffer(0)]],
                            constant FrameUniforms &u [[buffer(1)]],
                            constant DrawUniforms &d [[buffer(2)]],
                            const device TreeInstanceGPU *trees [[buffer(3)]])
{
    float4 v = mesh[vid * 2];
    float3 n = mesh[vid * 2 + 1].xyz;
    TreeInstanceGPU t = trees[iid];
    float4 local = float4(treePoint(v, t, n), 1.0);
    float4 world = d.model * local;
    VertexOut o;
    o.position = u.viewProj * world;
    o.worldPos = world.xyz;
    o.normal = normalize((d.model * float4(n, 0.0)).xyz);
    o.uv = float2(v.w, 0.0);
    o.currentClip = u.viewProjNoJitter * world;
    o.previousClip = u.prevViewProjNoJitter * (d.prevModel * local);
    o.seed = t.params.y;
    return o;
}

/// Parked airliners: a shared mesh (MeshVertex, body frame x forward, y left) placed by
/// instances (x, y, z, heading radians; seed).
struct ParkedInstance {
    float4 positionHeading;
    float4 params;
};

/// Body axes (x forward, y left, z up) to the airport frame: roll (params.z, right wing down
/// positive), pitch (params.y, nose up positive), then heading (positionHeading.w, from north).
inline float3 parkedRotate(float3 p, ParkedInstance t) {
    float cr = cos(t.params.z), sr = sin(t.params.z);
    float3 q = float3(p.x, p.y * cr - p.z * sr, p.z * cr + p.y * sr);
    float cp = cos(t.params.y), sp = sin(t.params.y);
    q = float3(q.x * cp - q.z * sp, q.y, q.z * cp + q.x * sp);
    float h = t.positionHeading.w;
    float2 fwd = float2(sin(h), cos(h)), left = float2(-cos(h), sin(h));
    return float3(fwd * q.x + left * q.y, q.z);
}

inline float3 parkedPoint(float3 p, ParkedInstance t) {
    return t.positionHeading.xyz + parkedRotate(p, t);
}

vertex VertexOut parkedVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device MeshVertex *vertices [[buffer(0)]],
                              constant FrameUniforms &u [[buffer(1)]],
                              constant DrawUniforms &d [[buffer(2)]],
                              const device ParkedInstance *instances [[buffer(3)]])
{
    MeshVertex v = vertices[vid];
    ParkedInstance t = instances[iid];
    float4 local = float4(parkedPoint(v.position.xyz, t), 1.0);
    float3 nl = parkedRotate(v.normal.xyz, t);
    float4 world = d.model * local;
    VertexOut o;
    o.position = u.viewProj * world;
    o.worldPos = world.xyz;
    o.normal = normalize((d.model * float4(nl, 0.0)).xyz);
    o.uv = v.uv;
    o.currentClip = u.viewProjNoJitter * world;
    o.previousClip = u.prevViewProjNoJitter * (d.prevModel * local);
    o.seed = t.params.x;
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

/// Sun transmittance through the clouds (the cloud shadow map around the view). The map holds
/// rays from its reference height; a point higher up reads the texel whose ray crosses the clouds
/// where its own does. Faded to the mean toward the map's edges.
inline float cloudShadowFactor(float3 worldPos, constant FrameUniforms &u, texture2d<float> map) {
    if (u.cloudShadow.x < 0.5) return 1.0;
    float h = worldPos.z + u.cloudLight.z;
    if (h >= u.cloudLight.w) return 1.0;
    float2 xy = worldPos.xy + (u.cloudShadowShift.x - h) * u.cloudShadowShift.zw;
    float2 uv = (xy - u.cloudShadow.zw) * u.cloudShadow.y + 0.5;
    float edge = smoothstep(0.0, 0.1, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
    float T = mix(u.cloudLight.y, map.sample(kLinearClamp, uv).r, edge);
    // Under a lone cumulus the shade is not dark: light scattered through and off the clouds
    // around fills about a third of it. Under a full deck that fill is the overcast's ambient,
    // so it fades out as the cover closes.
    return T + (1.0 - T) * 0.3 * (1.0 - u.cloudLight.x);
}

/// How overcast it is at a point: the sky's cloud cover for points under the lowest base.
inline float overcastAt(float3 worldPos, constant FrameUniforms &u) {
    float h = worldPos.z + u.cloudLight.z;
    return u.cloudLight.x * (1.0 - smoothstep(u.cloudShadowShift.y - 150.0, u.cloudShadowShift.y + 50.0, h));
}

/// Shadows from buildings (the world shadow map around the view): 3x3 PCF, a small normal
/// offset against acne, faded out toward the map's edges.
inline float worldShadowFactor(float3 worldPos, float3 N, constant FrameUniforms &u, depth2d<float> map) {
    if (u.worldShadowParams.x < 0.5) return 1.0;
    float4 sc = u.worldShadowViewProj * float4(worldPos + N * u.worldShadowParams.w, 1.0);
    float3 p = sc.xyz / sc.w;
    float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || p.z > 1.0 || p.z < 0.0) return 1.0;
    float edge = smoothstep(0.0, 0.08, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
    constexpr sampler cmp(filter::linear, address::clamp_to_edge, compare_func::less_equal);
    float texel = u.worldShadowParams.z;
    float sum = 0.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            sum += map.sample_compare(cmp, uv + float2(x, y) * texel, p.z - u.worldShadowParams.y);
    return mix(1.0, sum / 9.0, edge);
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
                           texture2d<float> skyView, float occlusion = 1.0)
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
    // Under cloud the sky is a grey dome lit from above: diffuse light about a third of the
    // clear day's total, without the blue.
    float overcast = overcastAt(worldPos, u);
    if (overcast > 0.0) {
        float total = dot(skyE + sun * saturate(L.z), float3(0.2126, 0.7152, 0.0722));
        skyE = mix(skyE, float3(0.93, 0.97, 1.0) * total * 0.33, overcast);
    }
    float3 groundE = 0.25 * (skyE + sun * saturate(L.z) * shadow);
    float up = N.z * 0.5 + 0.5;
    float3 ambientDiffuse = diffuseColor / kPi * (skyE * up + groundE * (1.0 - up));

    float3 R = reflect(-V, N);
    float viewHeight = kBottomRadius + max(u.atmosphere.x + u.atmosphere.y, 0.001);
    float3 skyRadiance = R.z > -0.02 ? skyView.sample(kLinearClamp, skyViewUV(R, L, viewHeight)).rgb : groundE / kPi;
    // Rough surfaces see a blurred sky: blend the mirror direction toward the mean sky radiance.
    float3 env = mix(skyRadiance, skyE / kPi, saturate(max(roughness * roughness * 1.2, overcast)));
    // Split-sum environment BRDF (Karis's analytic fit): unlike bare Fresnel it falls off with
    // roughness at grazing angles, so rough ground does not turn white toward the horizon.
    float3 ambientSpecular = env * envBRDF(f0, roughness, NdotV);

    // `occlusion`: the share of the sky a surface sees (a cabin interior sees it only through
    // the windows).
    return direct + (ambientDiffuse + ambientSpecular) * occlusion;
}

inline float3 applyAerialPerspective(float3 color, float3 worldPos, float4 screenPos,
                                     constant FrameUniforms &u, texture3d<float> aerial,
                                     const device LightingState &light)
{
    float distanceKm = length(worldPos) * 0.001;
    float w = sqrt(saturate(distanceKm / u.atmosphere.z));
    float2 uv = screenPos.xy * u.renderSize.zw;
    float4 ap = aerial.sample(kLinearClamp, float3(uv, w));
    // Fade in across the first slice so the camera's immediate surroundings stay clear.
    float fade = saturate(w * float(kAerialSize.z));
    // Haze under an overcast is lit by the grey sky, not the sun.
    float dim = 1.0 - 0.6 * u.cloudLight.x * (u.cloudLight.z < u.cloudShadowShift.y ? 1.0 : 0.0);
    color = color * mix(1.0, ap.a, fade) + ap.rgb * fade * dim;
    float dist = length(worldPos);
    float fogT = exp(-fogDepth(worldPos / max(dist, 1e-3), dist, u));
    return color * fogT + light.fogColour.rgb * (1.0 - fogT);
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
    float joint = 1.0 - smoothstep(0.015, 0.04, jointDistance(uv, slab));
    c *= 1.0 - 0.2 * joint;
    float halfLen = size.x * 0.5;
    float fromEnd = halfLen - abs(uv.x);
    float zone = smoothstep(150.0, 320.0, fromEnd) * (1.0 - smoothstep(650.0, 1000.0, fromEnd));
    float lane = 1.0 - smoothstep(3.0, 12.0, abs(uv.y));
    float streaks = fbm(uv * float2(0.05, 1.4), 3);
    float rubber = zone * lane * (0.45 + 0.55 * streaks);
    return mix(c, float3(0.05, 0.05, 0.05), saturate(rubber * 0.95));
}

/// Photographed detail (CC0, ambientCG), each channel levelled so 1 is its average: concrete
/// aggregate grain on a 1.6 m tile, the cement's mid-scale mottling on 11 m, asphalt grain on
/// 2.4 m. Mip-mapped, so it fades into the procedural tone with distance.
inline float3 groundDetail(texture2d<float> t, float2 uvMetres) {
    return float3(t.sample(kLinearRepeat, uvMetres / 1.6).r, t.sample(kLinearRepeat, uvMetres / 11.0).g,
                  t.sample(kLinearRepeat, uvMetres / 2.4).b) * 2.0;
}

/// The grain's surface relief as a normal (z up), strongest close to the eye.
inline float3 groundNormal(texture2d<float> t, float2 uvMetres, float distance) {
    float3 n = t.sample(kLinearRepeat, uvMetres / 1.6).xyz * 2.0 - 1.0;
    float k = 0.55 * saturate(1.0 - distance / 250.0);
    return normalize(float3(n.xy * k, 1.0));
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
    float joint = (1.0 - smoothstep(0.012, 0.03, jointDistance(uv, slab))) * saturate(1.0 - distance / 140.0);
    return c * (1.0 - 0.18 * joint);
}

/// Generic facades: uv.x metres along the wall, uv.y metres up. Returns albedo; sets roughness
/// and the light that windows give off at night (`glow`, scene radiance).
inline float3 facadeAlbedo(float code, float2 uv, float3 N, thread float &roughness, thread float3 &glow, float seed = 0.0) {
    glow = float3(0.0);
    if (code == 9.0) {
        // City buildings: Phoenix and Los Angeles stucco, tile and membrane roofs, small windows.
        if (N.z > 0.7) {
            roughness = 0.85;
            // White and light grey membranes (most commercial roofs), sand-coloured and
            // terracotta concrete tile, the odd dark shingle roof.
            float3 roofs[6] = { float3(0.70, 0.70, 0.68), float3(0.58, 0.57, 0.54), float3(0.62, 0.52, 0.40),
                                float3(0.52, 0.30, 0.20), float3(0.66, 0.60, 0.50), float3(0.32, 0.31, 0.30) };
            return roofs[int(seed * 5.99)] * (0.9 + 0.2 * fbm(uv * 0.3, 2));
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
    if (code == 10.0) {
        // Ground equipment: uv.y is the paint (0 white, 1 safety yellow, 2 black tyres and cab
        // glass, 3 blue tarpaulin, 4 orange, 5 grey steel), uv.x metres along for wear.
        float paint = floor(uv.y + 0.5);
        float wear = 0.9 + 0.1 * fbm(uv * float2(1.3, 1.0) + seed * 11.0, 2);
        roughness = paint == 2.0 ? 0.35 : (paint == 5.0 ? 0.5 : 0.6);
        if (paint == 1.0) return float3(0.80, 0.58, 0.05) * wear;
        if (paint == 2.0) return float3(0.025, 0.025, 0.028);
        if (paint == 3.0) return float3(0.10, 0.20, 0.42) * wear;
        if (paint == 4.0) return float3(0.85, 0.30, 0.04);
        if (paint == 5.0) return float3(0.45, 0.46, 0.47) * wear;
        return float3(0.80, 0.80, 0.78) * wear;
    }
    if (N.z > 0.7 && code != 7.0) {
        roughness = 0.9;
        return float3(0.36, 0.35, 0.33) * (0.85 + 0.3 * fbm(uv * 0.05, 3));
    }
    if (code == 7.0) {
        // Boarding bridges and floodlight masts. uv.y: the canopy's rubber (-100), painted steel
        // for columns, beams, bogie and masts (-1), roofs (-2), else metres above the floor.
        if (uv.y < -50.0) { roughness = 0.9; return float3(0.035, 0.035, 0.035); }
        if (uv.y < -1.5) { roughness = 0.7; return float3(0.48, 0.49, 0.50); }
        if (uv.y < -0.5) { roughness = 0.55; return float3(0.52, 0.53, 0.54) * (0.92 + 0.08 * fbm(uv * 3.0, 2)); }
        // Ribbed cladding (0.3 m flutes) with a glazed band from 0.9 m to 2.3 m, 1.2 m panes.
        bool window = uv.y > 0.9 && uv.y < 2.3 && fract(uv.x / 1.2) > 0.08;
        bool trim = abs(uv.y - 0.85) < 0.05 || abs(uv.y - 2.35) < 0.05;
        roughness = window ? 0.08 : 0.45;
        glow = window ? float3(1.0, 0.86, 0.62) * 1.6e-4 : float3(0.0);
        if (window) return float3(0.035, 0.045, 0.055);
        if (trim) return float3(0.30, 0.31, 0.32);
        float flute = 0.5 + 0.5 * cos(uv.x * 6.2831 / 0.3);
        return float3(0.76, 0.77, 0.78) * (0.94 + 0.06 * flute);
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
                                  texture2d<float> nightLights [[texture(5)]],
                                  depth2d<float> worldShadowMap [[texture(6)]],
                                  texture2d<float> cloudShadowMap [[texture(7)]],
                                  texture2d<float> groundDetailMap [[texture(8)]],
                                  texture2d<float> groundNormalMap [[texture(9)]])
{
    float kind = d.material.w;
    float3 N = normalize(in.normal);
    // Two-sided meshes (the aircraft) face the viewer. Everything else (terrain and its skirts,
    // buildings, roofs, signs) has authored normals used as they are: flipping by winding once
    // turned every counter-clockwise roof into a downward-facing wall full of windows.
    if (!frontFacing && kind == kKindAircraft) N = -N;
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
        // Open water (sea level, where the elevation data's ocean depths were clamped): a dark,
        // glossy surface whose wave normals reflect the sky and catch the sun. Waves fade with
        // distance into a slightly rougher surface, as they do to the eye.
        float water = saturate(in.seed * 1.6 - 0.3);
        if (water > 0.0) {
            float2 p = in.worldPos.xy + u.noiseOrigin.xy;
            float t = u.atmosphere.w;
            float amp = 0.22 * saturate(1.0 - distance / 7000.0);
            float2 g = float2(fbm(p * 0.045 + float2(t * 0.04, 0.0), 3) - fbm(p * 0.045 + float2(3.1, 1.7 - t * 0.03), 3),
                              fbm(p * 0.07 + float2(5.2, 2.3 + t * 0.025), 3) - fbm(p * 0.07 + float2(-t * 0.05, 0.0), 3));
            N = normalize(mix(N, normalize(float3(g * amp * 2.0, 1.0)), water));
            albedo = mix(albedo, float3(0.012, 0.028, 0.034) + albedo * 0.12, water);
            roughness = mix(roughness, 0.07 + 0.15 * saturate(distance / 15000.0), water);
        }
    } else if (kind == kKindRunway) {
        bool concrete = d.emissive.z > 0.5;
        albedo = concrete ? concreteRunwayAlbedo(in.uv, d.emissive.xy) : runwayAlbedo(in.uv, d.emissive.xy);
        float3 gd = groundDetail(groundDetailMap, in.uv);
        albedo *= concrete ? clamp(mix(1.0, gd.x * gd.y, 0.85), 0.5, 1.6) : clamp(gd.z, 0.6, 1.5);
        N = groundNormal(groundNormalMap, in.uv, distance);
        roughness = concrete ? 0.88 : 0.92;
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
        bool asphalt = d.emissive.x > 0.5;
        albedo = pavementAlbedo(in.uv, asphalt, distance);
        float3 gd = groundDetail(groundDetailMap, in.uv);
        albedo *= asphalt ? clamp(gd.z, 0.6, 1.5) : clamp(mix(1.0, gd.x * gd.y, 0.85), 0.5, 1.6);
        N = groundNormal(groundNormalMap, in.uv, distance);
    } else if (kind == kKindParked) {
        // Generic liveries: white fuselage with a window line and a grey belly, the fin and
        // engines in one of eight colours. No real airline's marks.
        const float3 palette[8] = { float3(0.05, 0.10, 0.35), float3(0.55, 0.05, 0.06), float3(0.10, 0.35, 0.65),
                                    float3(0.05, 0.35, 0.18), float3(0.80, 0.35, 0.05), float3(0.30, 0.10, 0.40),
                                    float3(0.05, 0.40, 0.42), float3(0.35, 0.06, 0.12) };
        float3 livery = palette[int(in.seed * 7.99)];
        float part = in.uv.x, along = in.uv.y;
        roughness = 0.35;
        if (part < 0.5) {
            albedo = float3(0.82, 0.82, 0.80);
            if (N.z < -0.35) albedo = float3(0.55, 0.56, 0.57);
            bool cabin = along > 6.0 && along < d.emissive.x * 0.78 && N.z > 0.08 && N.z < 0.32 && fract(along / 0.53) < 0.42;
            bool cockpit = along > 1.2 && along < 3.2 && N.z > 0.25 && N.z < 0.6;
            if (cabin || cockpit) { albedo = float3(0.03, 0.04, 0.05); roughness = 0.1; }
            if (cabin) windowGlow = float3(1.0, 0.85, 0.6) * 1.2e-4;
        } else if (part < 1.5) {
            albedo = float3(0.62, 0.63, 0.64);
        } else if (part < 2.5) {
            albedo = livery;
        } else if (part < 3.5) {
            albedo = mix(float3(0.7, 0.7, 0.7), livery, 0.6);
        } else {
            albedo = float3(0.80, 0.80, 0.78);
        }
    } else if (kind == kKindTree) {
        // Canopy greens from olive to deep green, mottled; brown trunks.
        if (in.uv.x > 0.5) {
            albedo = float3(0.16, 0.12, 0.08);
        } else {
            float3 a = mix(float3(0.07, 0.09, 0.04), float3(0.10, 0.13, 0.06), fract(in.seed * 13.7));
            albedo = a * (0.75 + 0.5 * fbm(in.worldPos.xy * 0.8 + in.seed * 50.0, 2));
        }
        roughness = 0.9;
    } else if (kind == kKindSign) {
        albedo = albedoTexture.sample(kLinearClamp, in.uv).rgb;
    } else if (kind == kKindBuilding) {
        albedo = facadeAlbedo(d.emissive.x, in.uv, N, roughness, windowGlow, in.seed);
    } else if (d.material.z > 0.5) {
        float4 t = albedoTexture.sample(kLinearRepeat, in.uv);
        albedo *= t.rgb;
    }

    // Rain darkens the ground and glosses pavement, most in the low spots where it pools.
    float wet = u.weather.x;
    if (wet > 0.0 && (kind == kKindRunway || kind == kKindPavement || kind == kKindMarking ||
                      kind == kKindTerrain || kind == kKindGround)) {
        bool paved = kind != kKindTerrain && kind != kKindGround;
        float pool = smoothstep(0.52, 0.7, fbm((in.worldPos.xy + u.noiseOrigin.xy) * 0.09, 3));
        albedo *= mix(1.0, paved ? 0.55 : 0.75, wet);
        if (paved) roughness = mix(roughness, mix(0.32, 0.05, pool), wet);
    }

    float shadow = min(shadowFactor(in.worldPos, u, shadowMap), worldShadowFactor(in.worldPos, N, u, worldShadowMap));
    shadow *= cloudShadowFactor(in.worldPos, u, cloudShadowMap);
    // Aircraft interiors carry their sky occlusion in emissive.w (0 means open air).
    float occlusion = (kind == kKindAircraft && d.emissive.w > 0.0) ? d.emissive.w : 1.0;
    float3 color = shadeSurface(albedo, roughness, d.material.y, N, in.worldPos, shadow, u, light, skyView, occlusion);
    // Aircraft emission (AC3D materials) lights the surface's own colour, as OpenGL's
    // modulate does, rather than adding flat white.
    color += d.emissive.rgb * albedo * (kind == kKindAircraft ? 1.0 : 0.0);
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
    color = applyAerialPerspective(color, in.worldPos, in.position, u, aerial, light);

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
    // Clear glass scatters almost nothing: what it adds is a faint tint and the reflection
    // (shadeSurface's specular). Lit as a diffuse surface, it reads as frosted plastic.
    float3 color = shadeSurface(albedo * 0.08, 0.05, 0.0, N, in.worldPos, shadow, u, light, skyView);
    color = applyAerialPerspective(color, in.worldPos, in.position, u, aerial, light);
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
                                const device LightingState &light [[buffer(3)]],
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

    // Moonlight scattered in the air: a faint deep blue, brighter toward the horizon.
    if (dir.z > -0.05) L += u.moonLight.x * 0.08 * float3(0.32, 0.48, 1.0) * (1.0 - 0.6 * saturate(dir.z));

    // The Moon: a sphere lit by the Sun, so it shows its phase; the maria darker, a little
    // earthshine on the dark side, behind the atmosphere's transmittance.
    float moonR = u.moonDirection.w;
    if (moonR > 0.0 && dot(dir, u.moonDirection.xyz) > cos(moonR * 1.05) && dir.z > -0.02) {
        float3 m = u.moonDirection.xyz;
        float3 right = normalize(cross(m, float3(0.0, 0.0, 1.0)));
        float3 upT = cross(right, m);
        float2 q = float2(dot(dir, right), dot(dir, upT)) / sin(moonR);
        float r2 = dot(q, q);
        if (r2 < 1.0) {
            float3 n = q.x * right + q.y * upT - sqrt(1.0 - r2) * m;
            float lit = saturate(dot(n, sunDir));
            float maria = 1.0 - 0.38 * smoothstep(0.42, 0.62, fbm(q * 1.9 + 7.3, 4));
            float3 T = sampleTransmittance(transmittanceLUT, viewHeight, max(dir.z, 0.0));
            float3 moon = (lit * 0.12 / kPi * maria + 0.00001) * u.sunIlluminance.rgb * T;
            L += moon * smoothstep(1.0, 0.94, sqrt(r2));
        }
    }

    // Under an overcast whatever sky shows past the clouds' reach is the deck's grey, and mist
    // hides the sky toward the horizon.
    if (u.cloudLight.z < u.cloudShadowShift.y) L = mix(L, light.fogColour.rgb, u.cloudLight.x);
    float fogT = exp(-fogDepth(dir, 1e7, u));
    L = L * fogT + light.fogColour.rgb * (1.0 - fogT);

    // Motion for a point at infinity: only camera rotation moves it.
    float4 cur = u.viewProjNoJitter * float4(dir, 0.0);
    float4 prev = u.prevViewProjNoJitter * float4(dir, 0.0);
    GBufferOut o;
    o.color = float4(L, 1.0);
    o.motion = motionVector(cur, prev, u);
    return o;
}

// MARK: - Shadow map

vertex float4 shadowParkedVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device MeshVertex *vertices [[buffer(0)]],
                                 constant FrameUniforms &u [[buffer(1)]],
                                 constant DrawUniforms &d [[buffer(2)]],
                                 const device ParkedInstance *instances [[buffer(3)]])
{
    return u.shadowViewProj * (d.model * float4(parkedPoint(vertices[vid].position.xyz, instances[iid]), 1.0));
}

vertex float4 shadowTreeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device float4 *mesh [[buffer(0)]],
                               constant FrameUniforms &u [[buffer(1)]],
                               constant DrawUniforms &d [[buffer(2)]],
                               const device TreeInstanceGPU *trees [[buffer(3)]])
{
    float3 n = mesh[vid * 2 + 1].xyz;
    return u.shadowViewProj * (d.model * float4(treePoint(mesh[vid * 2], trees[iid], n), 1.0));
}

vertex float4 shadowCompactVertex(uint vid [[vertex_id]],
                                  const device CompactVertex *vertices [[buffer(0)]],
                                  constant FrameUniforms &u [[buffer(1)]],
                                  constant DrawUniforms &d [[buffer(2)]])
{
    float4 world = d.model * float4(float3(vertices[vid].position), 1.0);
    return u.shadowViewProj * world;
}

vertex float4 shadowVertex(uint vid [[vertex_id]],
                           const device MeshVertex *vertices [[buffer(0)]],
                           constant FrameUniforms &u [[buffer(1)]],
                           constant DrawUniforms &d [[buffer(2)]])
{
    float4 world = d.model * float4(vertices[vid].position.xyz, 1.0);
    return u.shadowViewProj * world;
}
