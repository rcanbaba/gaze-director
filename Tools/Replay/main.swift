// Replays saved calibration diagnostics through calibration, the director and the warp planner,
// to check decisions on real measurements without the camera.
//
// Usage: replay [--vision] <camera-step folder> <reading-step folder>
//   Prints how often redirection is on while looking at the camera (should be ~0%) and while
//   reading (should be ~100%), and how much the warp displacement jitters.

import Foundation
import GazeCore

/// `--vision` replays with Vision's pupil point as the iris estimate instead of the logged one.
let useVisionPupil = CommandLine.arguments.contains("--vision")

let arguments = CommandLine.arguments.filter { $0 != "--vision" }
guard arguments.count == 3 else {
    print("usage: replay [--vision] <camera-step folder> <reading-step folder>")
    exit(2)
}
let cameraFrames = loadDiagnostics(arguments[1], useVisionPupil: useVisionPupil)
let readingFrames = loadDiagnostics(arguments[2], useVisionPupil: useVisionPupil)

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
