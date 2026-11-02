// Renders a synthetic eye, runs the real Metal warp on it with a few displacements and writes a
// magnified contact sheet, so the shader can be checked without a camera.
//
// Usage: warp-preview <EyeWarp.metal> <output.png>

import CoreGraphics
import CoreVideo
import Foundation
import GazeCore
import ImageIO
import Metal
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: warp-preview <EyeWarp.metal> <output.png>")
    exit(2)
}

let width = 320, height = 200
let eyeCenter = Vec2(160, 100)
let iris = Vec2(165, 98)

func makeBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    return buffer!
}

func withContext(_ buffer: CVPixelBuffer, _ body: (CGContext) -> Void) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    body(context)
}

func drawEye(_ c: CGContext) {
    // Top-left origin like the camera frames.
    c.translateBy(x: 0, y: CGFloat(height))
    c.scaleBy(x: 1, y: -1)

    c.setFillColor(red: 0.86, green: 0.68, blue: 0.56, alpha: 1)
    c.fill(CGRect(x: 0, y: 0, width: width, height: height))

    c.setStrokeColor(red: 0.35, green: 0.22, blue: 0.15, alpha: 1)
    c.setLineWidth(7)
    c.setLineCap(.round)
    c.move(to: CGPoint(x: 100, y: 52))
    c.addQuadCurve(to: CGPoint(x: 220, y: 50), control: CGPoint(x: 160, y: 28))
    c.strokePath()

    c.setStrokeColor(red: 0.7, green: 0.5, blue: 0.4, alpha: 1)
    c.setLineWidth(1.5)
    c.move(to: CGPoint(x: 115, y: 88))
    c.addQuadCurve(to: CGPoint(x: 205, y: 88), control: CGPoint(x: 160, y: 52))
    c.strokePath()

    let almond = CGMutablePath()
    almond.move(to: CGPoint(x: 110, y: 100))
    almond.addQuadCurve(to: CGPoint(x: 210, y: 100), control: CGPoint(x: 160, y: 62))
    almond.addQuadCurve(to: CGPoint(x: 110, y: 100), control: CGPoint(x: 160, y: 128))

    c.saveGState()
    c.addPath(almond)
    c.clip()
    c.setFillColor(red: 0.95, green: 0.93, blue: 0.9, alpha: 1)
    c.fill(CGRect(x: 100, y: 60, width: 120, height: 70))

    let irisCenter = CGPoint(x: iris.x, y: iris.y)
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [CGColor(red: 0.55, green: 0.38, blue: 0.2, alpha: 1), CGColor(red: 0.3, green: 0.18, blue: 0.1, alpha: 1)] as CFArray,
        locations: [0, 1]
    )!
    c.drawRadialGradient(gradient, startCenter: irisCenter, startRadius: 0, endCenter: irisCenter, endRadius: 20, options: [])
    c.setStrokeColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 0.6)
    c.setLineWidth(0.8)
    for i in 0..<24 {
        let a = Double(i) / 24 * 2 * .pi
        c.move(to: CGPoint(x: iris.x + cos(a) * 8, y: iris.y + sin(a) * 8))
        c.addLine(to: CGPoint(x: iris.x + cos(a) * 19, y: iris.y + sin(a) * 19))
    }
    c.strokePath()
    c.setStrokeColor(red: 0.12, green: 0.08, blue: 0.05, alpha: 1)
    c.setLineWidth(2)
    c.strokeEllipse(in: CGRect(x: iris.x - 20, y: iris.y - 20, width: 40, height: 40))
    c.setFillColor(red: 0.03, green: 0.02, blue: 0.02, alpha: 1)
    c.fillEllipse(in: CGRect(x: iris.x - 7, y: iris.y - 7, width: 14, height: 14))
    c.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.95)
    c.fillEllipse(in: CGRect(x: iris.x + 4, y: iris.y - 8, width: 5, height: 5))
    c.restoreGState()

    c.setStrokeColor(red: 0.1, green: 0.07, blue: 0.06, alpha: 1)
    c.setLineWidth(3)
    c.move(to: CGPoint(x: 110, y: 100))
    c.addQuadCurve(to: CGPoint(x: 210, y: 100), control: CGPoint(x: 160, y: 62))
    c.strokePath()
    c.setLineWidth(1)
    c.move(to: CGPoint(x: 110, y: 100))
    c.addQuadCurve(to: CGPoint(x: 210, y: 100), control: CGPoint(x: 160, y: 128))
    c.strokePath()
}

func cropImage(_ buffer: CVPixelBuffer) -> CGImage {
    var image: CGImage!
    withContext(buffer) { image = $0.makeImage() }
    return image.cropping(to: CGRect(x: 80, y: 25, width: 160, height: 120))!
}

let source = makeBuffer()
withContext(source, drawEye)

let device = MTLCreateSystemDefaultDevice()!
let shader = try String(contentsOfFile: arguments[1], encoding: .utf8)
let library = try device.makeLibrary(source: shader, options: nil)
guard let warper = MetalWarper(device: device, library: library) else {
    print("failed to create warper")
    exit(1)
}

let cases: [(String, Vec2)] = [
    ("original", .zero), ("right 8px", Vec2(8, 0)), ("left 10px", Vec2(-10, 0)),
    ("up 6px", Vec2(0, -6)), ("down 6px", Vec2(0, 6)), ("up-right", Vec2(6, -5)),
]
let scale = 3, columns = 3
let cellWidth = 160 * scale, cellHeight = 120 * scale
let sheet = CGContext(
    data: nil, width: cellWidth * columns, height: cellHeight * 2, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
sheet.interpolationQuality = .none

for (index, (name, displacement)) in cases.enumerated() {
    let warp = EyeWarp(iris: iris, displacement: displacement, center: eyeCenter, axis: Vec2(1, 0), halfSize: Vec2(50, 16.5), irisRadius: 20)
    guard let output = warper.warp(source, eyes: displacement == .zero ? [] : [warp]) else {
        print("warp failed for \(name)")
        exit(1)
    }
    let column = index % columns, row = index / columns
    let rect = CGRect(x: column * cellWidth, y: (1 - row) * cellHeight, width: cellWidth, height: cellHeight)
    sheet.draw(cropImage(output), in: rect)
    print("\(index + 1). \(name)")
}

let url = URL(fileURLWithPath: arguments[2])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, sheet.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("wrote \(url.path)")
