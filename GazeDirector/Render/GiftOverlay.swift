import AVFoundation
import CoreImage
import CoreVideo

/// A gift video: colour on the left half (premultiplied over black), alpha mask as grey on the
/// right half — the layout live-stream gift effects use.
struct GiftItem: Identifiable, Hashable {
    let url: URL
    let name: String
    var id: URL { url }

    init(url: URL) {
        self.url = url
        // "4-Teddy-Bear.mp4" → "Teddy Bear"
        let base = url.deletingPathExtension().lastPathComponent
        let trimmed = base.drop { $0.isNumber }.drop { $0 == "-" || $0 == "_" || $0 == " " }
        name = (trimmed.isEmpty ? base : String(trimmed))
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Demo gifts shipped with the app, then any the user drops into ~/Movies/GazeDirector/Gifts.
    static func all() -> [GiftItem] {
        let bundled = (Bundle.main.urls(forResourcesWithExtension: "mp4", subdirectory: "Gifts") ?? [])
        let user = (try? FileManager.default.contentsOfDirectory(at: userFolder, includingPropertiesForKeys: nil)) ?? []
        let videos = user.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
        let byName = { (a: URL, b: URL) in a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending }
        return (bundled.sorted(by: byName) + videos.sorted(by: byName)).map(GiftItem.init)
    }

    static var userFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GazeDirector/Gifts", isDirectory: true)
    }
}

/// Plays one gift; frames are pulled by host time from the frame queue.
final class GiftPlayback: @unchecked Sendable {
    let name: String
    private let player: AVPlayer
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    private let ended = Locked(false)
    private var observer: NSObjectProtocol?
    private var lastFrame: CVPixelBuffer?

    init(_ gift: GiftItem) {
        name = gift.name
        let item = AVPlayerItem(url: gift.url)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { [ended] _ in
            ended.set(true)
        }
        player.play()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isFinished: Bool { ended.get() || player.currentItem?.status == .failed }

    /// The gift frame for now, or the previous one if no new frame is due yet.
    func frame(atHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            lastFrame = buffer
        }
        return lastFrame
    }
}

/// Puts a gift frame over a camera frame with the mask as alpha, centred.
final class GiftCompositor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    func composite(gift: CVPixelBuffer, over frame: CVPixelBuffer) -> CVPixelBuffer {
        let giftImage = CIImage(cvPixelBuffer: gift)
        let halfWidth = giftImage.extent.width / 2, giftHeight = giftImage.extent.height
        let colour = giftImage.cropped(to: CGRect(x: 0, y: 0, width: halfWidth, height: giftHeight))
        let mask = giftImage.cropped(to: CGRect(x: halfWidth, y: 0, width: halfWidth, height: giftHeight))
            .transformed(by: CGAffineTransform(translationX: -halfWidth, y: 0))

        let frameImage = CIImage(cvPixelBuffer: frame)
        let bounds = frameImage.extent
        // Landscape gifts (text banners) cover the whole frame; portrait ones fit its height.
        let scale = halfWidth > giftHeight
            ? min(bounds.width / halfWidth, bounds.height / giftHeight)
            : min(bounds.height * 0.95 / giftHeight, bounds.width * 0.9 / halfWidth)
        let place = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: (bounds.width - halfWidth * scale) / 2,
            y: (bounds.height - giftHeight * scale) / 2
        ))

        // Video compression lifts black to a few percent grey, which would wash out the whole gift
        // rectangle; push the mask floor back to zero before blending.
        let floor: CGFloat = 0.08
        let cleanMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / (1 - 2 * floor), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 / (1 - 2 * floor), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 / (1 - 2 * floor), w: 0),
            "inputBiasVector": CIVector(x: -floor / (1 - 2 * floor), y: -floor / (1 - 2 * floor), z: -floor / (1 - 2 * floor), w: 0),
        ]).applyingFilter("CIColorClamp")

        // Gift colour is premultiplied over black, so the exact blend is colour + camera × (1 − mask).
        // But renders often leave a faint coloured haze where the mask is ~0, and adding it washes
        // out the whole gift area. Weighting colour by a boosted mask drops the haze where the gift
        // is clear while keeping glows (mask 0.1–0.3) far brighter than a plain mask blend would.
        let placedMask = cleanMask.transformed(by: place)
        let colourWeight = placedMask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 3, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 3, w: 0),
        ]).applyingFilter("CIColorClamp")
        let weightedColour = colour.transformed(by: place)
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: colourWeight])
        let cameraPart = CIImage(color: .black).cropped(to: bounds).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: frameImage,
            kCIInputMaskImageKey: placedMask,
        ])
        // CIAdditionCompositing adds alpha too; alpha 2 washes the rendered area out, so reset it.
        let result = weightedColour
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: cameraPart])
            .settingAlphaOne(in: bounds)
            .cropped(to: bounds)

        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        guard let output = makeBuffer(width: width, height: height) else { return frame }
        context.render(result, to: output)
        CVBufferPropagateAttachments(frame, output)
        return output
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
