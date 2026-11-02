import Foundation

public struct DirectorConfig: Equatable, Sendable {
    /// Seconds between glances away while you are talking.
    public var glanceIntervalSpeaking: ClosedRange<Double> = 2.0...3.5
    /// Seconds between glances away while you are listening.
    public var glanceIntervalListening: ClosedRange<Double> = 4.0...7.0
    /// How long a glance away lasts.
    public var glanceHold: ClosedRange<Double> = 0.4...1.1
    /// Glance size in uv (fraction of eye width). 0.07 is roughly 10° of eye rotation.
    public var glanceAmplitudeX: ClosedRange<Double> = 0.05...0.09
    public var glanceAmplitudeY: ClosedRange<Double> = 0.015...0.035
    public var glancesEnabled = true
    /// Tiny fixation shifts so the eyes do not look frozen on the camera.
    public var microShiftInterval: ClosedRange<Double> = 0.7...1.6
    public var microShiftAmplitude = 0.01
    /// Real saccades take tens of milliseconds; slow eye slides look uncanny.
    public var saccadeDuration = 0.05
    /// Fade between real and redirected eyes when entering or leaving the reading zone.
    public var engageDuration = 0.08
    /// Hysteresis: once engaged, the zone grows by this much.
    public var zoneMargin = 0.02
    /// Gaze must stay outside the zone this long before redirection lets go.
    public var exitDwell = 0.2
    /// Head turned further than this (radians) disables redirection.
    public var maxHeadYaw = 0.45

    public init() {}
}

public enum DirectorState: String, Sendable {
    case noFace
    case passthrough
    case engaged
    case glancing
}

public struct DirectorInput: Sendable {
    public var time: Double
    /// Gaze offset from the camera point in uv; nil when no face is tracked.
    public var gazeOffset: Vec2?
    public var isBlinking = false
    public var isSpeaking = true
    public var headYaw: Double?

    public init(time: Double, gazeOffset: Vec2?, isBlinking: Bool = false, isSpeaking: Bool = true, headYaw: Double? = nil) {
        self.time = time
        self.gazeOffset = gazeOffset
        self.isBlinking = isBlinking
        self.isSpeaking = isSpeaking
        self.headYaw = headYaw
    }
}

public struct DirectorOutput: Sendable {
    /// Where the eyes should appear to look, as an offset from the camera point in uv.
    public var target: Vec2
    /// 0 shows the real eyes, 1 shows them fully redirected.
    public var weight: Double
    public var state: DirectorState
    public var nextGlanceIn: Double?
}

/// Decides, frame by frame, where the eyes should appear to look.
///
/// While the real gaze sits inside the calibrated reading zone, the eyes are pointed at the camera
/// with small fixation shifts, and every few seconds (randomised) they glance away and come back.
/// Outside the zone, during big head turns or without a face, the real eyes pass through.
public struct GazeDirector: Sendable {
    public var config: DirectorConfig
    public var readingZone: GazeRect?

    private var rng: SplitMix64
    private var engaged = false
    private var outsideSince: Double?
    private var linearWeight = 0.0
    private var lastTime: Double?
    private var offset = Transition(value: .zero)
    private var micro = Vec2.zero
    private var glanceEnd: Double?
    private var nextGlanceAt: Double?
    private var nextMicroAt: Double?

    public init(config: DirectorConfig = DirectorConfig(), readingZone: GazeRect? = nil, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.config = config
        self.readingZone = readingZone
        self.rng = SplitMix64(seed: seed)
    }

    public mutating func update(_ input: DirectorInput) -> DirectorOutput {
        let t = input.time
        let dt = lastTime.map { max(0, t - $0) } ?? 0
        lastTime = t

        updateEngagement(input)

        let step = config.engageDuration > 0 ? dt / config.engageDuration : 1
        linearWeight = engaged ? min(1, linearWeight + step) : max(0, linearWeight - step)

        if engaged {
            updateMovements(at: t, speaking: input.isSpeaking)
        } else {
            offset = Transition(value: .zero)
            micro = .zero
            glanceEnd = nil
            nextGlanceAt = nil
            nextMicroAt = nil
        }

        let state: DirectorState
        if input.gazeOffset == nil {
            state = .noFace
        } else if !engaged {
            state = .passthrough
        } else {
            state = glanceEnd != nil ? .glancing : .engaged
        }
        return DirectorOutput(
            target: offset.value(at: t),
            weight: smoothstep(linearWeight),
            state: state,
            nextGlanceIn: nextGlanceAt.map { max(0, $0 - t) }
        )
    }

