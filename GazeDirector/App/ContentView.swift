import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                VideoPreview(display: model.display, mirrored: model.settings.mirrored)
                if model.settings.showOverlay {
                    DebugOverlay(frame: model.debugFrame, mirrored: model.settings.mirrored)
                }
                if model.cameraDenied {
                    Text("Camera access was denied. Allow it in System Settings → Privacy & Security → Camera.")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Divider()
            sidebar
                .frame(width: 280)
        }
    }

    private var sidebar: some View {
        Form {
            Section("Camera") {
                Picker("Device", selection: $model.selectedCameraID) {
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                Toggle("Mirror preview", isOn: $model.settings.mirrored)
            }
            Section("Effect") {
                Toggle("Gaze correction", isOn: $model.settings.effectEnabled)
                Toggle("Debug overlay", isOn: $model.settings.showOverlay)
            }
            Section("Stats") {
                LabeledContent("FPS", value: model.stats.fps.formatted(.number.precision(.fractionLength(1))))
                LabeledContent("Processing", value: "\(model.stats.processingMs.formatted(.number.precision(.fractionLength(2)))) ms")
                LabeledContent("Frame", value: "\(Int(model.stats.frameSize.width))×\(Int(model.stats.frameSize.height))")
            }
        }
        .formStyle(.grouped)
    }
}
