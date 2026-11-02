import CoreVideo
import GazeCore
import Vision

struct FaceLandmarks {
    struct Eye {
        let contour: [Vec2]
        let pupil: Vec2?
    }

    /// Exactly two eyes, ordered image-left then image-right.
    let eyes: [Eye]
    /// Head yaw in radians when Vision reports it.
    let yaw: Double?
}

/// Runs Vision face landmarks on each frame and converts the eyes to top-left-origin pixel coordinates.
final class FaceTracker {
    private let handler = VNSequenceRequestHandler()
    private let request: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()

    func detect(in pixelBuffer: CVPixelBuffer) -> FaceLandmarks? {
        do {
            try handler.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            return nil
        }
        let largest = request.results?.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        guard let face = largest, let landmarks = face.landmarks else { return nil }

        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        func points(_ region: VNFaceLandmarkRegion2D?) -> [Vec2] {
            region?.pointsInImage(imageSize: size).map { Vec2(Double($0.x), height - Double($0.y)) } ?? []
        }

        var eyes = [
            FaceLandmarks.Eye(contour: points(landmarks.leftEye), pupil: points(landmarks.leftPupil).first),
            FaceLandmarks.Eye(contour: points(landmarks.rightEye), pupil: points(landmarks.rightPupil).first),
        ]
        guard eyes.allSatisfy({ $0.contour.count >= 4 }) else { return nil }
        eyes.sort { mean($0.contour).x < mean($1.contour).x }
        return FaceLandmarks(eyes: eyes, yaw: face.yaw?.doubleValue)
    }

    private func mean(_ points: [Vec2]) -> Vec2 {
        points.reduce(.zero, +) / Double(points.count)
    }
}
