import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio
import os.log

private let log = Logger(subsystem: GazeCamera.extensionBundleIdentifier, category: "camera")

/// The "Gaze Director" camera. It has two streams:
/// - a sink stream the Gaze Director app pushes corrected frames into, and
/// - a source stream that FaceTime, Photo Booth, Teams, Zoom or a browser read from.
/// Frames from the sink are passed straight through. While the app is not sending, the source
/// stream shows a placeholder asking to open the app.
final class GazeCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: GazeCameraStreamSource!
    private var sinkStream: GazeCameraStreamSource!

    private let queue = DispatchQueue(label: "gaze.camera.device", qos: .userInteractive)
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var placeholderTimer: DispatchSourceTimer?
    /// Host time of the last frame from the app; the placeholder only shows after a gap.
    private var lastSinkFrame: UInt64 = 0
    private var placeholder: CVPixelBuffer?

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: GazeCamera.deviceID, legacyDeviceID: GazeCamera.deviceID.uuidString, source: self)

        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: GazeCamera.width, height: GazeCamera.height, extensions: nil, formatDescriptionOut: &description)
        let format = CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: GazeCamera.frameDuration, minFrameDuration: GazeCamera.frameDuration, validFrameDurations: nil)

        sourceStream = GazeCameraStreamSource(localizedName: "\(localizedName) Video", direction: .source, format: format, owner: self)
        sinkStream = GazeCameraStreamSource(localizedName: "\(localizedName) Input", direction: .sink, format: format, owner: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
        placeholder = Self.makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = GazeCamera.name
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source stream (apps reading the camera)

    fileprivate func startSource() {
        queue.async { [self] in
            sourceClients += 1
            guard placeholderTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: GazeCamera.frameDuration.seconds, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.sendPlaceholderIfIdle() }
            timer.resume()
            placeholderTimer = timer
        }
    }

    fileprivate func stopSource() {
        queue.async { [self] in
            sourceClients = max(0, sourceClients - 1)
            if sourceClients == 0 {
                placeholderTimer?.cancel()
                placeholderTimer = nil
            }
        }
    }

    private func sendPlaceholderIfIdle() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastSinkFrame > 500_000_000, let placeholder else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        guard let sample = Self.sampleBuffer(placeholder, time: time) else { return }
        sourceStream.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(time.seconds * Double(NSEC_PER_SEC)))
    }

    // MARK: Sink stream (the Gaze Director app pushing frames)

    fileprivate func startSink(client: CMIOExtensionClient) {
        queue.async { [self] in
            sinkClient = client
            consumeNext(from: client)
        }
    }

    fileprivate func stopSink() {
        queue.async { [self] in sinkClient = nil }
    }

    private func consumeNext(from client: CMIOExtensionClient) {
        guard sinkClient === client else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, error in
            guard let self else { return }
            self.queue.async {
                if let sample {
                    self.lastSinkFrame = DispatchTime.now().uptimeNanoseconds
                    let hostTime = UInt64(CMSampleBufferGetPresentationTimeStamp(sample).seconds * Double(NSEC_PER_SEC))
                    if self.sourceClients > 0 {
                        self.sourceStream.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTime)
                    }
                    self.sinkStream.stream.notifyScheduledOutputChanged(
                        CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: hostTime)
                    )
                    self.consumeNext(from: client)
                } else {
                    if let error { log.debug("sink consume: \(error.localizedDescription, privacy: .public)") }
                    // Nothing queued yet; try again shortly instead of spinning.
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consumeNext(from: client) }
                }
            }
        }
    }

    // MARK: Frames

    static func sampleBuffer(_ pixelBuffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: GazeCamera.frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample
    }

    /// Dark frame with a hint, shown while the app is not sending.
    private static func makePlaceholder() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(GazeCamera.width), Int(GazeCamera.height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(GazeCamera.width), height: Int(GazeCamera.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return buffer }
        context.setFillColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: Int(GazeCamera.width), height: Int(GazeCamera.height)))

        let text = NSAttributedString(string: "Open Gaze Director to start the camera", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.85, green: 0.85, blue: 0.88, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(GazeCamera.width) - bounds.width) / 2, y: (CGFloat(GazeCamera.height) - bounds.height) / 2)
        CTLineDraw(line, context)
        return buffer
    }
}

/// One stream of the device; the device does the work.
final class GazeCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let direction: CMIOExtensionStream.Direction
    private unowned let owner: GazeCameraDeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat, owner: GazeCameraDeviceSource) {
        self.format = format
        self.direction = direction
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: UUID(), direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            properties.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData])
        }
        return properties
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { streamProperties.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { streamProperties.frameDuration = GazeCamera.frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { streamProperties.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { streamProperties.sinkBuffersRequiredForStartup = 1 }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        switch direction {
        case .source:
            owner.startSource()
        case .sink:
            if let client { owner.startSink(client: client) }
        @unknown default:
            break
        }
    }

    func stopStream() throws {
        switch direction {
        case .source: owner.stopSource()
        case .sink: owner.stopSink()
        @unknown default: break
        }
    }
}

final class GazeCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: GazeCameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = GazeCameraDeviceSource(localizedName: GazeCamera.name)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = GazeCamera.name
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
