import XCTest
@testable import GazeCore

final class DirectorTests: XCTestCase {
    private let zone = GazeRect(minX: -0.08, maxX: 0.08, minY: 0.02, maxY: 0.08)
    private let reading = Vec2(0.03, 0.05)
    private let frame = 1.0 / 30

    private func run(_ director: inout GazeDirector, from start: Double, seconds: Double, gaze: (Double) -> Vec2?, blinking: Bool = false, yaw: Double? = nil) -> [(Double, DirectorOutput)] {
        var outputs: [(Double, DirectorOutput)] = []
        var t = start
        while t < start + seconds {
            outputs.append((t, director.update(DirectorInput(time: t, gazeOffset: gaze(t), isBlinking: blinking, headYaw: yaw))))
            t += frame
        }
        return outputs
    }

    func testPassesThroughWithoutReadingZone() {
        var director = GazeDirector(seed: 1)
        let out = run(&director, from: 0, seconds: 1) { _ in self.reading }
        XCTAssertEqual(out.last?.1.state, .passthrough)
        XCTAssertEqual(out.last?.1.weight, 0)
    }

    func testEngagesInsideZoneAndTargetsCamera() throws {
        var config = DirectorConfig()
        config.glancesEnabled = false
        var director = GazeDirector(config: config, readingZone: zone, seed: 1)
        let out = run(&director, from: 0, seconds: 1) { _ in self.reading }
        let last = try XCTUnwrap(out.last?.1)
        XCTAssertEqual(last.state, .engaged)
        XCTAssertEqual(last.weight, 1)
        XCTAssertLessThanOrEqual(last.target.length, config.microShiftAmplitude + 1e-9)
    }

    func testShortExcursionsKeepRedirectionButRealLookAwayReleases() {
        var director = GazeDirector(readingZone: zone, seed: 2)
        _ = run(&director, from: 0, seconds: 0.5) { _ in self.reading }

        let away = Vec2(0.25, 0)
        let brief = run(&director, from: 0.5, seconds: 0.1) { _ in away }
        XCTAssertTrue(brief.allSatisfy { $0.1.state != .passthrough }, "a 100 ms excursion should not release")

        let back = run(&director, from: 0.6, seconds: 0.2) { _ in self.reading }
        XCTAssertNotEqual(back.last?.1.state, .passthrough)

        let long = run(&director, from: 0.8, seconds: 0.6) { _ in away }
        XCTAssertEqual(long.last?.1.state, .passthrough)
        XCTAssertEqual(long.last?.1.weight, 0)
    }

    func testBlinkDoesNotReleaseEvenIfGazeLooksOutside() {
        var director = GazeDirector(readingZone: zone, seed: 3)
        _ = run(&director, from: 0, seconds: 0.5) { _ in self.reading }
        let blink = run(&director, from: 0.5, seconds: 0.5, gaze: { _ in Vec2(0.3, 0.3) }, blinking: true)
        XCTAssertTrue(blink.allSatisfy { $0.1.weight > 0.99 })
    }

    func testHeadTurnDisablesRedirection() {
        var director = GazeDirector(readingZone: zone, seed: 4)
        let out = run(&director, from: 0, seconds: 0.5, gaze: { _ in self.reading }, yaw: 0.7)
        XCTAssertEqual(out.last?.1.state, .passthrough)
    }

    func testGlancesAreRandomlySpacedAndShortAndReturnToCamera() {
        let config = DirectorConfig()
        for seed in UInt64(1)...20 {
            var director = GazeDirector(config: config, readingZone: zone, seed: seed)
            let out = run(&director, from: 0, seconds: 20) { _ in self.reading }

            var starts: [Double] = []
            var ends: [Double] = []
            var previous = DirectorState.passthrough
            for (t, o) in out {
                if o.state == .glancing && previous != .glancing { starts.append(t) }
                if o.state != .glancing && previous == .glancing { ends.append(t) }
                previous = o.state
            }
            XCTAssertGreaterThanOrEqual(starts.count, 4, "seed \(seed)")

            // Spacing between the end of one glance and the start of the next follows the speaking interval.
            for (end, nextStart) in zip(ends, starts.dropFirst()) {
                let gap = nextStart - end
                XCTAssertGreaterThanOrEqual(gap, config.glanceIntervalSpeaking.lowerBound - frame, "seed \(seed)")
                XCTAssertLessThanOrEqual(gap, config.glanceIntervalSpeaking.upperBound + 2 * frame, "seed \(seed)")
            }
            for (start, end) in zip(starts, ends) {
                XCTAssertLessThanOrEqual(end - start, config.glanceHold.upperBound + config.saccadeDuration + 2 * frame)
            }

            // Mid-glance the eyes are clearly off camera; between glances they are on it.
            let glancing = out.filter { $0.1.state == .glancing }.map { $0.1.target.length }
            XCTAssertGreaterThan(glancing.max() ?? 0, config.glanceAmplitudeX.lowerBound - 1e-9)
            let engaged = out.filter { $0.1.state == .engaged && $0.0 > 0.5 }
            let settled = engaged.filter { o in !starts.contains { abs($0 - o.0) < 0.1 } && !ends.contains { abs($0 - o.0) < 0.1 } }
            XCTAssertTrue(settled.allSatisfy { $0.1.target.length <= config.microShiftAmplitude + 1e-9 }, "seed \(seed)")
        }
    }

