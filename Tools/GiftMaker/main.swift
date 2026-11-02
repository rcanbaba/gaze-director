// Renders the demo gifts as side-by-side alpha videos: colour (premultiplied over black) on the
// left half, the alpha mask as grey on the right half. This is the layout live-stream gift videos
// commonly use, so the app plays these and downloaded gifts the same way.
//
// Usage: gift-maker <output folder>

import AVFoundation
import CoreGraphics
import CoreText
import Foundation

let half = (width: 720, height: 1280)
let fps: Int32 = 30
let duration = 3.0
let frameCount = Int(duration * Double(fps))

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func drawEmoji(_ text: String, size: CGFloat, at point: CGPoint, rotation: CGFloat = 0, alpha: CGFloat = 1, in context: CGContext) {
    let font = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.saveGState()
    context.setAlpha(alpha)
    context.translateBy(x: point.x, y: point.y)
    context.rotate(by: rotation)
    context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
    CTLineDraw(line, context)
    context.restoreGState()
}

/// Fade in over the first 0.15 s and out over the last 0.4 s.
func envelope(_ t: Double) -> CGFloat {
    CGFloat(min(1, t / 0.15, (duration - t) / 0.4))
}

struct Gift {
    let name: String
    let draw: (CGContext, Double) -> Void
}

func hearts() -> Gift {
    var rng = SplitMix64(state: 11)
    let items = (0..<22).map { _ in
        (x: Double.random(in: 80...640, using: &rng), delay: Double.random(in: 0...1.2, using: &rng),
         speed: Double.random(in: 380...620, using: &rng), size: Double.random(in: 70...150, using: &rng),
         wobble: Double.random(in: 0...(2 * .pi), using: &rng), glyph: ["❤️", "💖", "💕", "💗"].randomElement(using: &rng)!)
    }
    return Gift(name: "Hearts") { context, t in
        for item in items where t > item.delay {
            let age = t - item.delay
            let y = -item.size + age * item.speed
            let x = item.x + sin(age * 3 + item.wobble) * 40
            drawEmoji(item.glyph, size: item.size, at: CGPoint(x: x, y: y), rotation: CGFloat(sin(age * 2 + item.wobble) * 0.25),
                      alpha: envelope(t) * CGFloat(min(1, age / 0.2)), in: context)
        }
    }
}

func confetti() -> Gift {
    var rng = SplitMix64(state: 23)
    let colors: [CGColor] = [
        CGColor(red: 1, green: 0.25, blue: 0.35, alpha: 1), CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1),
        CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1), CGColor(red: 0.25, green: 0.55, blue: 1, alpha: 1),
        CGColor(red: 0.75, green: 0.35, blue: 1, alpha: 1),
    ]
    let pieces = (0..<160).map { _ in
        (angle: Double.random(in: (.pi * 0.15)...(.pi * 0.85), using: &rng), speed: Double.random(in: 700...1500, using: &rng),
         spin: Double.random(in: -12...12, using: &rng), size: Double.random(in: 14...28, using: &rng), color: colors.randomElement(using: &rng)!)
    }
    return Gift(name: "Confetti") { context, t in
        let origin = CGPoint(x: Double(half.width) / 2, y: 260)
        drawEmoji("🎉", size: 220, at: origin, rotation: 0.2, alpha: envelope(t) * CGFloat(min(1, t / 0.1)), in: context)
        for piece in pieces {
            let x = origin.x + cos(piece.angle) * piece.speed * t * 0.55
            let y = origin.y + sin(piece.angle) * piece.speed * t - 900 * t * t
            context.saveGState()
            context.setAlpha(envelope(t))
            context.translateBy(x: x, y: y)
            context.rotate(by: CGFloat(piece.spin * t))
            context.setFillColor(piece.color)
            context.fill(CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.size / 2))
            context.restoreGState()
        }
    }
}

func stars() -> Gift {
    var rng = SplitMix64(state: 37)
    let rays = (0..<36).map { _ in
        (angle: Double.random(in: 0...(2 * .pi), using: &rng), speed: Double.random(in: 180...420, using: &rng),
         size: Double.random(in: 40...90, using: &rng), glyph: ["✨", "⭐️", "🌟"].randomElement(using: &rng)!)
    }
    return Gift(name: "Stars") { context, t in
        let center = CGPoint(x: Double(half.width) / 2, y: Double(half.height) * 0.55)
        let pulse = 1 + 0.12 * sin(t * 10)
        drawEmoji("🌟", size: 260 * pulse, at: center, alpha: envelope(t), in: context)
        for ray in rays {
            let r = ray.speed * t
            let p = CGPoint(x: center.x + cos(ray.angle) * r, y: center.y + sin(ray.angle) * r)
            drawEmoji(ray.glyph, size: ray.size * (0.6 + 0.4 * sin(t * 8 + ray.angle)), at: p, alpha: envelope(t), in: context)
        }
    }
}

func applause() -> Gift {
    var rng = SplitMix64(state: 41)
    let small = (0..<16).map { _ in
        (x: Double.random(in: 60...660, using: &rng), delay: Double.random(in: 0.2...1.6, using: &rng), size: Double.random(in: 60...110, using: &rng))
    }
    return Gift(name: "Applause") { context, t in
        let beat = abs(sin(t * 9))
        drawEmoji("👏", size: 300 * (0.9 + 0.15 * beat), at: CGPoint(x: Double(half.width) / 2, y: 420), rotation: CGFloat(0.08 * sin(t * 9)), alpha: envelope(t), in: context)
        for item in small where t > item.delay {
            let age = t - item.delay
            drawEmoji("👏", size: item.size, at: CGPoint(x: item.x, y: 120 + age * 420), alpha: envelope(t) * CGFloat(min(1, age / 0.2)), in: context)
        }
    }
}

func render(_ gift: Gift, to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: half.width * 2,
        AVVideoHeightKey: half.height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: half.width * 2,
        kCVPixelBufferHeightKey as String: half.height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let layer = CGContext(data: nil, width: half.width, height: half.height, bitsPerComponent: 8, bytesPerRow: half.width * 4,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for frame in 0..<frameCount {
        let t = Double(frame) / Double(fps)
        layer.clear(CGRect(x: 0, y: 0, width: half.width, height: half.height))
        gift.draw(layer, t)

        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let out = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let outRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = layer.data!.assumingMemoryBound(to: UInt8.self)
        // Bitmap memory is top row first, like video frames (only the drawing coordinates are bottom-up).
        for y in 0..<half.height {
            let s = src + y * half.width * 4
            let o = out + y * outRow
            for x in 0..<half.width {
                let r = s[x * 4], g = s[x * 4 + 1], b = s[x * 4 + 2], a = s[x * 4 + 3]
                o[x * 4] = b; o[x * 4 + 1] = g; o[x * 4 + 2] = r; o[x * 4 + 3] = 255
                let m = (half.width + x) * 4
                o[m] = a; o[m + 1] = a; o[m + 2] = a; o[m + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "GiftMaker", code: 1) }
}

guard CommandLine.arguments.count == 2 else {
    print("usage: gift-maker <output folder>")
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (index, gift) in [hearts(), confetti(), stars(), applause()].enumerated() {
    let url = folder.appendingPathComponent("\(index + 1)-\(gift.name).mp4")
    try render(gift, to: url)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\(url.lastPathComponent): \(size / 1024) KB")
}
