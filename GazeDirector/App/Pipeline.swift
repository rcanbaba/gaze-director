import AVFoundation
import GazeCore
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

/// Per-frame tracking state for the debug overlay, in image pixels (top-left origin).
struct DebugFrame {
    struct Eye {
        var contour: [CGPoint]
        var iris: CGPoint
        var visionPupil: CGPoint?
        var refined: Bool
        var blinking: Bool
    }

    var imageSize: CGSize = .zero
    var eyes: [Eye] = []
}

/// Runs on the camera frame queue: tracks the eyes, decides where they should look, warps, displays.
final class Pipeline: @unchecked Sendable {
    let settings = Locked(ProcessingSettings())
    var onStats: ((PipelineStats) -> Void)?
    var onDebug: ((DebugFrame) -> Void)?

    private let display: VideoDisplay
    private let faceTracker = FaceTracker()
    private var eyeTrackers = [EyeTracker(), EyeTracker()]

    private var statsWindowStart = CACurrentMediaTime()
    private var statsFrames = 0
    private var statsProcessing = 0.0

    init(display: VideoDisplay) {
        self.display = display
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let start = CACurrentMediaTime()
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        let eyes = measureEyes(in: pixelBuffer, time: time)

        display.show(pixelBuffer)

        if settings.get().showOverlay {
            onDebug?(debugFrame(for: pixelBuffer, eyes: eyes))
        }
        recordStats(processing: CACurrentMediaTime() - start, pixelBuffer: pixelBuffer)
    }

    /// Returns both eyes, or an empty array when the face or either eye is lost.
    private func measureEyes(in pixelBuffer: CVPixelBuffer, time: Double) -> [EyeMeasurement] {
        guard let face = faceTracker.detect(in: pixelBuffer) else {
            eyeTrackers.indices.forEach { eyeTrackers[$0].reset() }
            return []
        }
        let eyes = LumaSampler.withSampler(pixelBuffer) { luma in
            (0..<2).compactMap { i in
                eyeTrackers[i].update(contour: face.eyes[i].contour, pupil: face.eyes[i].pupil, time: time) { luma($0) }
            }
        } ?? []
        return eyes.count == 2 ? eyes : []
    }

    private func debugFrame(for pixelBuffer: CVPixelBuffer, eyes: [EyeMeasurement]) -> DebugFrame {
        func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
        return DebugFrame(
            imageSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
            eyes: eyes.map { eye in
                DebugFrame.Eye(
                    contour: eye.frame.contour.map(cg),
                    iris: cg(eye.frame.point(at: eye.irisUV)),
                    visionPupil: eye.visionPupilUV.map { cg(eye.frame.point(at: $0)) },
                    refined: eye.refined,
                    blinking: eye.isBlinking
                )
            }
        )
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
