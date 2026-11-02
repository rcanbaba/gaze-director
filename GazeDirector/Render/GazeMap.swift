import GazeCore
import SwiftUI

/// Gaze-offset space at a glance: camera point at the centre, reading zone, real gaze and target.
struct GazeMap: View {
    let frame: DebugFrame
    /// Half the visible range in uv.
    var range = 0.15

    var body: some View {
        Canvas { context, size in
            func map(_ v: Vec2) -> CGPoint {
                CGPoint(x: (v.x / range + 1) / 2 * size.width, y: (v.y / range + 1) / 2 * size.height)
            }

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.85)))

            if let zone = frame.readingZone {
                let a = map(Vec2(zone.minX, zone.minY)), b = map(Vec2(zone.maxX, zone.maxY))
                let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                context.fill(Path(rect), with: .color(.blue.opacity(0.25)))
                context.stroke(Path(rect), with: .color(.blue), lineWidth: 1)
            }

            let c = map(.zero)
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - 6, y: c.y))
            cross.addLine(to: CGPoint(x: c.x + 6, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - 6))
            cross.addLine(to: CGPoint(x: c.x, y: c.y + 6))
            context.stroke(cross, with: .color(.white), lineWidth: 1)

            if let center = frame.readingCenter {
                let p = map(center)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.blue))
            }
            if let raw = frame.gazeOffset {
                let p = map(raw)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(.gray))
            }
            if let gaze = frame.smoothedGaze {
                let p = map(gaze)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.cyan))
            }
            if frame.weight > 0, let target = frame.target {
                let p = map(target)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.pink), lineWidth: 2)
            }
        }
        .overlay(alignment: .topLeading) {
            Text("camera +  ·  gaze ●  ·  target ○")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
