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
fragment float4 finalFragment(FullscreenOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
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
    float3 wgt = -amp * 0.16;
    float3 sharp = (c + (n + sth + w + e) * wgt) / (1.0 + 4.0 * wgt);
    return float4(saturate(sharp), 1.0);
}
