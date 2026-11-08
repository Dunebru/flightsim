// The GPU's sizes of the structs shared with Swift, for the layout test.
kernel void structSizes(device uint *out [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    out[0] = sizeof(FrameUniforms);
    out[1] = sizeof(DrawUniforms);
    out[2] = sizeof(CloudUniforms);
    out[3] = sizeof(LightingState);
    out[4] = sizeof(PrecipUniforms);
    out[5] = sizeof(GPULight);
    out[6] = sizeof(LightUniforms);
    out[7] = sizeof(StarGPU);
    out[8] = sizeof(StarUniforms);
}
