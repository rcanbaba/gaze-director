import AVFoundation
import CoreImage
import GazeCore

/// Writes a short movie with the eyes stacked, original on top and corrected below, so the effect
/// can be judged afterwards. Looking at the live preview while reading would take the gaze out of the
/// reading zone and switch the correction off.
final class ClipRecorder {
    static var folderURL: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GazeDirector", isDirectory: true)
    }

    let duration: Double
    let url: URL

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// Size of each of the two stacked panels.
    private let panel: CGSize
    /// Fixed at the start so the framing does not wobble with tracking noise.
    private let region: CGRect
    private var startTime: Double?
    private(set) var finished = false

    /// Frames a band around both eyes, from the first frame's eye positions.
    init?(eyes: [EyeMeasurement], frameSize: CGSize, duration: Double = 15) {
        guard eyes.count == 2 else { return nil }
        let a = eyes[0].frame.center, b = eyes[1].frame.center
        let span = (b - a).length * 2.6
        let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let size = CGSize(width: span, height: span * 0.36)
        region = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            .intersection(CGRect(origin: .zero, size: frameSize)).integral
        panel = CGSize(width: 1280, height: (1280 * region.height / region.width / 2).rounded(.down) * 2)

        try? FileManager.default.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        url = Self.folderURL.appendingPathComponent("gaze-\(stamp).mov")
        self.duration = duration

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(panel.width),
            AVVideoHeightKey: Int(panel.height * 2),
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(panel.width),
            kCVPixelBufferHeightKey as String: Int(panel.height * 2),
        ])
        self.writer = writer
        self.input = input
    }

    func progress(at time: Double) -> Double {
        startTime.map { min(1, (time - $0) / duration) } ?? 0
    }

    /// Appends one frame. `correcting` lights a green marker on the corrected panel.
    func append(original: CVPixelBuffer, corrected: CVPixelBuffer, correcting: Bool, time: Double, completion: @escaping (URL?) -> Void) {
        guard !finished else { return }
        if startTime == nil {
            guard writer.startWriting() else {
                finished = true
                completion(nil)
                return
            }
            writer.startSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
            startTime = time
        }
        if time - startTime! >= duration {
            finished = true
            input.markAsFinished()
            writer.finishWriting { [writer, url] in
                completion(writer.status == .completed ? url : nil)
            }
            return
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }

        let scale = panel.width / region.width
        func side(_ pixelBuffer: CVPixelBuffer, y: CGFloat) -> CIImage {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            // Core Image has a bottom-left origin.
            let flipped = CGRect(x: region.minX, y: image.extent.height - region.maxY, width: region.width, height: region.height)
            return image.cropped(to: flipped)
                .transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: 0, y: y))
        }
        let marker = CIImage(color: correcting ? CIColor(red: 0.2, green: 0.9, blue: 0.3) : CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: panel.width - 34, y: panel.height - 34, width: 22, height: 22))
        // Core Image's y axis points up: the corrected panel at the bottom, the original above it.
        let composed = marker
            .composited(over: side(corrected, y: 0))
            .composited(over: side(original, y: panel.height))
        context.render(composed, to: buffer)
        adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
    }
}
