import AVFoundation
import AppKit
import SwiftUI

/// Shows processed frames with an AVSampleBufferDisplayLayer. Frames can be pushed from any queue.
final class VideoDisplay: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    func show(_ pixelBuffer: CVPixelBuffer) {
        guard let sampleBuffer = Self.makeSampleBuffer(pixelBuffer) else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

/// Hosts the display layer in SwiftUI. Mirroring flips the layer only, so tracking stays in camera space.
struct VideoPreview: NSViewRepresentable {
    let display: VideoDisplay
    var mirrored: Bool

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(display.layer)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.layer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    final class HostView: NSView {
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}
