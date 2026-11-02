import Foundation

/// One Euro filter (Casiez et al., 2012): strong smoothing while still, little lag while moving fast.
///
/// Low lag matters here: the warp moves the iris by `target - measured`, so any lag in `measured`
/// shows up as the displayed eye briefly following a real reading saccade.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double

    private var value: Double?
    private var derivative = 0.0
    private var lastTime: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 10, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func reset() {
        value = nil
        lastTime = nil
        derivative = 0
    }

    public mutating func filter(_ x: Double, at time: Double) -> Double {
        guard let previous = value, let lastTime, time > lastTime else {
            value = x
            self.lastTime = time
            return x
        }
        let dt = time - lastTime
        let dx = (x - previous) / dt
        derivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (dx - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let filtered = previous + Self.alpha(cutoff: cutoff, dt: dt) * (x - previous)
        value = filtered
        self.lastTime = time
        return filtered
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

public struct OneEuroFilter2D: Sendable {
    private var x: OneEuroFilter
    private var y: OneEuroFilter

    public init(minCutoff: Double = 1.0, beta: Double = 10, derivativeCutoff: Double = 1.0) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    public mutating func reset() {
        x.reset()
        y.reset()
    }

    public mutating func filter(_ v: Vec2, at time: Double) -> Vec2 {
        Vec2(x.filter(v.x, at: time), y.filter(v.y, at: time))
    }
}
