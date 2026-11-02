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
                } else {
                    statusBadge
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if model.settings.eyeZoom, !model.eyeZoom.original.isEmpty {
                    EyeZoomPanel(zoom: model.eyeZoom, mirrored: model.settings.mirrored)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Divider()
            sidebar
                .frame(width: 300)
        }
    }

    /// Whether the correction is running right now. It switches off while you look at this window,
    /// since that is outside the reading zone; record a clip to see it while reading.
    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            if !model.isCalibrated { return ("Correction OFF: calibrate first", .red) }
            if !model.settings.effectEnabled { return ("Correction disabled", .gray) }
            switch model.debugFrame.state {
            case .engaged, .glancing: return ("Correcting", .green)
            case .passthrough: return ("Not reading: real eyes shown", .orange)
            case .noFace: return ("No face", .gray)
            }
        }()
        return Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.85), in: Capsule())
    }

    private func tintButton(_ tint: Tint, title: String, color: Color) -> some View {
        let active = model.settings.tint == tint
        return Button(active ? "\(title) ✓" : title) {
            model.settings.tint = active ? .none : tint
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? color : .gray)
    }

    private var sidebar: some View {
        Form {
            Section("Gifts") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(model.gifts.enumerated()), id: \.element.id) { index, gift in
                        Button {
                            model.playGift(at: index)
                        } label: {
                            VStack(spacing: 1) {
                                Text(gift.name).lineLimit(1)
                                if index < 9 {
                                    Text("⌃⌥\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                HStack {
                    Button("Open gifts folder") { model.openGiftsFolder() }
                    Button("Reload") { model.reloadGifts() }
                }
                Text("⌃⌥1–9 work while Teams, Meet or FaceTime is in front. Add side-by-side alpha videos (colour left, mask right) to the gifts folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test filter") {
                HStack {
                    tintButton(.red, title: "Red", color: .red)
                    tintButton(.green, title: "Green", color: .green)
                }
                Text("Tints what the Gaze Director camera sends. Press again to remove.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calibration") {
                Button("Calibrate: lens 2 s, chime, read 8 s") { model.calibrateFully() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.calibrationProgress != nil)
                Button("Redo reading step only (8 s)") { model.calibrate(.reading) }
                    .disabled(model.calibrationProgress != nil || !model.canCalibrateReading)
                LabeledContent("Status", value: calibrationStatus)
                if let message = model.calibrationMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if model.calibration != nil {
                    Button("Reset calibration", role: .destructive) { model.resetCalibration() }
                }
                Toggle("Save calibration frames (local, for debugging)", isOn: $model.settings.saveDiagnostics)
                Button("Show saved frames in Finder") { DiagnosticsRecorder.revealInFinder() }
            }

            Section("Behaviour") {
                Toggle("Gaze correction", isOn: $model.settings.effectEnabled)
                Picker("Mode", selection: $model.settings.talkMode) {
                    ForEach(TalkMode.allCases) { Text($0.title).tag($0) }
                }
                if model.microphoneDenied {
                    Text("Microphone access was denied.").font(.callout).foregroundStyle(.red)
                }
                Picker("Iris source", selection: $model.settings.irisSource) {
                    Text("Gradient locator").tag(IrisSource.gradient)
                    Text("Vision pupil (steady, under-reads)").tag(IrisSource.vision)
                }
                Toggle("Glance away now and then", isOn: $model.settings.glancesEnabled)
                LabeledContent("Strength \(model.settings.correctionStrength.formatted(.number.precision(.fractionLength(1))))×") {
                    Slider(value: $model.settings.correctionStrength, in: 0.5...2.5)
                }
                LabeledContent("Max correction") {
                    Slider(value: $model.settings.maxCorrection, in: 0.04...0.25)
                }
                LabeledContent("Follow reading motion") {
                    Slider(value: $model.settings.followReading, in: 0...1)
                }
                Text("0 = fixed correction only. Higher also cancels the left-right reading sweep, with a little more jitter and stretching at line ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Virtual camera") {
                LabeledContent("Status", value: model.virtualCameraConnected ? "Sending to “Gaze Director” camera" : "Extension not connected")
                Button("Install camera extension") { model.installCameraExtension() }
                if let status = model.extensionStatus {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                Text("Pick “Gaze Director” as the camera in FaceTime, Photo Booth, Teams, Zoom or the browser. Keep this app open; it does the processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove camera extension", role: .destructive) { model.uninstallCameraExtension() }
            }

            Section("Before / after clip") {
                Button("Record 15 s clip, then read normally") { model.recordClip() }
                    .disabled(model.clipProgress != nil)
                if let progress = model.clipProgress {
                    ProgressView(value: progress)
                }
                Text("Saves original | corrected side by side to Movies/GazeDirector and opens it. A green square marks frames being corrected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.clipFailed {
                    Text("Could not record the clip.").font(.callout).foregroundStyle(.red)
                }
                if let url = model.lastClipURL {
                    Button("Show last clip in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
                Toggle("Eye zoom", isOn: $model.settings.eyeZoom)
                LabeledContent("FPS", value: model.stats.fps.formatted(.number.precision(.fractionLength(1))))
                LabeledContent("Processing", value: "\(model.stats.processingMs.formatted(.number.precision(.fractionLength(2)))) ms")
                LabeledContent("Frame", value: "\(Int(model.stats.frameSize.width))×\(Int(model.stats.frameSize.height))")
            }
        }
        .formStyle(.grouped)
    }

    private var calibrationStatus: String {
        guard let calibration = model.calibration else { return "Not calibrated" }
        if calibration.readingZone == nil { return "Camera point only" }
        return calibration.readingCenter == nil || calibration.readingOpennessChange == nil ? "Redo step 2" : "Ready"
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
