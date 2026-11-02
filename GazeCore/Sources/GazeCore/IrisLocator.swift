import Foundation

/// Row-major grayscale image with values in 0...1.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> Float {
        pixels[y * width + x]
    }
}

/// Grid used to resample an eye into an eye-aligned crop. The crop spans u in ±uExtent and v in ±vExtent.
public struct EyeCropLayout: Sendable {
    /// About one cell per pixel for a 55 px wide eye in a 1080p frame.
    public var width = 64
    public var height = 32
    public var uExtent = 0.6
    public var vExtent = 0.3

    public init() {}

    var cellSize: Double { 2 * uExtent / Double(width) }

    public func uv(x: Double, y: Double) -> Vec2 {
        Vec2(-uExtent + (x + 0.5) * cellSize, -vExtent + (y + 0.5) * cellSize)
    }

    /// Samples an eye into a crop. `luma` returns brightness (0...1) at an image pixel position.
    public func crop(_ eye: EyeFrame, luma: (Vec2) -> Float) -> (image: GrayImage, mask: [Bool]) {
        let polygon = eye.uvContour
        var pixels = [Float](repeating: 0, count: width * height)
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let uv = uv(x: Double(x), y: Double(y))
                pixels[y * width + x] = luma(eye.point(at: uv))
                mask[y * width + x] = polygonContains(polygon, uv)
            }
        }
        return (GrayImage(width: width, height: height, pixels: pixels), mask)
    }
}

/// Gradient-based eye centre localisation (Timm & Barth, 2011), no learning involved.
///
/// The iris is a dark disk, so image gradients on its rim point away from its centre. For each candidate
/// centre the objective sums how well the displacement to each strong gradient lines up with that gradient,
/// weighted by how dark the candidate is. Only outward-pointing gradients count, which ignores lid edges.
public enum IrisLocator {
    /// Returns the iris centre in crop pixel coordinates, or nil when the crop holds no usable signal.
    ///
    /// - Parameter highlightRadius: bright spots up to about twice this size (in cells) are removed
    ///   first. A screen reflection inside a dark pupil otherwise makes the true centre look bright
    ///   and adds gradients of its own, and the result jumps between two places. 0 turns it off.
    public static func locate(in source: GrayImage, mask: [Bool], highlightRadius: Int = 3) -> Vec2? {
        let image = highlightRadius > 0 ? removeHighlights(source, radius: highlightRadius) : source
        let w = image.width, h = image.height
        guard w >= 5, h >= 5, mask.count == w * h else { return nil }

        let blurred = boxBlur(image)

        struct Gradient { var x: Float; var y: Float; var gx: Float; var gy: Float }
        var raw: [(x: Int, y: Int, gx: Float, gy: Float, mag: Float)] = []
        raw.reserveCapacity(w * h / 2)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where mask[y * w + x] {
                let gx = (image[x + 1, y] - image[x - 1, y]) * 0.5
                let gy = (image[x, y + 1] - image[x, y - 1]) * 0.5
                let mag = (gx * gx + gy * gy).squareRoot()
                if mag > 0 { raw.append((x, y, gx, gy, mag)) }
            }
        }
        guard raw.count >= 8 else { return nil }

        let mean = raw.reduce(0) { $0 + $1.mag } / Float(raw.count)
        let variance = raw.reduce(0) { $0 + ($1.mag - mean) * ($1.mag - mean) } / Float(raw.count)
        let threshold = mean + 0.3 * variance.squareRoot()
        let gradients = raw.filter { $0.mag > threshold }.map {
            Gradient(x: Float($0.x), y: Float($0.y), gx: $0.gx / $0.mag, gy: $0.gy / $0.mag)
        }
        guard gradients.count >= 4 else { return nil }

        var scores = [Float](repeating: 0, count: w * h)
        var best: (index: Int, score: Float) = (-1, 0)
        for cy in 0..<h {
            for cx in 0..<w where mask[cy * w + cx] {
                let fx = Float(cx), fy = Float(cy)
                var sum: Float = 0
                for g in gradients {
                    let dx = g.x - fx, dy = g.y - fy
                    let d2 = dx * dx + dy * dy
                    if d2 == 0 { continue }
                    let dot = (dx * g.gx + dy * g.gy) / d2.squareRoot()
                    if dot > 0 { sum += dot * dot }
                }
                let score = sum / Float(gradients.count) * (1 - blurred[cx, cy])
                scores[cy * w + cx] = score
                if score > best.score { best = (cy * w + cx, score) }
            }
        }
        guard best.index >= 0 else { return nil }

        let bx = best.index % w, by = best.index / w
        func parabolic(_ a: Float, _ b: Float, _ c: Float) -> Double {
            let denom = a - 2 * b + c
            guard denom < 0 else { return 0 }
            return Double(max(-0.5, min(0.5, 0.5 * (a - c) / denom)))
        }
        let s = { (x: Int, y: Int) -> Float in
            (0..<w).contains(x) && (0..<h).contains(y) ? scores[y * w + x] : 0
        }
        let ox = parabolic(s(bx - 1, by), best.score, s(bx + 1, by))
        let oy = parabolic(s(bx, by - 1), best.score, s(bx, by + 1))
        return Vec2(Double(bx) + ox, Double(by) + oy)
    }

    /// Grayscale opening (min filter, then max filter over a square window): bright spots smaller
    /// than the window vanish, while larger bright areas such as the sclera keep their shape.
    static func removeHighlights(_ image: GrayImage, radius: Int) -> GrayImage {
        let eroded = rankFilter(rankFilter(image, radius: radius, horizontal: true, pick: min), radius: radius, horizontal: false, pick: min)
        return rankFilter(rankFilter(eroded, radius: radius, horizontal: true, pick: max), radius: radius, horizontal: false, pick: max)
    }

    private static func rankFilter(_ image: GrayImage, radius: Int, horizontal: Bool, pick: (Float, Float) -> Float) -> GrayImage {
        let w = image.width, h = image.height
        var out = image.pixels
        for y in 0..<h {
            for x in 0..<w {
                var value = image[x, y]
                for d in -radius...radius where d != 0 {
                    let sx = horizontal ? x + d : x, sy = horizontal ? y : y + d
                    if sx >= 0, sx < w, sy >= 0, sy < h { value = pick(value, image[sx, sy]) }
                }
                out[y * w + x] = value
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    private static func boxBlur(_ image: GrayImage) -> GrayImage {
        let w = image.width, h = image.height
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                var n: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let sx = x + dx, sy = y + dy
                        if sx >= 0, sx < w, sy >= 0, sy < h {
                            sum += image[sx, sy]
                            n += 1
                        }
                    }
                }
                out[y * w + x] = sum / n
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}
