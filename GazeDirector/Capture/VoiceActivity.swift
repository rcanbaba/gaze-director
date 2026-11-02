import AVFoundation
import QuartzCore

/// Very small voice activity detector: microphone level above a threshold, with a hangover so pauses
/// between words still count as speaking.
final class VoiceActivity: @unchecked Sendable {
    var thresholdDB: Float = -42
    var hangover: Double = 0.6

    private let engine = AVAudioEngine()
    private let speaking = Locked(false)
    private let levelDB = Locked<Float>(-120)
    private var lastLoud = 0.0
    private var running = false

    var isSpeaking: Bool { speaking.get() }
    var level: Float { levelDB.get() }

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        speaking.set(false)
        levelDB.set(-120)
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += samples[i] * samples[i]
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        let now = CACurrentMediaTime()
        if db > thresholdDB { lastLoud = now }
        levelDB.set(db)
        speaking.set(now - lastLoud < hangover)
    }
}
