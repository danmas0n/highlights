import SwiftUI

/// Shows the operator how much room they have to be wrong.
///
/// The outer edge is everything being recorded; the inner rectangle is the tightest crop we can
/// deliver losslessly (1080p out of 4K, so exactly 2x). Keeping the player inside the inner box
/// means a tight highlight; keeping them merely inside the outer edge still means a usable one.
/// That gap is the entire reason we shoot wide instead of zooming on the sideline.
struct SafeFrameOverlay: View {
    /// Inner rect width as a fraction of the full frame. 0.5 for 1080p-from-4K.
    let cropFraction: Double

    var body: some View {
        GeometryReader { geometry in
            let frame = videoFrame(in: geometry.size)
            let inner = CGSize(width: frame.width * cropFraction, height: frame.height * cropFraction)

            ZStack {
                Rectangle()
                    .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                    .frame(width: frame.width, height: frame.height)

                CornerBrackets()
                    .stroke(.yellow.opacity(0.9), lineWidth: 2.5)
                    .frame(width: inner.width, height: inner.height)

                Text("tight crop")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .offset(y: -inner.height / 2 - 12)
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    /// The preview uses `resizeAspect`, so the video is letterboxed inside the view. Match it or
    /// the brackets would sit over the letterbox bars and lie about the framing.
    private func videoFrame(in size: CGSize) -> CGSize {
        let videoAspect = 16.0 / 9.0
        let viewAspect = size.width / size.height
        if viewAspect > videoAspect {
            return CGSize(width: size.height * videoAspect, height: size.height)
        } else {
            return CGSize(width: size.width, height: size.width / videoAspect)
        }
    }
}

/// Corner brackets rather than a closed rectangle — a full box reads as a viewfinder edge and
/// pulls the eye inward, which is the opposite of what we want the operator doing.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.16
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))

        return path
    }
}
