import AVFoundation
import GazeCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    struct CameraOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published var cameras: [CameraOption] = []
    @Published var selectedCameraID: String? {
        didSet {
            if oldValue != selectedCameraID { camera.configure(deviceID: selectedCameraID) }
        }
    }
    @Published var settings = ProcessingSettings() {
        didSet {
            pipeline.settings.set(settings)
            if settings.talkMode != oldValue.talkMode { updateMicrophone() }
            if settings.irisSource != oldValue.irisSource, calibration != nil {
                calibration = nil
                calibrationMessage = "Iris source changed. Calibrate again."
            }
        }
    }
    @Published private(set) var calibration: Calibration? {
        didSet {
            pipeline.calibration.set(calibration)
            saveCalibration()
        }
    }
    @Published private(set) var calibrationProgress: CalibrationProgress?
    @Published private(set) var calibrationMessage: String?
    @Published private(set) var stats = PipelineStats()
    @Published private(set) var debugFrame = DebugFrame()
    @Published private(set) var eyeZoom = EyeZoom()
    @Published private(set) var clipProgress: Double?
    @Published private(set) var lastClipURL: URL?
    @Published private(set) var clipFailed = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var microphoneDenied = false

    let display = VideoDisplay()
    let camera = CameraCapture()
    let voice = VoiceActivity()
    let pipeline: Pipeline

    /// v2: calibrations are measured with Vision's pupil by default; v1 ones used the gradient locator.
    private static let calibrationKey = "calibration.v2"

    init() {
        pipeline = Pipeline(display: display)
        pipeline.isSpeaking = { [voice] in voice.isSpeaking }
        pipeline.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.stats = stats }
        }
        pipeline.onDebug = { [weak self] frame in
            DispatchQueue.main.async { self?.debugFrame = frame }
        }
        pipeline.onEyeZoom = { [weak self] zoom in
            DispatchQueue.main.async { self?.eyeZoom = zoom }
        }
        pipeline.onCalibrationProgress = { [weak self] progress in
            DispatchQueue.main.async { self?.calibrationProgress = progress }
        }
        pipeline.onCalibrationFinished = { [weak self] step, result in
            DispatchQueue.main.async { self?.finishCalibration(step: step, result: result) }
        }
        pipeline.onClipProgress = { [weak self] progress in
            DispatchQueue.main.async { self?.clipProgress = progress }
        }
        pipeline.onClipFinished = { [weak self] url in
            DispatchQueue.main.async { self?.finishClip(url) }
        }
        camera.onFrame = { [pipeline] sampleBuffer in
            pipeline.process(sampleBuffer)
        }

        if let data = UserDefaults.standard.data(forKey: Self.calibrationKey),
           let saved = try? JSONDecoder().decode(Calibration.self, from: data) {
            calibration = saved
            pipeline.calibration.set(saved)
        }
        pipeline.settings.set(settings)
    }

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            cameraDenied = true
            return
        }
        let devices = CameraCapture.availableDevices()
        cameras = devices.map { CameraOption(id: $0.uniqueID, name: $0.localizedName) }
        let preferred = AVCaptureDevice.default(for: .video)?.uniqueID
        selectedCameraID = selectedCameraID ?? cameras.first(where: { $0.id == preferred })?.id ?? cameras.first?.id
        camera.start()
    }

    // MARK: Calibration

    var canCalibrateReading: Bool { calibration != nil }

    func calibrate(_ step: CalibrationRecorder.Step) {
        calibrationMessage = nil
        calibrationProgress = CalibrationProgress(step: step, progress: 0)
        pipeline.pendingCalibration.set(step)
    }

    func resetCalibration() {
        calibration = nil
        calibrationMessage = nil
    }

    private func finishCalibration(step: CalibrationRecorder.Step, result: Calibration?) {
        calibrationProgress = nil
        guard let result else {
            calibrationMessage = "Not enough clear frames. Keep your face in view and try again."
            return
        }
        calibration = result
        calibrationMessage = switch step {
        case .camera: "Camera point saved. Now read some text for step 2."
        case .reading: "Reading zone saved. Redirection is active while you read."
        }
    }

    private func saveCalibration() {
        if let calibration, let data = try? JSONEncoder().encode(calibration) {
            UserDefaults.standard.set(data, forKey: Self.calibrationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.calibrationKey)
        }
    }

    // MARK: Before/after clip

    func recordClip() {
        clipFailed = false
        clipProgress = 0
        pipeline.pendingClip.set(true)
    }

    private func finishClip(_ url: URL?) {
        clipProgress = nil
        guard let url else {
            clipFailed = true
            return
        }
        lastClipURL = url
        NSWorkspace.shared.open(url)
    }

    // MARK: Microphone

    private func updateMicrophone() {
        guard settings.talkMode == .microphone else {
            voice.stop()
            return
        }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                microphoneDenied = true
                return
            }
            microphoneDenied = false
            do {
                try voice.start()
            } catch {
                microphoneDenied = true
            }
        }
    }
}
