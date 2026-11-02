import CoreVideo
import GazeCore

/// Bilinear brightness lookups into a locked BGRA pixel buffer. Positions are in pixels with
/// pixel centres at +0.5, the same convention Vision and the Metal shader use.
struct LumaSampler {
    private let base: UnsafePointer<UInt8>
    private let bytesPerRow: Int
    private let width: Int
    private let height: Int

    /// Locks `pixelBuffer` for reading for the duration of `body`.
    static func withSampler<R>(_ pixelBuffer: CVPixelBuffer, _ body: (LumaSampler) -> R) -> R? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sampler = LumaSampler(
            base: base.assumingMemoryBound(to: UInt8.self),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        return body(sampler)
    }

    func callAsFunction(_ p: Vec2) -> Float {
        let x = min(max(p.x - 0.5, 0), Double(width - 1))
        let y = min(max(p.y - 0.5, 0), Double(height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        let top = luma(x0, y0) * (1 - fx) + luma(x1, y0) * fx
        let bottom = luma(x0, y1) * (1 - fx) + luma(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    private func luma(_ x: Int, _ y: Int) -> Float {
        let o = y * bytesPerRow + x * 4
        return (0.114 * Float(base[o]) + 0.587 * Float(base[o + 1]) + 0.299 * Float(base[o + 2])) / 255
    }
}
