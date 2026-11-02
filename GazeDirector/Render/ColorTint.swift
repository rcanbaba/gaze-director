import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// Obvious colour test filter on the outgoing frames, to check that changes made in the app reach
/// FaceTime, Photo Booth, Teams or Meet live.
enum Tint: String, CaseIterable, Identifiable {
    case none
    case red
    case green

    var id: String { rawValue }
}

final class ColorTinter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    /// Returns `input` for `.none`, otherwise a tinted copy.
    func apply(_ tint: Tint, to input: CVPixelBuffer) -> CVPixelBuffer {
        guard tint != .none else { return input }
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        guard let output = makeBuffer(width: width, height: height) else { return input }

        // Keep the chosen channel, dim the other two and lift the chosen one a little.
        let filter = CIFilter.colorMatrix()
        filter.inputImage = CIImage(cvPixelBuffer: input)
        let keep = CIVector(x: 1, y: 0, z: 0, w: 0), dim = 0.45
        switch tint {
        case .red:
            filter.rVector = keep
            filter.gVector = CIVector(x: 0, y: dim, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: dim, w: 0)
            filter.biasVector = CIVector(x: 0.12, y: 0, z: 0, w: 0)
        case .green:
            filter.rVector = CIVector(x: dim, y: 0, z: 0, w: 0)
            filter.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: dim, w: 0)
            filter.biasVector = CIVector(x: 0, y: 0.12, z: 0, w: 0)
        case .none:
            break
        }
        guard let image = filter.outputImage else { return input }
        context.render(image, to: output)
        CVBufferPropagateAttachments(input, output)
        return output
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
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
