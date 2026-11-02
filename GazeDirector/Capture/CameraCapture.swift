import AVFoundation

/// Owns the capture session and delivers BGRA camera frames on a dedicated serial queue.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "gaze.camera.session")
    private let frameQueue = DispatchQueue(label: "gaze.camera.frames", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    func configure(deviceID: String?) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            if let currentInput {
                session.removeInput(currentInput)
                self.currentInput = nil
            }
            let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
            guard let device,
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            currentInput = input

            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            }
            if session.outputs.isEmpty {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: frameQueue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
            }
        }
    }

    func start() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
