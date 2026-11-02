// Replays saved calibration diagnostics through calibration, the director and the warp planner,
// to check decisions on real measurements without the camera.
//
// Usage: replay <camera-step folder> <reading-step folder>
//   Prints how often redirection is on while looking at the camera (should be ~0%) and while
//   reading (should be ~100%), and how much the warp displacement jitters.

import Foundation
import GazeCore

struct EyeRecord: Decodable {
    var contour: [Vec2]
    var rawIrisUV: Vec2
    var irisUV: Vec2
    var visionPupilUV: Vec2?
    var refined: Bool
    var blinking: Bool
}

struct FrameRecord: Decodable {
    var time: Double
    var eyes: [EyeRecord]
}

func load(_ folder: String) -> [(Double, [EyeMeasurement])] {
    let url = URL(fileURLWithPath: folder).appendingPathComponent("measurements.jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        print("cannot read \(url.path)")
        exit(1)
    }
    return text.split(separator: "\n").compactMap { line in
        guard let record = try? JSONDecoder().decode(FrameRecord.self, from: Data(line.utf8)) else { return nil }
        let eyes = record.eyes.compactMap { e -> EyeMeasurement? in
            guard let frame = EyeFrame(contour: e.contour) else { return nil }
            return EyeMeasurement(frame: frame, irisUV: e.irisUV, rawIrisUV: e.rawIrisUV, visionPupilUV: e.visionPupilUV, refined: e.refined, isBlinking: e.blinking)
        }
        return (record.time, eyes.count == 2 ? eyes : [])
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: replay <camera-step folder> <reading-step folder>")
    exit(2)
}
let cameraFrames = load(arguments[1])
let readingFrames = load(arguments[2])

func calibrate(_ step: CalibrationRecorder.Step, _ frames: [(Double, [EyeMeasurement])], base: Calibration?) -> Calibration? {
    guard let start = frames.first?.0 else { return nil }
    var recorder = CalibrationRecorder(step: step, startTime: start)
    for (t, eyes) in frames { recorder.add(eyes, at: t, base: base) }
    return recorder.result(base: base)
}

guard let cameraCalibration = calibrate(.camera, cameraFrames, base: nil),
      let calibration = calibrate(.reading, readingFrames, base: cameraCalibration),
      let zone = calibration.readingZone, let center = calibration.readingCenter else {
    print("calibration failed")
    exit(1)
}
print(String(format: "reading centre (%+.3f, %+.3f) uv, zone x [%+.3f, %+.3f] y [%+.3f, %+.3f]",
             center.x, center.y, zone.minX, zone.maxX, zone.minY, zone.maxY))

var config = DirectorConfig()
config.glancesEnabled = false
config.microShiftAmplitude = 0

for (label, useCenter) in [("zone only (before)", false), ("zone + reading centre (now)", true)] {
    var director = GazeDirector(config: config, readingZone: zone, readingCenter: useCenter ? center : nil, seed: 1)
    // Reading frames are replayed right after the camera frames, as in a real session.
    let offset = (cameraFrames.last?.0 ?? 0) + 1 / 30 - (readingFrames.first?.0 ?? 0)
    for (name, frames, shift) in [("camera", cameraFrames, 0.0), ("reading", readingFrames, offset)] {
        var engaged = 0, total = 0
        var displacements: [Double] = []
        for (t, eyes) in frames {
            let gaze = eyes.isEmpty ? nil : calibration.gazeOffset(irisUV: eyes.map(\.irisUV))
            let out = director.update(DirectorInput(time: t + shift, gazeOffset: gaze, isBlinking: eyes.contains(where: \.isBlinking)))
            total += 1
            if out.weight > 0.5 { engaged += 1 }
            let warps = WarpPlanner.plan(eyes: eyes, calibration: useCenter ? calibration : Calibration(cameraUV: calibration.cameraUV, openness: calibration.openness), output: out, maxDisplacement: 0.16)
            if out.weight > 0.99, let first = warps.first { displacements.append(first.displacement.x) }
        }
        let sorted = displacements.sorted()
        let spread = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)] - sorted[Int(Double(sorted.count - 1) * 0.05)]
        print(String(format: "%@ – %@: redirected %3.0f%% of frames, horizontal displacement p5–p95 spread %.1f px",
                     label, name, Double(engaged) / Double(max(total, 1)) * 100, spread))
    }
}
