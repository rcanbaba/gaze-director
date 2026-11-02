import CoreMediaIO
import CoreVideo
import QuartzCore
import VideoToolbox

/// Pushes corrected frames into the Gaze Director camera extension's sink stream, from where
/// FaceTime, Photo Booth, Teams, Zoom and browsers read them. Used on the frame queue only.
final class VirtualCameraOutput {
    /// Called on the frame queue when the connection to the extension comes or goes.
    var onConnectionChange: ((Bool) -> Void)?

    private var queue: CMSimpleQueue?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var lastAttempt = -Double.infinity

    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        if queue == nil {
            // The extension may not be installed yet; look for it every couple of seconds.
            let now = CACurrentMediaTime()
            guard now - lastAttempt > 2 else { return }
            lastAttempt = now
            connect()
        }
        guard let queue, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue),
              let scaled = scale(pixelBuffer),
              let sample = Self.sampleBuffer(scaled, time: time) else { return }
        // The extension takes ownership of each queued buffer.
        if CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque()) != noErr {
            Unmanaged.passUnretained(sample).release()
        }
    }

    private func connect() {
        guard let device = Self.findDevice(), let streams = Self.streams(of: device), streams.count >= 2 else { return }
        // The extension adds its source stream first and the sink stream second.
        let sink = streams[1]
        var queueRef: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueRef) == noErr, let queueRef else { return }
        guard CMIODeviceStartStream(device, sink) == noErr else { return }
        queue = queueRef.takeRetainedValue()
        onConnectionChange?(true)
    }

    private func scale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        }
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(GazeCamera.width),
                kCVPixelBufferHeightKey as String: Int(GazeCamera.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let transfer, let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output, VTPixelTransferSessionTransferImage(transfer, from: pixelBuffer, to: output) == noErr else { return nil }
        return output
    }

    private static func sampleBuffer(_ pixelBuffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: GazeCamera.frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample
    }

    // MARK: Core Media I/O lookups

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func objectIDs(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID]? {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return nil }
        return ids
    }

    private static func findDevice() -> CMIOObjectID? {
        guard let devices = objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices) else { return nil }
        return devices.first { device in
            var address = address(kCMIODevicePropertyDeviceUID)
            var uid: Unmanaged<CFString>?
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &uid) == noErr,
                  let value = uid?.takeRetainedValue() else { return false }
            return (value as String) == GazeCamera.deviceID.uuidString
        }
    }

    private static func streams(of device: CMIOObjectID) -> [CMIOStreamID]? {
        objectIDs(of: device, selector: kCMIODevicePropertyStreams)
    }
}
