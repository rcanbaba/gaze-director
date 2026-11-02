// Reading the app's calibration diagnostics (measurements.jsonl) back into GazeCore types.
// Shared by the replay and warp-frame tools.

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

/// Frames with both eyes, or an empty eye list. With `useVisionPupil` the iris estimate is replaced
/// by Vision's pupil point, so sessions recorded with the gradient locator can be compared.
func loadDiagnostics(_ folder: String, useVisionPupil: Bool) -> [(Double, [EyeMeasurement])] {
    let url = URL(fileURLWithPath: folder).appendingPathComponent("measurements.jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        print("cannot read \(url.path)")
        exit(1)
    }
    return text.split(separator: "\n").compactMap { line in
        guard let record = try? JSONDecoder().decode(FrameRecord.self, from: Data(line.utf8)) else { return nil }
        let eyes = record.eyes.compactMap { e -> EyeMeasurement? in
            guard let frame = EyeFrame(contour: e.contour) else { return nil }
            let iris = useVisionPupil ? (e.visionPupilUV ?? e.irisUV) : e.irisUV
            return EyeMeasurement(frame: frame, irisUV: iris, rawIrisUV: e.rawIrisUV, visionPupilUV: e.visionPupilUV, refined: e.refined, isBlinking: e.blinking)
        }
        return (record.time, eyes.count == 2 ? eyes : [])
    }
}

func calibrate(_ step: CalibrationRecorder.Step, _ frames: [(Double, [EyeMeasurement])], base: Calibration?) -> Calibration? {
    guard let start = frames.first?.0 else { return nil }
    var recorder = CalibrationRecorder(step: step, startTime: start)
    for (t, eyes) in frames { recorder.add(eyes, at: t, base: base) }
    return recorder.result(base: base)
}

/// Runs both calibration steps from a pair of diagnostics folders.
func calibration(cameraFolder: String, readingFolder: String, useVisionPupil: Bool) -> Calibration? {
    let camera = calibrate(.camera, loadDiagnostics(cameraFolder, useVisionPupil: useVisionPupil), base: nil)
    return calibrate(.reading, loadDiagnostics(readingFolder, useVisionPupil: useVisionPupil), base: camera)
}
