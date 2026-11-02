// Compares iris estimators on saved calibration frames: Vision's pupil, the gradient locator, and
// the gradient locator with reflection removal. For each folder it prints the median and the
// p5–p95 spread per eye; for a camera/reading pair it prints the reading shift each one sees.
//
// Usage: estimators <camera-step folder> <reading-step folder>

import CoreVideo
import Foundation
import GazeCore

struct Estimates {
    var vision: [[Vec2]] = [[], []]
    var gradient: [[Vec2]] = [[], []]
    var cleaned: [[Vec2]] = [[], []]
}

func estimate(folder: String) -> Estimates {
    var result = Estimates()
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".png") }.sorted() ?? []
    // Skip the first half second while the eyes settle, as calibration does.
    for file in files.dropFirst(3) {
        let frame = loadFrame(folder + "/" + file)
        guard let face = FaceTracker().detect(in: frame) else { continue }
        let layout = EyeCropLayout()
        LumaSampler.withSampler(frame) { luma in
            for (i, eye) in face.eyes.enumerated() {
                guard let eyeFrame = EyeFrame(contour: eye.contour), eyeFrame.openness > 0.2 else { continue }
                if let pupil = eye.pupil { result.vision[i].append(eyeFrame.uv(of: pupil)) }
                let crop = layout.crop(eyeFrame) { luma($0) }
                if let p = IrisLocator.locate(in: crop.image, mask: crop.mask, highlightRadius: 0) { result.gradient[i].append(layout.uv(x: p.x, y: p.y)) }
                if let p = IrisLocator.locate(in: crop.image, mask: crop.mask) { result.cleaned[i].append(layout.uv(x: p.x, y: p.y)) }
            }
        }
    }
    return result
}

func median(_ values: [Double]) -> Double {
    values.isEmpty ? .nan : values.sorted()[values.count / 2]
}

func spread(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let s = values.sorted()
    return s[Int(Double(s.count - 1) * 0.95)] - s[Int(Double(s.count - 1) * 0.05)]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: estimators <camera-step folder> <reading-step folder>")
    exit(2)
}
let camera = estimate(folder: arguments[1])
let reading = estimate(folder: arguments[2])

for (name, pick) in [("vision", \Estimates.vision), ("gradient", \Estimates.gradient), ("gradient, reflections removed", \Estimates.cleaned)] {
    print("== \(name)")
    for eye in 0..<2 {
        let c = camera[keyPath: pick][eye], r = reading[keyPath: pick][eye]
        print(String(format: "  eye %d: camera spread u %.3f v %.3f | reading shift u %+.3f v %+.3f  (n %d/%d)",
                     eye, spread(c.map(\.x)), spread(c.map(\.y)),
                     median(r.map(\.x)) - median(c.map(\.x)), median(r.map(\.y)) - median(c.map(\.y)), c.count, r.count))
    }
}
