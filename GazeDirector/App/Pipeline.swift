import AVFoundation
import QuartzCore

struct ProcessingSettings: Equatable {
    var effectEnabled = true
    var mirrored = true
    var showOverlay = true
}

struct PipelineStats: Equatable {
    var fps: Double = 0
    var processingMs: Double = 0
    var frameSize: CGSize = .zero
}

/// Runs on the camera frame queue: tracks the eyes, decides where they should look, warps, displays.
final class Pipeline: @unchecked Sendable {
    let settings = Locked(ProcessingSettings())
    var onStats: ((PipelineStats) -> Void)?

    private let display: VideoDisplay
    private var statsWindowStart = CACurrentMediaTime()
    private var statsFrames = 0
    private var statsProcessing = 0.0

    init(display: VideoDisplay) {
        self.display = display
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let start = CACurrentMediaTime()

        display.show(pixelBuffer)

        recordStats(processing: CACurrentMediaTime() - start, pixelBuffer: pixelBuffer)
    }

    private func recordStats(processing: Double, pixelBuffer: CVPixelBuffer) {
        statsFrames += 1
        statsProcessing += processing
        let now = CACurrentMediaTime()
        let elapsed = now - statsWindowStart
        guard elapsed >= 0.5 else { return }

        let stats = PipelineStats(
            fps: Double(statsFrames) / elapsed,
            processingMs: statsProcessing / Double(statsFrames) * 1000,
            frameSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        )
        statsWindowStart = now
        statsFrames = 0
        statsProcessing = 0
        onStats?(stats)
    }
}
