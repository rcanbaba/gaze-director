import Foundation
import SystemExtensions

/// Installs or removes the embedded camera extension. macOS asks the user to approve it once in
/// System Settings, and only allows it from an app in /Applications.
final class CameraExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    /// Human-readable progress, delivered on the main queue.
    var onStatus: ((String) -> Void)?

    var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    func install() {
        guard isInApplicationsFolder else {
            onStatus?("Move Gaze Director to /Applications and open it from there first.")
            return
        }
        submit(.activationRequest(forExtensionWithIdentifier: GazeCamera.extensionBundleIdentifier, queue: .main))
    }

    func uninstall() {
        submit(.deactivationRequest(forExtensionWithIdentifier: GazeCamera.extensionBundleIdentifier, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onStatus?("Approve it in System Settings → General → Login Items & Extensions → Camera Extensions.")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            onStatus?("Ready. Pick “\(GazeCamera.name)” as the camera in FaceTime, Photo Booth, Teams or Meet.")
        case .willCompleteAfterReboot:
            onStatus?("Finishes after a restart.")
        @unknown default:
            onStatus?("Done.")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        onStatus?("Failed: \(error.localizedDescription)")
    }
}
