import CoreImage
import CoreVideo
import GazeCore
import ImageIO
import UniformTypeIdentifiers

/// Turns pixel buffers (or parts of them) into CGImages on the GPU, for the eye zoom and diagnostics.
final class FrameExporter {
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// `rect` is in pixels with a top-left origin, like the rest of the pipeline.
    func image(of pixelBuffer: CVPixelBuffer, rect: CGRect? = nil) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let full = image.extent
        guard let rect else { return context.createCGImage(image, from: full) }
        // Core Image puts the origin at the bottom left.
        let flipped = CGRect(x: rect.minX, y: full.height - rect.maxY, width: rect.width, height: rect.height)
        let clipped = flipped.intersection(full)
        guard !clipped.isEmpty else { return nil }
        return context.createCGImage(image, from: clipped)
    }

    /// Square-ish region around an eye, sized from its width.
    static func eyeRegion(_ eye: EyeFrame) -> CGRect {
        let w = eye.width * 2.2, h = eye.width * 1.2
        return CGRect(x: eye.center.x - w / 2, y: eye.center.y - h / 2, width: w, height: h).integral
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
