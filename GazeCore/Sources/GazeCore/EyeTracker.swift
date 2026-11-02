import Foundation

/// One eye as seen in a single frame.
public struct EyeMeasurement: Sendable {
    public let frame: EyeFrame
    /// Smoothed iris centre in uv. While blinking it stays at the last open-eye value.
    public let irisUV: Vec2
    /// Unsmoothed iris centre in uv for this frame.
    public let rawIrisUV: Vec2
    public let visionPupilUV: Vec2?
    /// True when the gradient locator produced the estimate, false when it fell back to Vision's pupil.
    public let refined: Bool
    public let isBlinking: Bool
}

/// Measures one eye over time: refines the iris centre, smooths it, and freezes it through blinks.
public struct EyeTracker: Sendable {
    /// Openness (height / width) below which the eye counts as closed.
    public var blinkThreshold: Double = 0.17
    public var layout = EyeCropLayout()

    private var filter = OneEuroFilter2D()
    private var lastOpenIris: Vec2?

    public init() {}

    public mutating func reset() {
        filter.reset()
        lastOpenIris = nil
    }

    /// - Parameters:
    ///   - contour: eye contour in image pixels (top-left origin).
    ///   - pupil: Vision's pupil estimate in image pixels, if any.
    ///   - luma: brightness (0...1) at an image pixel position.
    public mutating func update(contour: [Vec2], pupil: Vec2?, time: Double, luma: (Vec2) -> Float) -> EyeMeasurement? {
        guard let frame = EyeFrame(contour: contour) else { return nil }
        let visionUV = pupil.map(frame.uv(of:))

        let crop = layout.crop(frame, luma: luma)
        var refinedUV: Vec2?
        if let p = IrisLocator.locate(in: crop.image, mask: crop.mask) {
            let uv = layout.uv(x: p.x, y: p.y)
            let plausible = abs(uv.x) < 0.45 && abs(uv.y) < 0.25
            let agrees = visionUV.map { (uv - $0).length < 0.2 } ?? true
            if plausible && agrees { refinedUV = uv }
        }
        guard let raw = refinedUV ?? visionUV else { return nil }

        let blinking = frame.openness < blinkThreshold
        let iris: Vec2
        if blinking {
            iris = lastOpenIris ?? raw
        } else {
            iris = filter.filter(raw, at: time)
            lastOpenIris = iris
        }
        return EyeMeasurement(
            frame: frame,
            irisUV: iris,
            rawIrisUV: raw,
            visionPupilUV: visionUV,
            refined: refinedUV != nil,
            isBlinking: blinking
        )
    }
}
