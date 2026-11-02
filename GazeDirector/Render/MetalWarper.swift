import CoreVideo
import GazeCore
import Metal

/// GPU layout of one eye's warp. Must match `struct EyeWarp` in EyeWarp.metal.
struct EyeWarpGPU {
    var iris: SIMD2<Float>
    var displacement: SIMD2<Float>
    var center: SIMD2<Float>
    var axis: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var irisRadius: Float
    var padding: Float = 0

    init(_ warp: EyeWarp) {
        iris = SIMD2<Float>(warp.iris)
        displacement = SIMD2<Float>(warp.displacement)
        center = SIMD2<Float>(warp.center)
        axis = SIMD2<Float>(warp.axis)
        halfSize = SIMD2<Float>(warp.halfSize)
        irisRadius = Float(warp.irisRadius)
    }
}

/// Applies the eye warp on the GPU. BGRA in, BGRA out, no CPU copies: both buffers are IOSurfaces
/// wrapped as Metal textures.
final class MetalWarper {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    /// Pass a library to use a shader compiled elsewhere (the preview tool compiles it from source).
    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), library: MTLLibrary? = nil) {
        guard let device,
              let queue = device.makeCommandQueue(),
              let library = library ?? device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "warpEyes"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Returns `input` untouched when there is nothing to warp, otherwise a new buffer from the pool.
    func warp(_ input: CVPixelBuffer, eyes: [EyeWarp]) -> CVPixelBuffer? {
        guard !eyes.isEmpty else { return input }
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        guard let output = makeOutputBuffer(width: width, height: height),
              let source = texture(for: input),
              let destination = texture(for: output),
              let sourceTexture = CVMetalTextureGetTexture(source),
              let destinationTexture = CVMetalTextureGetTexture(destination),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return nil }

        var gpuEyes = eyes.map(EyeWarpGPU.init)
        var count = UInt32(gpuEyes.count)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        encoder.setBytes(&gpuEyes, length: MemoryLayout<EyeWarpGPU>.stride * gpuEyes.count, index: 0)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        CVBufferPropagateAttachments(input, output)
        return output
    }

    private func texture(for pixelBuffer: CVPixelBuffer) -> CVMetalTexture? {
        guard let textureCache else { return nil }
        let attributes = [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, attributes, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &texture
        )
        return texture
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
