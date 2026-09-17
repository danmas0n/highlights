import CoreGraphics
import Foundation

/// A crop window over a clip.
///
/// Keyframed so a moving crop is possible in future — the interpolation and the transform-ramp
/// export path both handle it — but nothing in the app currently produces more than one keyframe.
///
/// Coordinates are normalized to the source frame (0–1, origin top-left) so a path stays valid
/// if the source resolution changes. The window's aspect ratio is fixed to the delivery aspect;
/// only its centre and scale vary.
struct CropPath: Codable, Equatable {

    struct Keyframe: Codable, Equatable {
        /// Seconds from the start of the clip.
        var time: Double
        /// Centre of the crop window, normalized.
        var center: CGPoint
        /// Fraction of the source width the window spans. 0.5 == 2x zoom.
        var widthFraction: Double
    }

    var keyframes: [Keyframe]
    /// Delivery aspect ratio (width / height). 16:9 for everything we export.
    var aspect: Double = 16.0 / 9.0

    static func fixed(center: CGPoint = CGPoint(x: 0.5, y: 0.5), widthFraction: Double = 0.5) -> CropPath {
        CropPath(keyframes: [Keyframe(time: 0, center: center, widthFraction: widthFraction)])
    }

    var isStatic: Bool { keyframes.count <= 1 }

    /// True when this crop keeps the whole frame, so exporting it needs no compositing at all.
    var isFullFrame: Bool {
        isStatic && (keyframes.first?.widthFraction ?? 1) >= 0.999
    }

    /// Crop rect in normalized source coordinates at a given time, clamped to stay inside frame.
    func rect(at time: Double, sourceAspect: Double) -> CGRect {
        let key = interpolated(at: time)
        // Normalized height must account for the source's own aspect: a window spanning half the
        // width of a 16:9 source is half the height too, but on a 4:3 source it isn't.
        let width = key.widthFraction
        let height = width * (sourceAspect / aspect)

        var x = key.center.x - width / 2
        var y = key.center.y - height / 2
        // Clamp rather than letting the window run off the edge, which would composite black bars.
        x = min(max(x, 0), max(0, 1 - width))
        y = min(max(y, 0), max(0, 1 - height))
        return CGRect(x: x, y: y, width: min(width, 1), height: min(height, 1))
    }

    private func interpolated(at time: Double) -> Keyframe {
        guard let first = keyframes.first else {
            return Keyframe(time: 0, center: CGPoint(x: 0.5, y: 0.5), widthFraction: 1)
        }
        guard keyframes.count > 1 else { return first }

        let sorted = keyframes.sorted { $0.time < $1.time }
        if time <= sorted[0].time { return sorted[0] }
        if let last = sorted.last, time >= last.time { return last }

        for index in 0..<(sorted.count - 1) {
            let a = sorted[index], b = sorted[index + 1]
            guard time >= a.time, time <= b.time else { continue }
            let span = b.time - a.time
            let t = span > 0 ? (time - a.time) / span : 0
            // Smoothstep rather than linear: a linear ramp between keyframes starts and stops
            // abruptly, which reads as a jerk exactly where the eye is tracking a player.
            let e = t * t * (3 - 2 * t)
            return Keyframe(
                time: time,
                center: CGPoint(
                    x: a.center.x + (b.center.x - a.center.x) * e,
                    y: a.center.y + (b.center.y - a.center.y) * e
                ),
                widthFraction: a.widthFraction + (b.widthFraction - a.widthFraction) * e
            )
        }
        return sorted[sorted.count - 1]
    }
}
