// The stars: the catalogue's J2000 directions turned to the local sky for the place and time,
// drawn as sprites at infinity behind everything (depth 0 only). Brightness is physical, from the
// visual magnitude (E = 10^(-0.4 (m + 14.18)) lux) through the atmosphere's transmittance, scaled
// up as a dark-adapted eye is more sensitive than the renderer's capped night exposure; colour
// from B-V. They twinkle near the horizon, where the air path is long.

struct StarGPU {
    float4 dirMag;      // xyz: J2000 equatorial unit vector, w: visual magnitude
    float4 colour;      // rgb, normalised
};

struct StarUniforms {
    float4x4 rotation;  // equatorial to the local (world) frame
    float4 params;      // x: time (s), y: angle per pixel (rad), z: core radius (px), w: perceptual boost
};

vertex LightOut starVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device StarGPU *stars [[buffer(0)]],
                           constant FrameUniforms &u [[buffer(1)]],
                           constant StarUniforms &s [[buffer(2)]],
                           texture2d<float> transmittanceLUT [[texture(0)]])
{
    StarGPU st = stars[iid];
    float3 dir = normalize((s.rotation * float4(st.dirMag.xyz, 0.0)).xyz);
    LightOut o;
    o.offset = 0.0;
    o.radiance = 0.0;
    if (dir.z < -0.02) { o.position = float4(0, 0, -2, 1); return o; }
    float viewHeight = kBottomRadius + max(u.atmosphere.x + u.atmosphere.y, 0.001);
    float3 T = sampleTransmittance(transmittanceLUT, viewHeight, dir.z);
    float fogT = exp(-fogDepth(dir, 1e7, u));
    float lux = pow(10.0, -0.4 * (st.dirMag.w + 14.18));
    float twinkle = 1.0 + 0.4 * pow(1.0 - saturate(dir.z), 3.0)
        * sin(s.params.x * 11.0 + float(iid) * 1.7) * sin(s.params.x * 6.3 + float(iid) * 0.37);
    // Bright stars spread wider, as the eye's own glare makes them look bigger.
    float r = s.params.z * (1.0 + 0.9 * saturate((2.5 - st.dirMag.w) / 4.0));
    float pixelSolidAngle = s.params.y * s.params.y;
    o.radiance = st.colour.rgb * T * fogT * (lux * kLuxToScene * s.params.w * twinkle) / (pixelSolidAngle * r * r * 1.5708);
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 corner = corners[vid] * 2.5;
    o.offset = corner;
    float4 clip = u.viewProj * float4(dir, 0.0);
    o.position = clip;
    o.position.xy += corner * r * (2.0 / u.renderSize.xy) * clip.w;
    if (clip.w <= 0.0) o.position = float4(0, 0, -2, 1);
    return o;
}
