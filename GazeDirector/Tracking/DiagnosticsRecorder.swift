import AppKit
import CoreVideo
import GazeCore

/// Saves raw camera frames and per-frame measurements during calibration, so tracking can be checked
/// offline with Tools/eye-probe.sh. Files stay on this Mac, under Application Support.
final class DiagnosticsRecorder {
    static var rootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GazeDirector/Diagnostics", isDirectory: true)
    }

    /// Every Nth frame is saved as a PNG; every frame goes into measurements.jsonl.
    var imageEvery = 5

    private struct EyeRecord: Codable {
        var contour: [Vec2]
        var center: Vec2
        var width: Double
        var openness: Double
        var visionPupilUV: Vec2?
        var rawIrisUV: Vec2
        var irisUV: Vec2
        var refined: Bool
        var blinking: Bool
    }

    private struct FrameRecord: Codable {
        var frame: Int
        var time: Double
        var image: String?
        var eyes: [EyeRecord]
    }

    private let exporter: FrameExporter
    private let writeQueue = DispatchQueue(label: "gaze.diagnostics", qos: .utility)
    private var folder: URL?
    private var log: FileHandle?
    private var frameIndex = 0
    private let encoder = JSONEncoder()

    init(exporter: FrameExporter) {
        self.exporter = exporter
    }

    func begin(step: String) {
        end()
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let url = Self.rootURL.appendingPathComponent("\(stamp)-\(step)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let logURL = url.appendingPathComponent("measurements.jsonl")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: logURL)
            folder = url
            frameIndex = 0
        } catch {
            folder = nil
            log = nil
        }
    }

    func record(_ pixelBuffer: CVPixelBuffer, time: Double, eyes: [EyeMeasurement]) {
        guard let folder, let log else { return }
        defer { frameIndex += 1 }

        var imageName: String?
        if frameIndex % imageEvery == 0, let image = exporter.image(of: pixelBuffer) {
            let name = String(format: "frame-%04d.png", frameIndex)
            imageName = name
            writeQueue.async {
                FrameExporter.writePNG(image, to: folder.appendingPathComponent(name))
            }
        }

        let record = FrameRecord(frame: frameIndex, time: time, image: imageName, eyes: eyes.map {
            EyeRecord(
                contour: $0.frame.contour, center: $0.frame.center, width: $0.frame.width, openness: $0.frame.openness,
                visionPupilUV: $0.visionPupilUV, rawIrisUV: $0.rawIrisUV, irisUV: $0.irisUV,
                refined: $0.refined, blinking: $0.isBlinking
            )
        })
        if var line = try? encoder.encode(record) {
            line.append(0x0A)
            writeQueue.async { log.write(line) }
        }
    }

    func end() {
        if let log {
            writeQueue.async { try? log.close() }
        }
        log = nil
        folder = nil
    }

    static func revealInFinder() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([rootURL])
    }
}
