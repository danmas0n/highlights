import SwiftUI

/// Two-handle trim control with a live playhead, in the shape people already know from Photos.
///
/// Deliberately does not rebuild the player when handles move: the preview plays the whole
/// captured window and the handles only bound where playback loops, so dragging stays smooth
/// instead of stuttering while a composition is rebuilt on every frame of the gesture.
struct TrimBar: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let playhead: Double
    let onScrub: (Double) -> Void

    /// Keeps the handles from crossing and from producing a clip too short to be a highlight.
    private let minimumClip: Double = 1.0
    private let handleWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            // Bound as `let`, not a nested `func` — a ViewBuilder closure can't contain
            // declarations, only expressions and bindings.
            let usable = max(geometry.size.width - handleWidth * 2, 1)
            let startX = position(trimStart, usable: usable)
            let endX = position(trimEnd, usable: usable)
            let playheadX = position(playhead, usable: usable)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)

                // Selected span.
                RoundedRectangle(cornerRadius: 8)
                    .fill(.yellow.opacity(0.22))
                    .frame(width: max(endX - startX, 0))
                    .offset(x: startX)

                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.yellow, lineWidth: 2)
                    .frame(width: max(endX - startX, 0))
                    .offset(x: startX)

                // Playhead.
                Capsule()
                    .fill(.white)
                    .frame(width: 3)
                    .offset(x: playheadX - 1.5)
                    .shadow(radius: 2)

                handle(at: startX) { location in
                    let proposed = time(for: location, usable: usable)
                    trimStart = min(max(0, proposed), trimEnd - minimumClip)
                    onScrub(trimStart)
                }
                handle(at: endX) { location in
                    let proposed = time(for: location, usable: usable)
                    trimEnd = max(min(duration, proposed), trimStart + minimumClip)
                    onScrub(trimEnd)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // Tapping or dragging the body scrubs, as long as it isn't on a handle.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let proposed = time(for: value.location.x, usable: usable)
                        guard abs(proposed - trimStart) > 0.4, abs(proposed - trimEnd) > 0.4 else { return }
                        onScrub(min(max(proposed, trimStart), trimEnd))
                    }
            )
        }
        .frame(height: 46)
    }

    private func position(_ time: Double, usable: CGFloat) -> CGFloat {
        handleWidth + CGFloat(min(max(time, 0), duration) / max(duration, 0.001)) * usable
    }

    private func time(for x: CGFloat, usable: CGFloat) -> Double {
        Double((x - handleWidth) / usable) * duration
    }

    private func handle(at x: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.yellow)
            .frame(width: handleWidth, height: 46)
            .overlay {
                Capsule()
                    .fill(.black.opacity(0.45))
                    .frame(width: 2, height: 18)
            }
            .offset(x: x - handleWidth / 2)
            // The gesture has priority so a drag starting on a handle never gets read as a scrub.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onDrag($0.location.x + x - handleWidth / 2) }
            )
    }
}