    func testReadingCentreKeepsCameraLookOutEvenInsideAWideZone() {
        // A noisy calibration can produce a zone that also covers the camera point.
        let wide = GazeRect(minX: -0.12, maxX: 0.02, minY: -0.05, maxY: 0.05)
        let center = Vec2(-0.07, 0.01)
        var director = GazeDirector(readingZone: wide, readingCenter: center, seed: 5)

        let atCamera = run(&director, from: 0, seconds: 1) { _ in Vec2(0.005, 0) }
        XCTAssertEqual(atCamera.last?.1.state, .passthrough)

        let reading = run(&director, from: 1, seconds: 1) { _ in center }
        XCTAssertNotEqual(reading.last?.1.state, .passthrough)

        // Hysteresis: 45% of the way back to the camera keeps redirection on.
        let between = run(&director, from: 2, seconds: 1) { _ in center * 0.55 }
        XCTAssertNotEqual(between.last?.1.state, .passthrough)

        let back = run(&director, from: 3, seconds: 1) { _ in Vec2(0.005, 0) }
        XCTAssertEqual(back.last?.1.state, .passthrough)
    }

    func testReadingCentreAtTheCameraNeedsNoCorrection() {
        var director = GazeDirector(readingZone: zone, readingCenter: Vec2(0.01, 0.005), seed: 6)
        let out = run(&director, from: 0, seconds: 1) { _ in Vec2(0.01, 0.005) }
        XCTAssertEqual(out.last?.1.state, .passthrough)
    }

    func testSaccadesAreFast() {
        var transition = Transition(value: .zero)
        transition.retarget(Vec2(0.08, 0), at: 1.0, duration: 0.05)
        XCTAssertEqual(transition.value(at: 1.05).x, 0.08, accuracy: 1e-12)
        XCTAssertEqual(transition.value(at: 1.025).x, 0.04, accuracy: 1e-12)
    }
}

final class CalibrationAndWarpTests: XCTestCase {
    private func measurement(irisUV: Vec2, openness: Double = 0.36, blinking: Bool = false) -> EyeMeasurement {
        let a = 25.0, b = openness * 25
        let contour = (0..<16).map { i -> Vec2 in
            let t = Double(i) / 16 * 2 * .pi
            return Vec2(100 + a * cos(t), 100 + b * sin(t))
        }
        return EyeMeasurement(frame: EyeFrame(contour: contour)!, irisUV: irisUV, rawIrisUV: irisUV, visionPupilUV: nil, refined: true, isBlinking: blinking)
    }

    func testCameraStepTakesMedianAndReadingStepBuildsZone() throws {
        var camera = CalibrationRecorder(step: .camera, startTime: 0)
        var t = 0.0
        while !camera.isFinished(at: t) {
            let jitter = sin(t * 40) * 0.004
            camera.add([measurement(irisUV: Vec2(0.02 + jitter, 0.01)), measurement(irisUV: Vec2(-0.02 + jitter, 0.01))], at: t, base: nil)
            t += 1.0 / 30
        }
        let base = try XCTUnwrap(camera.result(base: nil))
        XCTAssertEqual(base.cameraUV[0].x, 0.02, accuracy: 0.005)
        XCTAssertEqual(base.cameraUV[1].x, -0.02, accuracy: 0.005)
        XCTAssertNil(base.readingZone)

        var reading = CalibrationRecorder(step: .reading, startTime: 10)
        t = 10
        while !reading.isFinished(at: t) {
            // Sweep left to right along a line 0.05 below the camera point.
            let sweep = (t - 10).truncatingRemainder(dividingBy: 1) * 0.12 - 0.06
            reading.add([measurement(irisUV: Vec2(0.02 + sweep, 0.06)), measurement(irisUV: Vec2(-0.02 + sweep, 0.06))], at: t, base: base)
            t += 1.0 / 30
        }
        let zone = try XCTUnwrap(reading.result(base: base)?.readingZone)
        XCTAssertTrue(zone.contains(Vec2(0, 0.05)))
        XCTAssertTrue(zone.contains(Vec2(-0.05, 0.05)))
        XCTAssertFalse(zone.contains(Vec2(0, -0.05)), "looking above the camera is not reading")
    }

