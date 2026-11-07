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

struct VertexOut {
    float4 position [[position]];
    float3 worldPos;        // camera-relative, metres
    float3 normal;
    float2 uv;
    float4 currentClip;     // unjittered
    float4 previousClip;
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
    VertexOut o;
    o.position = u.viewProj * world;
    o.worldPos = world.xyz;
    o.normal = normalize((d.model * float4(v.normal.xyz, 0.0)).xyz);
    o.uv = v.uv;
    o.currentClip = u.viewProjNoJitter * world;
    o.previousClip = u.prevViewProjNoJitter * prevWorld;
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
    float3 Fr = fresnelSchlick(NdotV, f0);
    float gloss = (1.0 - roughness) * (1.0 - roughness);
    float3 ambientSpecular = skyRadiance * Fr * gloss;
    // Rough surfaces still pick up some diffuse sky through the specular lobe.
    ambientSpecular += (skyE / kPi) * Fr * (1.0 - gloss) * 0.5;

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

fragment GBufferOut sceneFragment(VertexOut in [[stage_in]],
                                  bool frontFacing [[front_facing]],
                                  constant FrameUniforms &u [[buffer(1)]],
                                  constant DrawUniforms &d [[buffer(2)]],
                                  const device LightingState &light [[buffer(3)]],
                                  texture2d<float> albedoTexture [[texture(0)]],
                                  texture2d<float> skyView [[texture(1)]],
                                  texture3d<float> aerial [[texture(2)]],
                                  depth2d<float> shadowMap [[texture(3)]])
{
    float kind = d.material.w;
    float3 N = normalize(in.normal);
    if (!frontFacing) N = -N;
    float roughness = d.material.x;
    float3 albedo = d.baseColor.rgb;
    float distance = length(in.worldPos);

    if (kind == kKindGround) {
        albedo = groundAlbedo(in.worldPos.xy + u.noiseOrigin.xy, distance);
        N = float3(0, 0, 1);
    } else if (kind == kKindRunway) {
        albedo = runwayAlbedo(in.uv, d.emissive.xy);
        N = float3(0, 0, 1);
    } else if (kind == kKindMarking) {
        float mask = albedoTexture.sample(kLinearRepeat, in.uv).r;
        if (mask < 0.5) discard_fragment();
        albedo = float3(0.78, 0.78, 0.76);
        N = float3(0, 0, 1);
    } else if (d.material.z > 0.5) {
        float4 t = albedoTexture.sample(kLinearRepeat, in.uv);
        albedo *= t.rgb;
    }

    float shadow = shadowFactor(in.worldPos, u, shadowMap);
    float3 color = shadeSurface(albedo, roughness, d.material.y, N, in.worldPos, shadow, u, light, skyView);
    color += d.emissive.rgb * (kind == kKindAircraft ? 1.0 : 0.0);
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
