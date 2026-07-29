import CoreGraphics
import Foundation

/// A crop window that can move over the course of a clip — the synthetic camera operator.
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

    // MARK: - Smoothing

    /// Turns raw per-frame tracker output into something that looks like a human operator.
    ///
    /// Three ideas, all of which matter:
    ///  - **Dead zone**: the camera doesn't move at all while the subject is near the middle.
    ///    Without this the crop micro-jitters continuously and the clip is nauseating.
    ///  - **Critically damped easing**: the window eases toward the target instead of snapping.
    ///  - **Velocity limit**: caps how fast the window can travel, so a tracker glitch that
    ///    teleports the subject across the frame produces a slow drift rather than a whip pan.
    static func smoothed(
        observations: [(time: Double, center: CGPoint)],
        widthFraction: Double,
        deadZone: Double = 0.06,
        easing: Double = 0.12,
        maxSpeedPerSecond: Double = 0.35
    ) -> CropPath {
        guard let first = observations.first else { return .fixed(widthFraction: widthFraction) }

        var keyframes: [Keyframe] = []
        var current = first.center
        var previousTime = first.time

        for observation in observations {
            let dt = max(observation.time - previousTime, 1.0 / 120.0)
            previousTime = observation.time

            let dx = observation.center.x - current.x
            let dy = observation.center.y - current.y
            let distance = (dx * dx + dy * dy).squareRoot()

            if distance > deadZone {
                // Pull toward the edge of the dead zone, not toward the subject itself, so the
                // window comes to rest with the subject comfortably off-centre rather than
                // hunting around dead centre.
                let target = distance - deadZone
                let scale = (target / distance) * easing
                var stepX = dx * scale
                var stepY = dy * scale

                let stepLength = (stepX * stepX + stepY * stepY).squareRoot()
                let maxStep = maxSpeedPerSecond * dt
                if stepLength > maxStep, stepLength > 0 {
                    stepX *= maxStep / stepLength
                    stepY *= maxStep / stepLength
                }
                current = CGPoint(x: current.x + stepX, y: current.y + stepY)
            }

            keyframes.append(Keyframe(time: observation.time, center: current, widthFraction: widthFraction))
        }

        return CropPath(keyframes: decimate(keyframes))
    }

    /// Drops keyframes that add nothing, so the exported video composition carries a handful of
    /// transform ramps instead of one per frame.
    private static func decimate(_ keyframes: [Keyframe], tolerance: Double = 0.004) -> [Keyframe] {
        guard var last = keyframes.first else { return keyframes }
        var result = [last]
        for key in keyframes.dropFirst() {
            let dx = key.center.x - last.center.x
            let dy = key.center.y - last.center.y
            if (dx * dx + dy * dy).squareRoot() > tolerance || key.time - last.time > 0.5 {
                result.append(key)
                last = key
            }
        }
        if let final = keyframes.last, result.last?.time != final.time { result.append(final) }
        return result
    }
}
