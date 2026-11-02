// Loading saved PNG frames into Metal-compatible BGRA pixel buffers, like the camera delivers.
// Shared by the tools.

import CoreGraphics
import CoreVideo
import Foundation
import GazeCore
import ImageIO

func loadFrame(_ path: String) -> CVPixelBuffer {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("cannot read \(path)")
        exit(1)
    }
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    let frame = buffer!
    CVPixelBufferLockBaseAddress(frame, [])
    CGContext(
        data: CVPixelBufferGetBaseAddress(frame), width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    CVPixelBufferUnlockBaseAddress(frame, [])
    return frame
}

/// Re-runs face and iris tracking on a calibration session's saved frames (every 5th camera frame)
/// and calibrates from that, so a different iris source can be tried on old recordings.
func calibrationFromFrames(cameraFolder: String, readingFolder: String, source: IrisSource) -> Calibration? {
    func frames(_ folder: String) -> [(Double, [EyeMeasurement])] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".png") }.sorted() ?? []
        return files.compactMap { file in
            guard let index = Int(file.dropFirst("frame-".count).prefix(4)) else { return nil }
            let frame = loadFrame(folder + "/" + file)
            guard let face = FaceTracker().detect(in: frame) else { return nil }
            let eyes: [EyeMeasurement] = LumaSampler.withSampler(frame) { luma in
                face.eyes.compactMap { eye in
                    var tracker = EyeTracker()
                    tracker.source = source
                    return tracker.update(contour: eye.contour, pupil: eye.pupil, time: 0) { luma($0) }
                }
            } ?? []
            return (Double(index) / 30, eyes.count == 2 ? eyes : [])
        }
    }
    let camera = calibrate(.camera, frames(cameraFolder), base: nil)
    return calibrate(.reading, frames(readingFolder), base: camera)
}
