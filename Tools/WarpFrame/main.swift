// Applies the full correction to one saved camera frame, using the calibration from a diagnostics
// session, and writes a before/after sheet: both eyes at 2× (roughly how a call shows them) and
// each eye at 6×.
//
// Usage: warp-frame <camera-step folder> <reading-step folder> <frame.png> <output.png> [--gradient] [--strength 1.0] [--follow 0] [--max 0.16]
//   Columns: reading frame as recorded | corrected | a frame from the camera step (the goal).

import CoreGraphics
import CoreVideo
import Foundation
import GazeCore
import ImageIO
import Metal
import UniformTypeIdentifiers

let useGradient = CommandLine.arguments.contains("--gradient")
var strength = 1.0
var follow = 0.0
var maxCorrection = 0.16
var arguments: [String] = []
var argumentIterator = CommandLine.arguments.makeIterator()
while let argument = argumentIterator.next() {
    if argument == "--gradient" { continue }
    if argument == "--strength", let value = argumentIterator.next().flatMap(Double.init) { strength = value; continue }
    if argument == "--follow", let value = argumentIterator.next().flatMap(Double.init) { follow = value; continue }
    if argument == "--max", let value = argumentIterator.next().flatMap(Double.init) { maxCorrection = value; continue }
    arguments.append(argument)
}
guard arguments.count == 5 else {
    print("usage: warp-frame <camera-step folder> <reading-step folder> <frame.png> <output.png> [--gradient] [--strength 1.0] [--follow 0] [--max 0.16]")
    exit(2)
}

// With --gradient the calibration is redone from the saved frames, since logged sessions may have
// been recorded with Vision's pupil.
let calibrated = useGradient
    ? calibrationFromFrames(cameraFolder: arguments[1], readingFolder: arguments[2], source: .gradient)
    : calibration(cameraFolder: arguments[1], readingFolder: arguments[2], useVisionPupil: true)
guard let calibration = calibrated,
      let center = calibration.readingCenter else {
    print("calibration failed")
    exit(1)
}
print(String(format: "reading centre (%+.3f, %+.3f), offset used (%+.3f, %+.3f) uv, strength %.2f", center.x, center.y, calibration.readingOffset!.x, calibration.readingOffset!.y, strength))

func measureEyes(_ frame: CVPixelBuffer) -> [EyeMeasurement] {
    guard let face = FaceTracker().detect(in: frame) else { return [] }
    let eyes: [EyeMeasurement] = LumaSampler.withSampler(frame) { luma in
        face.eyes.compactMap { eye in
            var tracker = EyeTracker()
            tracker.source = useGradient ? .gradient : .vision
            return tracker.update(contour: eye.contour, pupil: eye.pupil, time: 0) { luma($0) }
        }
    } ?? []
    return eyes.count == 2 ? eyes : []
}

let frame = loadFrame(arguments[3])
let eyes = measureEyes(frame)
guard eyes.count == 2 else {
    print("need both eyes in \(arguments[3])")
    exit(1)
}

// The goal: a frame from the middle of the camera step, cropped around its own eyes.
let referencePath = URL(fileURLWithPath: arguments[1]).appendingPathComponent("frame-0030.png").path
let reference = FileManager.default.fileExists(atPath: referencePath) ? loadFrame(referencePath) : nil
let referenceEyes = reference.map(measureEyes) ?? []

let output = DirectorOutput(target: .zero, weight: 1, state: .engaged)
let warps = WarpPlanner.plan(eyes: eyes, calibration: calibration, output: output, maxDisplacement: maxCorrection, follow: follow, strength: strength)
for (i, w) in warps.enumerated() {
    print(String(format: "eye %d: displacement (%+.1f, %+.1f) px", i, w.displacement.x, w.displacement.y))
}

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: String(contentsOfFile: "GazeDirector/Render/EyeWarp.metal", encoding: .utf8), options: nil)
guard let warper = MetalWarper(device: device, library: library), let corrected = warper.warp(frame, eyes: warps) else {
    print("warp failed")
    exit(1)
}

let exporter = FrameExporter()

func pairRect(_ eyes: [EyeMeasurement]) -> CGRect {
    let left = eyes[0].frame, right = eyes[1].frame
    return CGRect(
        x: left.center.x - left.width * 1.3, y: (left.center.y + right.center.y) / 2 - left.width * 0.8,
        width: right.center.x - left.center.x + left.width * 2.6, height: left.width * 1.6
    ).integral
}

let pairScale = 1.6, eyeScale = 5.0
let pair = pairRect(eyes)
let eyeRects = eyes.map { FrameExporter.eyeRegion($0.frame) }
let pairSize = CGSize(width: pair.width * pairScale, height: pair.height * pairScale)
let eyeSize = CGSize(width: eyeRects[0].width * eyeScale, height: eyeRects[0].height * eyeScale)
let gap = 12.0
let columns = referenceEyes.count == 2 ? 3.0 : 2.0
let width = max(pairSize.width, eyeSize.width) * columns + gap * (columns - 1)
let height = pairSize.height + gap + eyeSize.height * 2 + gap
let sheet = CGContext(
    data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
sheet.setFillColor(gray: 0.12, alpha: 1)
sheet.fill(CGRect(x: 0, y: 0, width: width, height: height))
sheet.interpolationQuality = .high

/// Draws with a top-left origin.
func place(_ image: CGImage?, x: Double, y: Double, size: CGSize) {
    guard let image else { return }
    sheet.draw(image, in: CGRect(x: x, y: height - y - size.height, width: size.width, height: size.height))
}

// Top row: both eyes. Below: each eye. Columns: as recorded | corrected | camera-step reference.
var sources: [(CVPixelBuffer, [EyeMeasurement])] = [(frame, eyes), (corrected, eyes)]
if let reference, referenceEyes.count == 2 { sources.append((reference, referenceEyes)) }
let column = max(pairSize.width, eyeSize.width) + gap
for (index, (buffer, measured)) in sources.enumerated() {
    let x = Double(index) * column
    place(exporter.image(of: buffer, rect: pairRect(measured)), x: x, y: 0, size: pairSize)
    for (row, eye) in measured.enumerated() {
        let y = pairSize.height + gap + Double(row) * eyeSize.height
        place(exporter.image(of: buffer, rect: FrameExporter.eyeRegion(eye.frame)), x: x, y: y, size: eyeSize)
    }
}

let url = URL(fileURLWithPath: arguments[4])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, sheet.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("wrote \(url.path)")
