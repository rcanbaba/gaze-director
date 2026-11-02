// Runs the app's face and iris tracking on a still image and writes a magnified, annotated view of
// both eyes, so tracking can be checked on real faces without the live app.
//
// Usage: eye-probe <image> <output.png> [x y width height]
//   The optional rectangle crops the input first (for example the preview area of a screenshot);
//   the crop is scaled to 1280 px wide like a 720p camera frame.

import CoreGraphics
import CoreVideo
import Foundation
import GazeCore
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 7 else {
    print("usage: eye-probe <image> <output.png> [x y width height]")
    exit(2)
}

guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      var image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    print("cannot read \(arguments[1])")
    exit(1)
}
if arguments.count == 7, let r = arguments[3...6].map({ Double($0) }) as? [Double], let cropped = image.cropping(to: CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) {
    image = cropped
}

let width = 1280
let height = Int((Double(image.height) / Double(image.width) * Double(width)).rounded())
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

var buffer: CVPixelBuffer?
CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &buffer)
let frame = buffer!
CVPixelBufferLockBaseAddress(frame, [])
let frameContext = CGContext(
    data: CVPixelBufferGetBaseAddress(frame), width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
)!
frameContext.interpolationQuality = .high
frameContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
let frameImage = frameContext.makeImage()!
CVPixelBufferUnlockBaseAddress(frame, [])

guard let face = FaceTracker().detect(in: frame) else {
    print("no face found")
    exit(1)
}
print("yaw: \(face.yaw.map { String(format: "%.2f", $0) } ?? "–")")

var measurements: [EyeMeasurement] = []
var crops: [(GrayImage, [Bool])] = []
_ = LumaSampler.withSampler(frame) { luma in
    for eye in face.eyes {
        var tracker = EyeTracker()
        guard let m = tracker.update(contour: eye.contour, pupil: eye.pupil, time: 0, luma: { luma($0) }) else { continue }
        measurements.append(m)
        crops.append(tracker.layout.crop(m.frame) { luma($0) })
    }
}

for (i, m) in measurements.enumerated() {
    let fmt = { (v: Vec2?) in v.map { String(format: "(%+.3f, %+.3f)", $0.x, $0.y) } ?? "–" }
    print("eye \(i): width \(String(format: "%.1f", m.frame.width)) px, openness \(String(format: "%.2f", m.frame.openness)), contour points \(m.frame.contour.count)")
    print("  vision pupil uv \(fmt(m.visionPupilUV)), iris uv \(fmt(m.rawIrisUV)), refined \(m.refined)")
}

// Contact sheet: each eye magnified from the frame on the left, its eye-aligned crop on the right.
let zoom = 8.0, cropZoom = 10
let regionSize = CGSize(width: 64, height: 36)
let rowHeight = Int(regionSize.height * zoom)
let sheetWidth = Int(regionSize.width * zoom) + 48 * cropZoom + 30
let sheet = CGContext(
    data: nil, width: sheetWidth, height: rowHeight * max(1, measurements.count), bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
sheet.setFillColor(gray: 0.1, alpha: 1)
sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
sheet.interpolationQuality = .none
// Top-left origin from here on.
sheet.translateBy(x: 0, y: CGFloat(sheet.height))
sheet.scaleBy(x: 1, y: -1)

func flippedDraw(_ image: CGImage, in rect: CGRect) {
    sheet.saveGState()
    sheet.translateBy(x: rect.minX, y: rect.maxY)
    sheet.scaleBy(x: 1, y: -1)
    sheet.draw(image, in: CGRect(origin: .zero, size: rect.size))
    sheet.restoreGState()
}

func mark(_ p: CGPoint, _ r: CGFloat, _ color: CGColor, fill: Bool) {
    let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
    if fill {
        sheet.setFillColor(color)
        sheet.fillEllipse(in: rect)
    } else {
        sheet.setStrokeColor(color)
        sheet.setLineWidth(2)
        sheet.strokeEllipse(in: rect)
    }
}

let green = CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)
let yellow = CGColor(red: 1, green: 0.9, blue: 0, alpha: 1)
let cyan = CGColor(red: 0, green: 0.9, blue: 1, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

for (row, m) in measurements.enumerated() {
    let top = CGFloat(row * rowHeight)
    let origin = CGPoint(x: m.frame.center.x - regionSize.width / 2, y: m.frame.center.y - regionSize.height / 2)
    if let region = frameImage.cropping(to: CGRect(origin: origin, size: regionSize)) {
        flippedDraw(region, in: CGRect(x: 0, y: top, width: regionSize.width * zoom, height: regionSize.height * zoom))
    }
    func toSheet(_ v: Vec2) -> CGPoint {
        CGPoint(x: (v.x - origin.x) * zoom, y: top + (v.y - origin.y) * zoom)
    }
    sheet.setStrokeColor(green)
    sheet.setLineWidth(1.5)
    sheet.addLines(between: m.frame.contour.map(toSheet))
    sheet.closePath()
    sheet.strokePath()
    mark(toSheet(m.frame.center), 3, white, fill: true)
    if let pupil = m.visionPupilUV { mark(toSheet(m.frame.point(at: pupil)), 5, yellow, fill: true) }
    mark(toSheet(m.frame.point(at: m.rawIrisUV)), m.frame.width * 0.2 * zoom, cyan, fill: false)
    mark(toSheet(m.frame.point(at: m.rawIrisUV)), 3, cyan, fill: true)

    // Eye-aligned crop as the locator sees it, mask edge in green.
    let (gray, mask) = crops[row]
    let cropLeft = CGFloat(regionSize.width * zoom) + 30
    for y in 0..<gray.height {
        for x in 0..<gray.width {
            let v = CGFloat(gray[x, y])
            sheet.setFillColor(red: v, green: v, blue: v, alpha: 1)
            let cell = CGRect(x: cropLeft + CGFloat(x * cropZoom), y: top + CGFloat(y * cropZoom), width: CGFloat(cropZoom), height: CGFloat(cropZoom))
            sheet.fill(cell)
            let edge = mask[y * gray.width + x] && (x == 0 || y == 0 || x == gray.width - 1 || y == gray.height - 1
                || !mask[y * gray.width + x - 1] || !mask[y * gray.width + x + 1]
                || !mask[(y - 1) * gray.width + x] || !mask[(y + 1) * gray.width + x])
            if edge {
                sheet.setStrokeColor(green)
                sheet.setLineWidth(1)
                sheet.stroke(cell.insetBy(dx: 2, dy: 2))
            }
        }
    }
    let layout = EyeCropLayout()
    let cell = layout.uExtent * 2 / Double(layout.width)
    func cropPoint(_ uv: Vec2) -> CGPoint {
        CGPoint(x: cropLeft + CGFloat((uv.x + layout.uExtent) / cell) * CGFloat(cropZoom),
                y: top + CGFloat((uv.y + layout.vExtent) / cell) * CGFloat(cropZoom))
    }
    if let pupil = m.visionPupilUV { mark(cropPoint(pupil), 5, yellow, fill: true) }
    mark(cropPoint(m.rawIrisUV), 5, cyan, fill: true)
}

let url = URL(fileURLWithPath: arguments[2])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, sheet.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("wrote \(url.path)")
