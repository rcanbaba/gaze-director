import AVFoundation
import GazeCore
import QuartzCore

enum TalkMode: String, CaseIterable, Identifiable {
    case speaking
    case listening
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speaking: "I'm talking"
        case .listening: "I'm listening"
        case .microphone: "Detect with microphone"
        }
    }
}

struct ProcessingSettings: Equatable {
    var effectEnabled = true
    var mirrored = true
    var showOverlay = true
    var eyeZoom = true
    /// Save raw frames and measurements during calibration (locally) for offline analysis.
    var saveDiagnostics = true
    var talkMode = TalkMode.speaking
    /// Changing it invalidates the calibration, which was measured with the other source.
    var irisSource = IrisSource.vision
    var glancesEnabled = true
    /// Largest iris move in uv (fraction of eye width). Bigger moves look less natural.
    var maxCorrection = 0.16
    /// 0 corrects by the fixed calibrated reading offset (steady); 1 follows the measured iris
    /// every frame (cancels the reading sweep but jitters).
    var followReading = 0.0
}

struct PipelineStats: Equatable {
    var fps: Double = 0
    var processingMs: Double = 0
    var frameSize: CGSize = .zero
}

/// Per-frame state for the debug overlay and gaze map. Image positions are pixels, top-left origin.
struct DebugFrame {
    struct Eye {
        var contour: [CGPoint]
        var iris: CGPoint
        var visionPupil: CGPoint?
        var gradient: CGPoint?
        var target: CGPoint?
        var blinking: Bool
    }

    var imageSize: CGSize = .zero
    var eyes: [Eye] = []
    var gazeOffset: Vec2?
    var smoothedGaze: Vec2?
    var target: Vec2?
    var readingZone: GazeRect?
    var readingCenter: Vec2?
    var state = DirectorState.noFace
    var weight = 0.0
    var nextGlanceIn: Double?
    var isSpeaking = false
}

struct CalibrationProgress: Equatable {
    var step: CalibrationRecorder.Step
    var progress: Double
}

/// Runs on the camera frame queue: tracks the eyes, decides where they should look, warps, displays.
final class Pipeline: @unchecked Sendable {
    let settings = Locked(ProcessingSettings())
    let calibration = Locked<Calibration?>(nil)
    let pendingCalibration = Locked<CalibrationRecorder.Step?>(nil)
    var isSpeaking: () -> Bool = { false }

    var onStats: ((PipelineStats) -> Void)?
    var onDebug: ((DebugFrame) -> Void)?
    var onEyeZoom: ((EyeZoom) -> Void)?
    var onCalibrationProgress: ((CalibrationProgress?) -> Void)?
    var onCalibrationFinished: ((CalibrationRecorder.Step, Calibration?) -> Void)?

    private let display: VideoDisplay
    private let warper = MetalWarper()
    private let exporter = FrameExporter()
    private lazy var diagnostics = DiagnosticsRecorder(exporter: exporter)
    private let faceTracker = FaceTracker()
    private var eyeTrackers = [EyeTracker(), EyeTracker()]
    private var director = GazeDirector()
    private var recorder: CalibrationRecorder?
    private var frameCount = 0

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
        let settings = settings.get()
        let calibration = calibration.get()

        let blinkThreshold = calibration?.blinkThreshold ?? 0.17
        for i in eyeTrackers.indices {
            eyeTrackers[i].blinkThreshold = blinkThreshold
            eyeTrackers[i].source = settings.irisSource
        }
        let (eyes, yaw) = measureEyes(in: pixelBuffer, time: time)

        record(eyes, from: pixelBuffer, at: time, calibration: calibration, saveDiagnostics: settings.saveDiagnostics)

        director.readingZone = calibration?.readingZone
        director.readingCenter = calibration?.readingCenter
        director.config.glancesEnabled = settings.glancesEnabled
        let speaking = settings.talkMode == .microphone ? isSpeaking() : settings.talkMode == .speaking
        let gazeOffset = calibration.flatMap { cal in eyes.isEmpty ? nil : cal.gazeOffset(irisUV: eyes.map(\.irisUV)) }
        let decision = director.update(DirectorInput(
            time: time,
            gazeOffset: gazeOffset,
            isBlinking: eyes.contains(where: \.isBlinking),
            isSpeaking: speaking,
            headYaw: yaw
        ))

