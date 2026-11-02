import XCTest
@testable import GazeCore

final class TrackingTests: XCTestCase {
    private func ellipseContour(center: Vec2, a: Double, b: Double, angle: Double, count: Int = 16) -> [Vec2] {
        let axis = Vec2(cos(angle), sin(angle))
        return (0..<count).map { i in
            let t = Double(i) / Double(count) * 2 * .pi
            return center + axis * (a * cos(t)) + axis.perpendicular * (b * sin(t))
        }
    }

    func testEyeFrameAxesAndRoundTrip() throws {
        let angle = 10.0 * .pi / 180
        let contour = ellipseContour(center: Vec2(200, 120), a: 25, b: 9, angle: angle)
        let eye = try XCTUnwrap(EyeFrame(contour: contour))

        XCTAssertEqual(eye.width, 50, accuracy: 0.01)
        XCTAssertEqual(eye.center.x, 200, accuracy: 0.01)
        XCTAssertEqual(eye.center.y, 120, accuracy: 0.01)
        XCTAssertEqual(atan2(eye.xAxis.y, eye.xAxis.x), angle, accuracy: 1e-6)
        XCTAssertEqual(eye.openness, 18.0 / 50.0, accuracy: 0.02)

        let p = Vec2(207, 116)
        let back = eye.point(at: eye.uv(of: p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
    }

    func testPolygonContains() {
        let square = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        XCTAssertTrue(polygonContains(square, Vec2(5, 5)))
        XCTAssertFalse(polygonContains(square, Vec2(11, 5)))
    }

    /// Synthetic eye crop: bright sclera inside an elliptical opening, skin outside, a dark iris disk.
    private func syntheticCrop(iris: Vec2, radius: Double) -> (GrayImage, [Bool]) {
        let w = 48, h = 24
        var pixels = [Float](repeating: 0, count: w * h)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let px = Double(x), py = Double(y)
                let ex = (px - 24) / 21, ey = (py - 12) / 8
                let inEye = ex * ex + ey * ey <= 1
                let inIris = (Vec2(px, py) - iris).length <= radius
                pixels[y * w + x] = inEye ? (inIris ? 0.18 : 0.85) : 0.55
                mask[y * w + x] = inEye
            }
        }
        return (GrayImage(width: w, height: h, pixels: pixels), mask)
    }

    func testIrisLocatorFindsDarkDisk() throws {
        for truth in [Vec2(24, 12), Vec2(17, 11), Vec2(31, 13)] {
            let (image, mask) = syntheticCrop(iris: truth, radius: 7)
            let found = try XCTUnwrap(IrisLocator.locate(in: image, mask: mask))
            XCTAssertLessThan((found - truth).length, 1.0, "expected \(truth), got \(found)")
        }
    }

    func testIrisLocatorIgnoresReflectionInThePupil() throws {
        let truth = Vec2(22, 12)
        let (clean, mask) = syntheticCrop(iris: truth, radius: 7)
        var image = clean
        // A bright 3×3 screen reflection just off the centre, as on dark irises close to a display.
        for y in 10...12 { for x in 24...26 { image.pixels[y * image.width + x] = 0.95 } }

        let cleaned = try XCTUnwrap(IrisLocator.locate(in: image, mask: mask))
        XCTAssertLessThan((cleaned - truth).length, 1.0, "got \(cleaned)")
        let unfiltered = try XCTUnwrap(IrisLocator.locate(in: image, mask: mask, highlightRadius: 0))
        XCTAssertGreaterThan((unfiltered - truth).length, (cleaned - truth).length)
    }

    func testIrisLocatorRejectsFlatCrop() {
        let image = GrayImage(width: 48, height: 24, pixels: .init(repeating: 0.5, count: 48 * 24))
        XCTAssertNil(IrisLocator.locate(in: image, mask: .init(repeating: true, count: 48 * 24)))
    }

    func testOneEuroSmoothsJitterButFollowsJumps() {
        var filter = OneEuroFilter(minCutoff: 1, beta: 10)
        var t = 0.0
        var out = 0.0
        for i in 0..<60 {
            out = filter.filter(i.isMultiple(of: 2) ? 0.005 : -0.005, at: t)
            t += 1.0 / 30
        }
        XCTAssertLessThan(abs(out), 0.004)

        for _ in 0..<3 {
            out = filter.filter(0.1, at: t)
            t += 1.0 / 30
        }
        XCTAssertGreaterThan(out, 0.08, "should catch up with a saccade within a few frames")
    }

    func testEyeTrackerUsesChosenIrisSource() throws {
        let contour = ellipseContour(center: Vec2(100, 100), a: 25, b: 9, angle: 0)
        let disk = Vec2(100, 100)
        let hint = Vec2(105, 100)  // Vision's pupil, 0.1 eye widths off the dark disk
        let luma: (Vec2) -> Float = { p in (p - disk).length < 10 ? 0.15 : 0.85 }

        var vision = EyeTracker()
        vision.source = .vision
        let fromVision = try XCTUnwrap(vision.update(contour: contour, pupil: hint, time: 0, luma: luma))
        XCTAssertEqual(fromVision.rawIrisUV.x, 0.1, accuracy: 1e-9)
        XCTAssertFalse(fromVision.refined)
        XCTAssertEqual(try XCTUnwrap(fromVision.gradientUV).x, 0, accuracy: 0.03)

        var gradient = EyeTracker()
        gradient.source = .gradient
        let fromGradient = try XCTUnwrap(gradient.update(contour: contour, pupil: hint, time: 0, luma: luma))
        XCTAssertEqual(fromGradient.rawIrisUV.x, 0, accuracy: 0.03)
        XCTAssertTrue(fromGradient.refined)
    }

    func testEyeTrackerFreezesIrisDuringBlink() throws {
        var tracker = EyeTracker()
        let open = ellipseContour(center: Vec2(100, 100), a: 25, b: 9, angle: 0)
        let closed = ellipseContour(center: Vec2(100, 100), a: 25, b: 2, angle: 0)
        let pupil = Vec2(104, 100)
        let luma: (Vec2) -> Float = { p in (p - pupil).length < 10 ? 0.15 : 0.85 }

        let first = try XCTUnwrap(tracker.update(contour: open, pupil: pupil, time: 0, luma: luma))
        XCTAssertFalse(first.isBlinking)

        let blink = try XCTUnwrap(tracker.update(contour: closed, pupil: Vec2(80, 100), time: 0.033, luma: { _ in 0.5 }))
        XCTAssertTrue(blink.isBlinking)
        XCTAssertEqual(blink.irisUV, first.irisUV)
    }
}
