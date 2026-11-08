// Airport lights: instanced sprites, additive over the lit scene, depth-tested against it.
// Each light's energy is physical: its intensity (candela) through its beam pattern, over the
// distance squared, gives the illuminance at the camera; spread over a few pixels that becomes
// radiance in the same units as the sky (the sun is 1 unit, about 120,000 lux). So lights are
// faint by day and dominant at night without any special casing.

struct GPULight {
    float4 position;    // xyz airport frame; w: candela
    float4 colour;      // rgb; w: behaviour (0 steady, 1 flashing, 2 PAPI)
    float4 direction;   // xyz beam axis (zero: omnidirectional); w: cos of the beam half-width
    float4 params;      // flashing: x per second, y phase, z duty; PAPI: x angle (radians)
};

struct LightUniforms {
    float4x4 model;     // airport frame to camera-relative world
    float4 up;          // airport up in the world
    float4 params;      // x: time (s), y: angle per pixel (rad), z: core radius (px)
};

constant float kLuxToScene = 1.0 / 120000.0;

struct LightOut {
    float4 position [[position]];
    float2 offset;      // in core radii
    float3 radiance;
};

vertex LightOut lightVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device GPULight *lights [[buffer(0)]],
                            constant FrameUniforms &u [[buffer(1)]],
                            constant LightUniforms &l [[buffer(2)]],
                            texture3d<float> aerial [[texture(0)]])
{
    GPULight light = lights[iid];
    LightOut o;
    float4 world = l.model * float4(light.position.xyz, 1.0);
    float dist = length(world.xyz);
    float3 toCamera = -world.xyz / max(dist, 1e-3);

    float factor = 1.0;
    float3 axis = light.direction.xyz;
    if (dot(axis, axis) > 0.5) {
        float3 w = normalize((l.model * float4(axis, 0.0)).xyz);
        float c = dot(w, toCamera);
        float cosHalf = light.direction.w;
        factor = smoothstep(cosHalf - 0.12, cosHalf + 0.02, c);
    }
    float3 colour = light.colour.rgb;
    float behaviour = light.colour.w;
    float elevation = asin(clamp(dot(toCamera, l.up.xyz), -1.0, 1.0));
    if (behaviour == 1.0) {
        float phase = fract(l.params.x * light.params.x + light.params.y);
        factor *= phase < light.params.z ? 1.0 : 0.0;
    } else if (behaviour == 2.0) {
        // PAPI: white above the unit's angle, red below, with a 3 arc-minute transition.
        float t = smoothstep(light.params.x - 0.0009, light.params.x + 0.0009, elevation);
        colour = mix(float3(1.0, 0.1, 0.06), float3(1.0, 0.95, 0.85), t);
    }
    // Fixtures are never seen from below their own ground.
    factor *= smoothstep(-0.01, 0.01, elevation);

    // Illuminance at the camera, through the atmosphere.
    float illuminance = light.position.w * factor / max(dist * dist, 1.0) * kLuxToScene;
    float4 clip = u.viewProj * float4(world.xyz * (1.0 - min(1.5 / max(dist, 1.5), 0.5)), 1.0);
    float2 ndc = clip.xy / clip.w;
    float2 screenUV = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    float slice = sqrt(saturate(dist * 0.001 / u.atmosphere.z));
    float transmittance = aerial.sample(kLinearClamp, float3(screenUV, slice), level(0.0)).a;
    // Spread over a Gaussian core of radius r pixels: integral of exp(-2 d^2) is pi / 2.
    float r = l.params.z;
    float pixelSolidAngle = l.params.y * l.params.y;
    o.radiance = colour * illuminance * transmittance / (pixelSolidAngle * r * r * 1.5708);

    // Quad corners: the core plus a faint wide glare lobe.
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 corner = corners[vid] * 4.0;
    o.offset = corner;
    float2 pixel = 2.0 / u.renderSize.xy;
    o.position = clip;
    o.position.xy += corner * r * pixel * clip.w;
    if (illuminance <= 0.0 || clip.w <= 0.0) o.position = float4(0, 0, -2, 1);   // culled
    return o;
}

fragment GBufferOut lightFragment(LightOut in [[stage_in]]) {
    float d2 = dot(in.offset, in.offset);
    float profile = exp(-2.0 * d2) + 0.015 / pow(1.0 + d2, 1.5);
    GBufferOut o;
    o.color = float4(in.radiance * profile, 0.0);
    o.motion = float2(0.0);
    return o;
}
