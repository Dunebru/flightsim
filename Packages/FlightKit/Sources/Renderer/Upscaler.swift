import Metal
#if canImport(MetalFX)
import MetalFX
#endif

/// MetalFX scalers, created for a given input and output size. Falls back to nothing (the
/// final pass upsamples bilinearly) where MetalFX is not supported, such as the iOS Simulator.
final class Upscaler {
    let mode: UpscalerMode
    let inputSize: SIMD2<Int>
    let outputSize: SIMD2<Int>
    #if canImport(MetalFX)
    private var temporal: (any MTLFXTemporalScaler)?
    private var spatial: (any MTLFXSpatialScaler)?
    #endif
    let output: (any MTLTexture)?

    static let colorFormat: MTLPixelFormat = .rgba16Float
    static let outputFormat: MTLPixelFormat = .rgba16Float

    static func supports(_ mode: UpscalerMode, device: any MTLDevice) -> Bool {
        #if canImport(MetalFX)
        switch mode {
        case .temporal: MTLFXTemporalScalerDescriptor.supportsDevice(device)
        case .spatial: MTLFXSpatialScalerDescriptor.supportsDevice(device)
        case .off: true
        }
        #else
        // The iOS Simulator SDK ships no MetalFX.
        return mode == .off
        #endif
    }

    init(requested: UpscalerMode, device: any MTLDevice, input: SIMD2<Int>, output outSize: SIMD2<Int>,
         depthFormat: MTLPixelFormat, motionFormat: MTLPixelFormat) {
        inputSize = input
        outputSize = outSize
        var resolved: UpscalerMode = Upscaler.supports(requested, device: device) ? requested : .off
        if resolved != .off {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Upscaler.outputFormat, width: outSize.x,
                                                                height: outSize.y, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            desc.storageMode = .private
            output = device.makeTexture(descriptor: desc)
        } else {
            output = nil
        }
        #if canImport(MetalFX)
        switch resolved {
        case .temporal:
            let d = MTLFXTemporalScalerDescriptor()
            d.colorTextureFormat = Upscaler.colorFormat
            d.depthTextureFormat = depthFormat
            d.motionTextureFormat = motionFormat
            d.outputTextureFormat = Upscaler.outputFormat
            d.inputWidth = input.x
            d.inputHeight = input.y
            d.outputWidth = outSize.x
            d.outputHeight = outSize.y
            d.isAutoExposureEnabled = false
            temporal = d.makeTemporalScaler(device: device)
            if temporal == nil { resolved = .off }
        case .spatial:
            let d = MTLFXSpatialScalerDescriptor()
            d.colorTextureFormat = Upscaler.colorFormat
            d.outputTextureFormat = Upscaler.outputFormat
            d.inputWidth = input.x
            d.inputHeight = input.y
            d.outputWidth = outSize.x
            d.outputHeight = outSize.y
            d.colorProcessingMode = .perceptual
            spatial = d.makeSpatialScaler(device: device)
            if spatial == nil { resolved = .off }
        case .off:
            break
        }
        #endif
        mode = resolved
    }

    /// Encodes the upscale. Returns the texture the final pass should present.
    func encode(commandBuffer: any MTLCommandBuffer, color: any MTLTexture, depth: any MTLTexture,
                motion: any MTLTexture, jitter: SIMD2<Float>, reset: Bool) -> any MTLTexture {
        guard let output else { return color }
        #if canImport(MetalFX)
        if let temporal {
            temporal.colorTexture = color
            temporal.depthTexture = depth
            temporal.motionTexture = motion
            temporal.outputTexture = output
            // MetalFX takes the jitter that was applied, in input pixels.
            temporal.jitterOffsetX = jitter.x
            temporal.jitterOffsetY = jitter.y
            temporal.motionVectorScaleX = 1
            temporal.motionVectorScaleY = 1
            temporal.isDepthReversed = true
            temporal.reset = reset
            temporal.encode(commandBuffer: commandBuffer)
            return output
        }
        if let spatial {
            spatial.colorTexture = color
            spatial.outputTexture = output
            spatial.encode(commandBuffer: commandBuffer)
            return output
        }
        #endif
        return color
    }
}
