import Foundation

/// Warp parameters for one eye, in image pixels (top-left origin). Mirrors the Metal `EyeWarp` struct.
public struct EyeWarp: Equatable, Sendable {
    /// Current iris centre; the warp is centred here.
    public var iris: Vec2
    /// How far to move the iris.
    public var displacement: Vec2
    public var center: Vec2
    /// Unit vector along the eye, corner to corner.
    public var axis: Vec2
    /// Half width and half height of the eye opening.
    public var halfSize: Vec2
    public var irisRadius: Double

    public init(iris: Vec2, displacement: Vec2, center: Vec2, axis: Vec2, halfSize: Vec2, irisRadius: Double) {
        self.iris = iris
        self.displacement = displacement
        self.center = center
        self.axis = axis
        self.halfSize = halfSize
        self.irisRadius = irisRadius
    }
}

public enum WarpPlanner {
    /// Iris diameter is roughly 40% of the corner-to-corner eye width.
    static let irisRadiusRatio = 0.2

    /// Moves each iris from where it is to its camera point plus the director's target, scaled by
    /// the director's weight and capped at `maxDisplacement` (uv) to keep the warp believable.
    ///
    /// Per-frame iris estimates jitter by about as much as a reading saccade, so by default the eyes
    /// are assumed to sit at the calibrated reading centre and the correction is that fixed offset.
    /// `follow` (0...1) blends in the measured deviation from that centre, to also cancel the
    /// left-right sweep of reading at the cost of passing measurement noise into the warp.
    public static func plan(eyes: [EyeMeasurement], calibration: Calibration, output: DirectorOutput, maxDisplacement: Double, follow: Double = 0) -> [EyeWarp] {
        guard output.weight > 0.001, eyes.count == calibration.cameraUV.count else { return [] }
        return zip(eyes, calibration.cameraUV).map { eye, cameraUV in
            let frame = eye.frame
            let measured = eye.irisUV - cameraUV
            let current = calibration.readingCenter.map { $0 + (measured - $0) * follow } ?? measured
            let deltaUV = ((output.target - current) * output.weight).clamped(maxLength: maxDisplacement)
            return EyeWarp(
                iris: frame.point(at: eye.irisUV),
                displacement: frame.pixelVector(fromUV: deltaUV),
                center: frame.center,
                axis: frame.xAxis,
                halfSize: Vec2(frame.width / 2, max(frame.height / 2, frame.width * 0.12)),
                irisRadius: frame.width * irisRadiusRatio
            )
        }
    }
}
