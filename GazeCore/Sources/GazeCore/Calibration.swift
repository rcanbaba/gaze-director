import Foundation

/// Axis-aligned rectangle in gaze-offset space (uv relative to the camera point).
public struct GazeRect: Codable, Equatable, Sendable {
    public var minX: Double
    public var maxX: Double
    public var minY: Double
    public var maxY: Double

    public init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    public func contains(_ p: Vec2, margin: Double = 0) -> Bool {
        p.x >= minX - margin && p.x <= maxX + margin && p.y >= minY - margin && p.y <= maxY + margin
    }
}

/// What the user's eyes look like when looking at the camera, and where they go while reading.
public struct Calibration: Codable, Equatable, Sendable {
    /// Iris uv of each eye (image-left, image-right) while looking at the camera.
    public var cameraUV: [Vec2]
    /// Eye openness while looking at the camera; blinks are detected relative to it.
    public var openness: Double
    /// Range of the gaze offset while reading. Redirection only happens inside it.
    public var readingZone: GazeRect?
    /// Typical gaze offset while reading (median). The warp corrects by this fixed amount, which is
    /// far steadier than following the per-frame iris estimate.
    public var readingCenter: Vec2?
    /// Median eye openness while reading minus while looking at the camera. Positive means the eyes
    /// open wider when reading, i.e. the reading spot is higher than the lens.
    public var readingOpennessChange: Double?

    public init(cameraUV: [Vec2], openness: Double, readingZone: GazeRect? = nil, readingCenter: Vec2? = nil, readingOpennessChange: Double? = nil) {
        self.cameraUV = cameraUV
        self.openness = openness
        self.readingZone = readingZone
        self.readingCenter = readingCenter
        self.readingOpennessChange = readingOpennessChange
    }

    /// The fixed offset the warp undoes while reading.
    ///
    /// Horizontal comes from the pupil. Vision's pupil barely moves vertically, but the upper lid
    /// follows vertical gaze closely, so the vertical part comes from how much wider (looking up) or
    /// narrower (looking down) the eye opens while reading, when that is the larger signal.
    public var readingOffset: Vec2? {
        guard let center = readingCenter else { return nil }
        guard let change = readingOpennessChange, abs(change) > abs(center.y) else { return center }
        return Vec2(center.x, -change)
    }

    /// Mean offset of both irises from their camera positions.
    public func gazeOffset(irisUV: [Vec2]) -> Vec2 {
        let pairs = zip(irisUV, cameraUV)
        return pairs.reduce(Vec2.zero) { $0 + ($1.0 - $1.1) } / Double(max(1, min(irisUV.count, cameraUV.count)))
    }

    /// Openness below this counts as a blink.
    public var blinkThreshold: Double { openness * 0.6 }
}

/// Collects samples for one calibration step and turns them into a calibration.
public struct CalibrationRecorder: Sendable {
    public enum Step: String, Sendable {
        /// Look at the camera lens.
        case camera
        /// Read text the way you will during a call.
        case reading
    }

    public let step: Step
    public let startTime: Double
    public let duration: Double
    /// Samples from the first moments are dropped while the eyes settle.
    public var settleTime = 0.5
    public var zoneMargin = 0.02

    private var irisSamples: [[Vec2]] = [[], []]
    /// Mean of both eyes' openness, in either step.
    private var opennessSamples: [Double] = []
    private var offsetSamples: [Vec2] = []

    public init(step: Step, startTime: Double) {
        self.step = step
        self.startTime = startTime
        self.duration = step == .camera ? 2.0 : 8.0
    }

    public func progress(at time: Double) -> Double {
        min(1, max(0, (time - startTime) / duration))
    }

    public func isFinished(at time: Double) -> Bool {
        time - startTime >= duration
    }

    public mutating func add(_ eyes: [EyeMeasurement], at time: Double, base: Calibration?) {
        guard eyes.count == 2, time - startTime >= settleTime, !eyes.contains(where: \.isBlinking) else { return }
        switch step {
        case .camera:
            for i in 0..<2 { irisSamples[i].append(eyes[i].irisUV) }
            opennessSamples.append(eyes.map(\.frame.openness).reduce(0, +) / 2)
        case .reading:
            guard let base else { return }
            offsetSamples.append(base.gazeOffset(irisUV: eyes.map(\.irisUV)))
            opennessSamples.append(eyes.map(\.frame.openness).reduce(0, +) / 2)
        }
    }

    /// The updated calibration, or nil if too few samples were collected.
    public func result(base: Calibration?) -> Calibration? {
        switch step {
        case .camera:
            guard irisSamples.allSatisfy({ $0.count >= 10 }) else { return nil }
            // A new camera point invalidates the reading zone, which is relative to it.
            return Calibration(
                cameraUV: irisSamples.map { Vec2(percentile($0.map(\.x), 0.5), percentile($0.map(\.y), 0.5)) },
                openness: percentile(opennessSamples, 0.5)
            )
        case .reading:
            guard var calibration = base, offsetSamples.count >= 30 else { return nil }
            let xs = offsetSamples.map(\.x), ys = offsetSamples.map(\.y)
            calibration.readingZone = GazeRect(
                minX: percentile(xs, 0.05) - zoneMargin,
                maxX: percentile(xs, 0.95) + zoneMargin,
                minY: percentile(ys, 0.05) - zoneMargin,
                maxY: percentile(ys, 0.95) + zoneMargin
            )
            calibration.readingCenter = Vec2(percentile(xs, 0.5), percentile(ys, 0.5))
            calibration.readingOpennessChange = percentile(opennessSamples, 0.5) - calibration.openness
            return calibration
        }
    }
}

/// Nearest-rank percentile; `p` in 0...1.
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[min(max(index, 0), sorted.count - 1)]
}
