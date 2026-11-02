/// An eye-aligned coordinate frame built from the eye contour.
///
/// The x axis runs corner to corner (image-left to image-right), the y axis points down in the image.
/// Normalized "uv" coordinates are measured from the eye center in units of the corner-to-corner width,
/// on both axes, so a displacement in uv maps to pixels with a single scale.
public struct EyeFrame: Equatable, Sendable {
    public let contour: [Vec2]
    public let center: Vec2
    public let xAxis: Vec2
    public let width: Double
    /// Lid-to-lid extent perpendicular to the eye axis, in pixels.
    public let height: Double

    public var yAxis: Vec2 { xAxis.perpendicular }
    /// Height over width; drops sharply during a blink.
    public var openness: Double { width > 0 ? height / width : 0 }

    /// Returns nil when the contour is too small to describe an eye.
    public init?(contour: [Vec2]) {
        guard contour.count >= 4 else { return nil }

        var cornerA = contour[0], cornerB = contour[1]
        var best = -1.0
        for i in 0..<contour.count {
            for j in (i + 1)..<contour.count {
                let d = (contour[i] - contour[j]).length
                if d > best {
                    best = d
                    cornerA = contour[i]
                    cornerB = contour[j]
                }
            }
        }
        if cornerA.x > cornerB.x { swap(&cornerA, &cornerB) }
        guard best > 1 else { return nil }

        let axis = (cornerB - cornerA).normalized
        let center = (cornerA + cornerB) / 2
        let perp = axis.perpendicular
        var minY = Double.infinity, maxY = -Double.infinity
        for p in contour {
            let y = (p - center).dot(perp)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        self.contour = contour
        self.center = center
        self.xAxis = axis
        self.width = best
        self.height = maxY - minY
    }

    public func uv(of point: Vec2) -> Vec2 {
        let d = point - center
        return Vec2(d.dot(xAxis), d.dot(yAxis)) / width
    }

    public func point(at uv: Vec2) -> Vec2 {
        center + (xAxis * uv.x + yAxis * uv.y) * width
    }

    /// Converts a uv-space displacement to an image-space displacement in pixels.
    public func pixelVector(fromUV delta: Vec2) -> Vec2 {
        (xAxis * delta.x + yAxis * delta.y) * width
    }

    /// The contour expressed in uv coordinates.
    public var uvContour: [Vec2] { contour.map(uv(of:)) }
}

/// Even-odd point-in-polygon test.
public func polygonContains(_ polygon: [Vec2], _ p: Vec2) -> Bool {
    guard polygon.count >= 3 else { return false }
    var inside = false
    var j = polygon.count - 1
    for i in 0..<polygon.count {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y) {
            let xCross = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
            if p.x < xCross { inside.toggle() }
        }
        j = i
    }
    return inside
}
