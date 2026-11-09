// Post: exposure and tone mapping at render resolution (the upscaler works on display-encoded
// values), then a final pass to the drawable.

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// AgX base curve (Troy Sobotka's AgX, minimal fit popularised by Benjamin Wrensch):
// a filmic transform that desaturates toward white in highlights instead of clipping hue.
inline float3 agxContrast(float3 x) {
    float3 x2 = x * x, x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

inline float3 agxTonemap(float3 linearColor) {
    const float3x3 inset = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                    float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                    float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    const float3x3 outset = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                     float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                     float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
    const float minEV = -12.47393, maxEV = 4.026069;
    float3 v = inset * max(linearColor, float3(1e-10));
    v = clamp(log2(v), minEV, maxEV);
    v = (v - minEV) / (maxEV - minEV);
    v = agxContrast(v);
    // A "punchy" look (as Blender's AgX offers): the base curve alone reads flat and hazy.
    v = pow(max(v, float3(0.0)), float3(1.12));
    float luma = dot(v, float3(0.2126, 0.7152, 0.0722));
    v = luma + 1.25 * (v - luma);
    v = outset * v;
    // The curve's output is display-encoded (roughly sRGB gamma); keep it encoded.
    return saturate(v);
}

fragment float4 tonemapFragment(FullscreenOut in [[stage_in]],
                                texture2d<float> hdr [[texture(0)]],
                                const device LightingState &light [[buffer(0)]])
{
    constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);
    float3 c = hdr.sample(pointSampler, in.uv).rgb * light.exposure.x;
    return float4(agxTonemap(c), 1.0);
}

/// Copies the (possibly lower-resolution) display-encoded image to the drawable. When no
/// MetalFX scaler ran, the linear sampler does the upscale.
/// Final-pass settings: rain on the windscreen (0 none ... 1 heavy, from the flight deck only),
/// seconds, airspeed in knots, and a lightning flash (0 ... 1).
struct FinalUniforms {
    float rain;
    float time;
    float airspeed;
    float flash;
};

/// One layer of drops on the windscreen: beads at rest on the glass, and at speed streaks the
/// airflow drags up the glass. Returns the refraction offset (xy) and coverage (z).
inline float3 windscreenDrops(float2 uv, float aspect, float scale, float rain, float time, float airspeed, float seed) {
    float flow = saturate(airspeed / 120.0);
    float2 p = uv * float2(aspect, 1.0) * scale;
    // At speed the drops run up and back across the glass.
    p.y += time * mix(0.05, 1.8, flow);
    float2 cell = floor(p);
    float2 f = fract(p) - 0.5;
    float h1 = fract(sin(dot(cell + seed, float2(127.1, 311.7))) * 43758.5453);
    float h2 = fract(sin(dot(cell + seed, float2(269.5, 183.3))) * 43758.5453);
    float h3 = fract(sin(dot(cell + seed, float2(419.2, 371.9))) * 43758.5453);
    // Fewer drops in light rain; each lives a while then is blown or wiped away.
    float alive = step(h3, rain * 0.85) * step(0.25, fract(time * 0.15 + h1));
    float2 centre = (float2(h1, h2) - 0.5) * 0.6;
    float2 d = f - centre;
    d.y *= mix(1.0, 0.25, flow);                       // stretched into streaks at speed
    float r = mix(0.08, 0.2, h2);
    float drop = smoothstep(r, r * 0.55, length(d)) * alive;
    return float3(-d * drop * 0.035 / scale * 9.0, drop);
}

fragment float4 finalFragment(FullscreenOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                              depth2d<float> depth [[texture(1)]], constant FinalUniforms &fu [[buffer(0)]]) {
    // Contrast-adaptive sharpening (after AMD's CAS): restores the edge crispness upscaling
    // and temporal anti-aliasing soften, less where the neighbourhood already has contrast.
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float3 c = source.sample(kLinearClamp, in.uv).rgb;
    float3 n = source.sample(kLinearClamp, in.uv + float2(0, -texel.y)).rgb;
    float3 sth = source.sample(kLinearClamp, in.uv + float2(0, texel.y)).rgb;
    float3 w = source.sample(kLinearClamp, in.uv + float2(-texel.x, 0)).rgb;
    float3 e = source.sample(kLinearClamp, in.uv + float2(texel.x, 0)).rgb;
    float3 mn = min(c, min(min(n, sth), min(w, e))), mx = max(c, max(max(n, sth), max(w, e)));
    float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
    // Full strength up close (the deck, aircraft, the airport); a quarter beyond 8 km, where
    // sharpening would mostly amplify terrain detail changing level (measured: LOD pops 2.6 to
    // 4.0 of 255 at cruise with full strength everywhere). Reverse-Z depth, near plane 0.1 m.
    uint2 dp = uint2(in.uv * float2(depth.get_width(), depth.get_height()));
    float z = depth.read(min(dp, uint2(depth.get_width() - 1, depth.get_height() - 1)));
    float dist = 0.1 / max(z, 1e-7);
    // The sky (nothing drawn, depth 0) keeps full strength: it has no levels to pop, and the
    // stars want the crispness.
    float3 wgt = -amp * 0.16 * (z <= 0.0 ? 1.0 : 1.0 - 0.75 * smoothstep(1500.0, 8000.0, dist));
    float3 sharp = (c + (n + sth + w + e) * wgt) / (1.0 + 4.0 * wgt);
    float3 outColor = saturate(sharp);
    // Rain on the windscreen: only where the view passes through the glass (beyond the deck).
    if (fu.rain > 0.0 && dist > 4.0) {
        float aspect = float(source.get_width()) / float(source.get_height());
        float3 a = windscreenDrops(in.uv, aspect, 9.0, fu.rain, fu.time, fu.airspeed, 0.0);
        float3 b = windscreenDrops(in.uv, aspect, 17.0, fu.rain, fu.time * 1.3, fu.airspeed, 7.0);
        float cover = saturate(a.z + b.z);
        if (cover > 0.0) {
            // Each drop is a tiny lens: it shows the world from a little away, flipped and soft,
            // with a darker rim.
            float3 refracted = source.sample(kLinearClamp, in.uv + a.xy + b.xy).rgb;
            float rim = smoothstep(0.2, 0.9, cover) * (1.0 - smoothstep(0.9, 1.0, cover));
            outColor = mix(outColor, refracted * (1.0 - 0.25 * rim) + 0.04, cover * 0.85);
        }
    }
    // Lightning: the whole view washed toward white for a moment.
    outColor += fu.flash * (1.0 - outColor) * 0.55;
    return float4(outColor, 1.0);
}
