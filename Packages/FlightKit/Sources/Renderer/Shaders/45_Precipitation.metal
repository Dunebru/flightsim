// Falling rain and snow: drops in a box around the camera that wraps as the camera moves, so they
// stay put in the world and fall through it. Each drop is a streak along its motion relative to
// the camera over the frame (at 140 kt rain sweeps nearly level past the windscreen), at least a
// pixel wide with its brightness spread to match. Lit by the light falling on mist (white, from
// the sky and sun), depth-tested against the scene, blended over it.

struct PrecipUniforms {
    float4 box;      // xyz: box size (m), w: drop count
    float4 offset;   // xyz: camera position plus fall, modulo the box (m); w: 0 rain, 1 snow
    float4 streak;   // xyz: drop motion relative to the camera over the exposure (m); w: drop radius (m)
    float4 look;     // x: opacity, y: pixel angle (rad), z: time (s)
};

struct PrecipOut {
    float4 position [[position]];
    float2 uv;       // x: -1..1 across the streak, y: 0..1 along it
    float alpha;
    float shade;     // brightness relative to mist
};

vertex PrecipOut precipVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant FrameUniforms &u [[buffer(1)]],
                              constant PrecipUniforms &p [[buffer(2)]])
{
    float3 r = cloudHash(float3(float(iid) * 0.618, float(iid) * 0.371 + 3.1, 7.7));
    float3 box = p.box.xyz;
    float3 pos = (fract(r - p.offset.xyz / box) - 0.5) * box;
    bool snow = p.offset.w > 0.5;
    if (snow) {
        // Flakes drift and wander.
        float t = p.look.z;
        pos.xy += sin(t * (0.6 + r.yz * 0.8) + r.zx * 6.2832) * 0.35;
    }
    float dist = length(pos);
    float3 motion = p.streak.xyz;
    float3 a = pos, b = pos - motion;
    float3 axis = b - a;
    float len = length(axis);
    float3 toCamera = -pos / max(dist, 1e-3);
    float3 along = len > 1e-4 ? axis / len : float3(0.0, 0.0, 1.0);
    float3 side = cross(along, toCamera);
    side = length(side) > 1e-4 ? normalize(side) : float3(1.0, 0.0, 0.0);
    // At least about a pixel wide; a drop drawn wider than it is gets fainter to match.
    float radius = p.streak.w;
    float drawn = max(radius, dist * p.look.y * 0.7);
    // Snowflakes and short streaks are drawn at least as long as they are wide.
    float extend = max(drawn - len * 0.5, 0.0);

    const float2 corners[6] = { float2(-1, 0), float2(1, 0), float2(-1, 1), float2(1, 0), float2(1, 1), float2(-1, 1) };
    float2 c = corners[vid];
    float3 world = mix(a - along * extend, b + along * extend, c.y) + side * drawn * c.x;

    PrecipOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.uv = c;
    // Seen from below, drops and flakes show their shaded undersides against the bright sky; seen
    // level or from above they catch the sky's light. Rain also refracts the sky, so it stays lighter.
    float up = saturate(-toCamera.z);
    o.shade = snow ? mix(1.7, 0.45, up) : mix(1.6, 0.8, up);
    float3 edge = abs(pos) / (box * 0.5);
    float fade = (1.0 - smoothstep(0.6, 1.0, max(max(edge.x, edge.y), edge.z))) * smoothstep(0.3, 1.2, dist);
    // Fainter when drawn wider than the drop is, and when smeared into a long streak. (Rain is
    // exaggerated here, as every film and game does: a real drop crosses a pixel too fast to see.)
    o.alpha = fade * sqrt(radius / drawn) * clamp(sqrt(0.3 / max(len, 0.05)), 0.3, 1.5);
    return o;
}

fragment GBufferOut precipFragment(PrecipOut in [[stage_in]],
                                   constant PrecipUniforms &p [[buffer(2)]],
                                   const device LightingState &light [[buffer(3)]])
{
    float across = 1.0 - in.uv.x * in.uv.x;
    float a = saturate(in.alpha * across * p.look.x);
    // Drops catch the light of the sky around them, like mist does.
    // Drops act as tiny lenses showing the bright sky above, so they read lighter than the mist.
    float3 radiance = light.fogColour.rgb * in.shade;
    GBufferOut o;
    o.color = float4(radiance * a, a);
    o.motion = float2(0.0);
    return o;
}
