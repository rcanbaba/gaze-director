import CoreGraphics
import SwiftUI

/// Both eyes, magnified, before and after the warp. Images are ordered image-left then image-right.
struct EyeZoom {
    var original: [CGImage] = []
    var corrected: [CGImage] = []
    var warped = false
}

struct EyeZoomPanel: View {
    let zoom: EyeZoom
    let mirrored: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            row("Original", zoom.original)
            row(zoom.warped ? "Corrected" : "Corrected (idle)", zoom.corrected)
        }
        .padding(8)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ title: String, _ images: [CGImage]) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 64, alignment: .leading)
            // A mirrored preview shows the image-right eye on the left.
            ForEach(Array((mirrored ? images.reversed() : images).enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 180)
                    .scaleEffect(x: mirrored ? -1 : 1)
            }
        }
    }
}
