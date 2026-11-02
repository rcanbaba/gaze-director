import SwiftUI

/// Draws tracking state over the preview. Uses the same aspect-fit and mirroring as the video layer.
struct DebugOverlay: View {
    let frame: DebugFrame
    let mirrored: Bool

    var body: some View {
        Canvas { context, size in
            let image = frame.imageSize
            guard image.width > 0, image.height > 0 else { return }
            let scale = min(size.width / image.width, size.height / image.height)
            let origin = CGPoint(x: (size.width - image.width * scale) / 2, y: (size.height - image.height * scale) / 2)
            func map(_ p: CGPoint) -> CGPoint {
                let x = mirrored ? image.width - p.x : p.x
                return CGPoint(x: origin.x + x * scale, y: origin.y + p.y * scale)
            }
            func dot(_ p: CGPoint, _ color: Color, radius: CGFloat) {
                let c = map(p)
                context.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
            }

            for eye in frame.eyes {
                var outline = Path()
                outline.addLines(eye.contour.map(map))
                outline.closeSubpath()
                context.stroke(outline, with: .color(eye.blinking ? .orange : .green.opacity(0.8)), lineWidth: 1)

                // Raw candidates small, the smoothed estimate in use large.
                if let pupil = eye.visionPupil {
                    dot(pupil, .yellow.opacity(0.8), radius: 2)
                }
                if let gradient = eye.gradient {
                    dot(gradient, .purple.opacity(0.9), radius: 2)
                }
                dot(eye.iris, .cyan, radius: 3)

                if let target = eye.target {
                    var line = Path()
                    line.move(to: map(eye.iris))
                    line.addLine(to: map(target))
                    context.stroke(line, with: .color(.pink), lineWidth: 1)
                    let c = map(target)
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.pink), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
