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
    private let handleWidth: CGFloat = 22
    private let space = "trimbar"

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

                RoundedRectangle(cornerRadius: 8)
                    .fill(.yellow.opacity(0.22))
                    .frame(width: max(endX - startX, 0))
                    .offset(x: startX)

                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.yellow, lineWidth: 2)
                    .frame(width: max(endX - startX, 0))
                    .offset(x: startX)

                Capsule()
                    .fill(.white)
                    .frame(width: 3)
                    .offset(x: playheadX - 1.5)
                    .shadow(radius: 2)

                handle(at: startX) { x in
                    trimStart = min(max(0, time(for: x, usable: usable)), trimEnd - minimumClip)
                    onScrub(trimStart)
                }
                handle(at: endX) { x in
                    trimEnd = max(min(duration, time(for: x, usable: usable)), trimStart + minimumClip)
                    onScrub(trimEnd)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // Tapping or dragging the body scrubs, as long as it isn't on a handle.
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        let proposed = time(for: value.location.x, usable: usable)
                        guard abs(proposed - trimStart) > 0.4, abs(proposed - trimEnd) > 0.4 else { return }
                        onScrub(min(max(proposed, trimStart), trimEnd))
                    }
            )
        }
        .coordinateSpace(.named(space))
        .frame(height: 46)
    }

    private func position(_ time: Double, usable: CGFloat) -> CGFloat {
        handleWidth + CGFloat(min(max(time, 0), duration) / max(duration, 0.001)) * usable
    }

    private func time(for x: CGFloat, usable: CGFloat) -> Double {
        Double((x - handleWidth) / usable) * duration
    }

    /// Reports the finger's position in the *bar's* coordinate space.
    ///
    /// Reading `location` in the handle's own space and adding the handle's offset back on
    /// double-counted that offset, so every frame's new position fed the next one — the handle
    /// accelerated away and pinned itself at the minimum clip length, with no way to drag it back.
    /// Naming the coordinate space removes the arithmetic entirely: the finger is wherever it is.
    private func handle(at x: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.yellow)
            .frame(width: handleWidth, height: 46)
            .overlay {
                Capsule()
                    .fill(.black.opacity(0.45))
                    .frame(width: 2, height: 18)
            }
            // A generous invisible margin: these are small targets and the gesture must not be
            // lost mid-drag if the finger strays off the bar.
            .contentShape(Rectangle().inset(by: -18))
            .offset(x: x - handleWidth / 2)
            // High priority so a drag starting on a handle is never read as a scrub.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { onDrag($0.location.x) }
            )
    }
}
