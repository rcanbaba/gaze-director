import GazeCore
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
                if let progress = model.calibrationProgress {
                    CalibrationPrompt(progress: progress)
                }
            }
            Divider()
            sidebar
                .frame(width: 300)
        }
    }

    private var sidebar: some View {
        Form {
            Section("Calibration") {
                Button("1 · Look at the camera lens (2 s)") { model.calibrate(.camera) }
                    .disabled(model.calibrationProgress != nil)
                Button("2 · Read your text normally (8 s)") { model.calibrate(.reading) }
                    .disabled(model.calibrationProgress != nil || !model.canCalibrateReading)
                LabeledContent("Status", value: calibrationStatus)
                if let message = model.calibrationMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if model.calibration != nil {
                    Button("Reset calibration", role: .destructive) { model.resetCalibration() }
                }
            }

            Section("Behaviour") {
                Toggle("Gaze correction", isOn: $model.settings.effectEnabled)
                Picker("Mode", selection: $model.settings.talkMode) {
                    ForEach(TalkMode.allCases) { Text($0.title).tag($0) }
                }
                if model.microphoneDenied {
                    Text("Microphone access was denied.").font(.callout).foregroundStyle(.red)
                }
                Toggle("Glance away now and then", isOn: $model.settings.glancesEnabled)
                LabeledContent("Max correction") {
                    Slider(value: $model.settings.maxCorrection, in: 0.04...0.25)
                }
            }

            Section("Live") {
                GazeMap(frame: model.debugFrame)
                    .frame(height: 150)
                LabeledContent("State", value: model.debugFrame.state.rawValue)
                LabeledContent("Weight", value: model.debugFrame.weight.formatted(.number.precision(.fractionLength(2))))
                LabeledContent("Next glance", value: model.debugFrame.nextGlanceIn.map { "\($0.formatted(.number.precision(.fractionLength(1)))) s" } ?? "–")
                LabeledContent("Speaking", value: model.debugFrame.isSpeaking ? "yes" : "no")
            }

            Section("Camera") {
                Picker("Device", selection: $model.selectedCameraID) {
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                Toggle("Mirror preview", isOn: $model.settings.mirrored)
                Toggle("Debug overlay", isOn: $model.settings.showOverlay)
                LabeledContent("FPS", value: model.stats.fps.formatted(.number.precision(.fractionLength(1))))
                LabeledContent("Processing", value: "\(model.stats.processingMs.formatted(.number.precision(.fractionLength(2)))) ms")
                LabeledContent("Frame", value: "\(Int(model.stats.frameSize.width))×\(Int(model.stats.frameSize.height))")
            }
        }
        .formStyle(.grouped)
    }

    private var calibrationStatus: String {
        guard let calibration = model.calibration else { return "Not calibrated" }
        return calibration.readingZone == nil ? "Camera point only" : "Ready"
    }
}

private struct CalibrationPrompt: View {
    let progress: CalibrationProgress

    var body: some View {
        VStack(spacing: 10) {
            Text(progress.step == .camera ? "Look straight into the camera lens" : "Read your text as you would in a call")
                .font(.title3.weight(.semibold))
            ProgressView(value: progress.progress)
                .frame(width: 260)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
    }
}