    func testWarpMovesIrisToCameraAndRespectsCap() throws {
        let calibration = Calibration(cameraUV: [Vec2(0, 0), Vec2(0, 0)], openness: 0.36)
        let eyes = [measurement(irisUV: Vec2(0.05, 0.04)), measurement(irisUV: Vec2(0.05, 0.04))]
        let full = DirectorOutput(target: .zero, weight: 1, state: .engaged)

        let warps = WarpPlanner.plan(eyes: eyes, calibration: calibration, output: full, maxDisplacement: 0.16)
        XCTAssertEqual(warps.count, 2)
        // Eye is 50 px wide: (-0.05, -0.04) uv is (-2.5, -2) px.
        XCTAssertEqual(warps[0].displacement.x, -2.5, accuracy: 1e-9)
        XCTAssertEqual(warps[0].displacement.y, -2.0, accuracy: 1e-9)
        XCTAssertEqual(warps[0].irisRadius, 10, accuracy: 1e-9)

        let capped = WarpPlanner.plan(eyes: eyes, calibration: calibration, output: full, maxDisplacement: 0.02)
        XCTAssertEqual(capped[0].displacement.length, 1.0, accuracy: 1e-9)

        let off = DirectorOutput(target: .zero, weight: 0, state: .passthrough)
        XCTAssertTrue(WarpPlanner.plan(eyes: eyes, calibration: calibration, output: off, maxDisplacement: 0.16).isEmpty)
    }

    func testVerticalOffsetComesFromEyeOpeningWhenThatIsTheLargerSignal() throws {
        // Eyes open 0.06 wider while reading: the reading spot is above the lens.
        var calibration = Calibration(cameraUV: [.zero, .zero], openness: 0.29, readingCenter: Vec2(-0.05, -0.03), readingOpennessChange: 0.06)
        let offset = try XCTUnwrap(calibration.readingOffset)
        XCTAssertEqual(offset.x, -0.05, accuracy: 1e-12)
        XCTAssertEqual(offset.y, -0.06, accuracy: 1e-12)

        calibration.readingOpennessChange = 0.01
        XCTAssertEqual(try XCTUnwrap(calibration.readingOffset).y, -0.03, accuracy: 1e-12)

        let full = DirectorOutput(target: .zero, weight: 1, state: .engaged)
        calibration.readingOpennessChange = 0.06
        let warps = WarpPlanner.plan(eyes: [measurement(irisUV: .zero), measurement(irisUV: .zero)], calibration: calibration, output: full, maxDisplacement: 0.5, strength: 2)
        XCTAssertEqual(warps[0].displacement.x, 5, accuracy: 1e-9)
        XCTAssertEqual(warps[0].displacement.y, 6, accuracy: 1e-9)
    }

    func testWarpUsesFixedReadingOffsetSoIrisJitterDoesNotLeakIn() {
        let calibration = Calibration(cameraUV: [Vec2(0, 0), Vec2(0, 0)], openness: 0.36, readingCenter: Vec2(-0.07, 0.02))
        let full = DirectorOutput(target: .zero, weight: 1, state: .engaged)
        let displacements = [Vec2(-0.05, 0.03), Vec2(-0.09, 0.01), Vec2(-0.07, 0.02)].map { iris in
            WarpPlanner.plan(eyes: [measurement(irisUV: iris), measurement(irisUV: iris)], calibration: calibration, output: full, maxDisplacement: 0.16)[0].displacement
        }
        for d in displacements {
            XCTAssertEqual(d.x, 3.5, accuracy: 1e-9)
            XCTAssertEqual(d.y, -1.0, accuracy: 1e-9)
        }

        // Full follow tracks the measured iris instead.
        let tracked = WarpPlanner.plan(eyes: [measurement(irisUV: Vec2(-0.05, 0.03)), measurement(irisUV: Vec2(-0.05, 0.03))], calibration: calibration, output: full, maxDisplacement: 0.16, follow: 1)
        XCTAssertEqual(tracked[0].displacement.x, 2.5, accuracy: 1e-9)
        XCTAssertEqual(tracked[0].displacement.y, -1.5, accuracy: 1e-9)
    }
}