    private mutating func updateEngagement(_ input: DirectorInput) {
        let headOK = input.headYaw.map { abs($0) < config.maxHeadYaw } ?? true
        guard let gaze = input.gazeOffset, let zone = readingZone, headOK else {
            engaged = false
            outsideSince = nil
            return
        }
        // Gaze is frozen during blinks, so keep whatever was decided before the blink.
        if input.isBlinking { return }

        if engaged {
            if zone.contains(gaze, margin: config.zoneMargin) {
                outsideSince = nil
            } else {
                let since = outsideSince ?? input.time
                outsideSince = since
                if input.time - since >= config.exitDwell {
                    engaged = false
                    outsideSince = nil
                }
            }
        } else if zone.contains(gaze) {
            engaged = true
            nextMicroAt = input.time + Double.random(in: config.microShiftInterval, using: &rng)
            scheduleGlance(after: input.time, speaking: input.isSpeaking)
        }
    }

    private mutating func updateMovements(at t: Double, speaking: Bool) {
        if let end = glanceEnd {
            if t >= end {
                glanceEnd = nil
                offset.retarget(micro, at: t, duration: config.saccadeDuration)
                scheduleGlance(after: t, speaking: speaking)
            }
            return
        }

        if config.glancesEnabled {
            if nextGlanceAt == nil { scheduleGlance(after: t, speaking: speaking) }
            if let next = nextGlanceAt, t >= next {
                let hold = Double.random(in: config.glanceHold, using: &rng)
                glanceEnd = t + config.saccadeDuration + hold
                nextGlanceAt = nil
                offset.retarget(randomGlance(), at: t, duration: config.saccadeDuration)
                return
            }
        } else {
            nextGlanceAt = nil
        }

        if let next = nextMicroAt, t >= next {
            let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
            let radius = config.microShiftAmplitude * Double.random(in: 0...1, using: &rng).squareRoot()
            micro = Vec2(cos(angle), sin(angle)) * radius
            offset.retarget(micro, at: t, duration: config.saccadeDuration)
            nextMicroAt = t + Double.random(in: config.microShiftInterval, using: &rng)
        }
    }

    private mutating func scheduleGlance(after t: Double, speaking: Bool) {
        guard config.glancesEnabled else {
            nextGlanceAt = nil
            return
        }
        let interval = speaking ? config.glanceIntervalSpeaking : config.glanceIntervalListening
        nextGlanceAt = t + Double.random(in: interval, using: &rng)
    }

    /// Mostly sideways and slightly up, sometimes level or a little down, like a thinking glance.
    private mutating func randomGlance() -> Vec2 {
        let x = Double.random(in: config.glanceAmplitudeX, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
        let verticalBias: [Double] = [-1, -1, -0.5, 0, 0.6]
        let y = Double.random(in: config.glanceAmplitudeY, using: &rng) * verticalBias.randomElement(using: &rng)!
        return Vec2(x, y)
    }
}

/// Eased move between two offsets.
struct Transition: Sendable {
    var from: Vec2
    var to: Vec2
    var start: Double
    var duration: Double

    init(value: Vec2) {
        from = value
        to = value
        start = 0
        duration = 0
    }

    func value(at t: Double) -> Vec2 {
        guard duration > 0 else { return to }
        let p = smoothstep(min(1, max(0, (t - start) / duration)))
        return from + (to - from) * p
    }

    mutating func retarget(_ target: Vec2, at t: Double, duration: Double) {
        from = value(at: t)
        to = target
        start = t
        self.duration = duration
    }
}

func smoothstep(_ x: Double) -> Double {
    let c = min(1, max(0, x))
    return c * c * (3 - 2 * c)
}

/// Small seedable generator so director behaviour is reproducible in tests.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