        var warps: [EyeWarp] = []
        if settings.effectEnabled, let calibration, recorder == nil {
            warps = WarpPlanner.plan(eyes: eyes, calibration: calibration, output: decision, maxDisplacement: settings.maxCorrection, follow: settings.followReading)
        }

        let output = warper?.warp(pixelBuffer, eyes: warps) ?? pixelBuffer
        display.show(output)

        frameCount += 1
        if settings.eyeZoom, eyes.count == 2, frameCount.isMultiple(of: 2) {
            let regions = eyes.map { FrameExporter.eyeRegion($0.frame) }
            onEyeZoom?(EyeZoom(
                original: regions.compactMap { exporter.image(of: pixelBuffer, rect: $0) },
                corrected: regions.compactMap { exporter.image(of: output, rect: $0) },
                warped: !warps.isEmpty
            ))
        }

        if settings.showOverlay {
            var frame = debugFrame(for: pixelBuffer, eyes: eyes, warps: warps)
            frame.gazeOffset = gazeOffset
            frame.smoothedGaze = decision.smoothedGaze
            frame.target = decision.target
            frame.readingZone = calibration?.readingZone
            frame.readingCenter = calibration?.readingCenter
            frame.state = decision.state
            frame.weight = decision.weight
            frame.nextGlanceIn = decision.nextGlanceIn
            frame.isSpeaking = speaking
            onDebug?(frame)
        }
        recordStats(processing: CACurrentMediaTime() - start, pixelBuffer: pixelBuffer)
    }

    /// Returns both eyes (or none when the face or either eye is lost) and the head yaw.
    private func measureEyes(in pixelBuffer: CVPixelBuffer, time: Double) -> ([EyeMeasurement], Double?) {
        guard let face = faceTracker.detect(in: pixelBuffer) else {
            eyeTrackers.indices.forEach { eyeTrackers[$0].reset() }
            return ([], nil)
        }
        let eyes = LumaSampler.withSampler(pixelBuffer) { luma in
            (0..<2).compactMap { i in
                eyeTrackers[i].update(contour: face.eyes[i].contour, pupil: face.eyes[i].pupil, time: time) { luma($0) }
            }
        } ?? []
        return (eyes.count == 2 ? eyes : [], face.yaw)
    }

    private func record(_ eyes: [EyeMeasurement], from pixelBuffer: CVPixelBuffer, at time: Double, calibration: Calibration?, saveDiagnostics: Bool) {
        if let step = pendingCalibration.mutate({ value -> CalibrationRecorder.Step? in
            defer { value = nil }
            return value
        }) {
            recorder = CalibrationRecorder(step: step, startTime: time)
            if saveDiagnostics { diagnostics.begin(step: step.rawValue) }
        }
        guard var current = recorder else { return }

        current.add(eyes, at: time, base: calibration)
        diagnostics.record(pixelBuffer, time: time, eyes: eyes)
        if current.isFinished(at: time) {
            recorder = nil
            diagnostics.end()
            onCalibrationProgress?(nil)
            onCalibrationFinished?(current.step, current.result(base: calibration))
        } else {
            recorder = current
            onCalibrationProgress?(CalibrationProgress(step: current.step, progress: current.progress(at: time)))
        }
    }

    private func debugFrame(for pixelBuffer: CVPixelBuffer, eyes: [EyeMeasurement], warps: [EyeWarp]) -> DebugFrame {
        func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
        return DebugFrame(
            imageSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
            eyes: eyes.enumerated().map { i, eye in
                DebugFrame.Eye(
                    contour: eye.frame.contour.map(cg),
                    iris: cg(eye.frame.point(at: eye.irisUV)),
                    visionPupil: eye.visionPupilUV.map { cg(eye.frame.point(at: $0)) },
                    gradient: eye.gradientUV.map { cg(eye.frame.point(at: $0)) },
                    target: warps.indices.contains(i) ? cg(warps[i].iris + warps[i].displacement) : nil,
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
