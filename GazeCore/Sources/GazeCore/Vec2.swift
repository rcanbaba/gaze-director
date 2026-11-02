import simd

/// 2D vector used for all gaze math. Image-space points use a top-left origin with y pointing down.
public typealias Vec2 = SIMD2<Double>

extension SIMD2 where Scalar == Double {
    public var length: Double { simd_length(self) }

    public var normalized: Vec2 {
        let l = length
        return l > 0 ? self / l : .zero
    }

    /// Perpendicular vector rotated +90° in image space (x right, y down), so (1, 0) maps to (0, 1).
    public var perpendicular: Vec2 { Vec2(-y, x) }

    public func dot(_ other: Vec2) -> Double { simd_dot(self, other) }

    /// Scales the vector down so its length does not exceed `maxLength`.
    public func clamped(maxLength: Double) -> Vec2 {
        let l = length
        return l > maxLength && l > 0 ? self * (maxLength / l) : self
    }
}
