import CoreMedia
import Foundation

/// Values the camera extension and the host app must agree on. This file is compiled into both.
enum GazeCamera {
    static let name = "Gaze Director"
    static let extensionBundleIdentifier = "com.rcanbaba.GazeDirector.GazeCamera"
    /// Fixed so the host app can find the device: Core Media I/O reports it as the device UID.
    static let deviceID = UUID(uuidString: "6E2C9F0A-3B1D-4E5A-9C7B-2D8F1A4E6B30")!
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let frameRate: Int32 = 30
    static var frameDuration: CMTime { CMTime(value: 1, timescale: frameRate) }
}
