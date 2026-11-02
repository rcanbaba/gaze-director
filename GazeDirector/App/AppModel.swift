import AVFoundation
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
        didSet { pipeline.settings.set(settings) }
    }
    @Published private(set) var stats = PipelineStats()
    @Published private(set) var cameraDenied = false

    let display = VideoDisplay()
    let camera = CameraCapture()
    let pipeline: Pipeline

    init() {
        pipeline = Pipeline(display: display)
        pipeline.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.stats = stats }
        }
        camera.onFrame = { [pipeline] sampleBuffer in
            pipeline.process(sampleBuffer)
        }
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
}
