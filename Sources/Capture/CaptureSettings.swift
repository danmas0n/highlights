import AVFoundation
import Foundation

/// User-facing capture configuration, persisted across launches.
struct CaptureSettings: Codable, Equatable {
    enum Codec: String, Codable, CaseIterable { case hevc, h264 }

    struct Resolution: Codable, Equatable, Hashable {
        var width: Int32
        var height: Int32

        static let uhd = Resolution(width: 3840, height: 2160)
        static let hd = Resolution(width: 1920, height: 1080)

        var label: String { self == .uhd ? "4K" : "1080p" }
        /// How much lossless crop-in we get when delivering 1080p.
        var cropZoomFactor: Double { Double(width) / Double(Resolution.hd.width) }
    }

    /// 4K is not vanity here — it *is* the zoom. Dropping to 1080p capture means every crop is
    /// an upscale, which is the one setting change that undermines the whole approach.
    var resolution: Resolution = .uhd
    var frameRate: Int = 30
    var codec: Codec = .hevc
    /// 30 Mbps HEVC at 4K30. Deliberately below the ~45 Mbps a camera app would use: the
    /// deliverable is a cropped 1080p clip, so bits spent on 4K fine detail we're going to throw
    /// away are bits spent heating the phone. ~13 GB/hour.
    var bitRate: Int = 30_000_000

    /// Automatically drop to 24 fps when the phone reports serious thermal pressure.
    ///
    /// Frame rate is the right thing to shed — never resolution, because 4K *is* the zoom and
    /// dropping it would silently degrade framing on every clip rather than just smoothness.
    var reduceQualityWhenHot: Bool = true

    /// Cinematic stabilization runs continuous motion analysis alongside the encode. It's the
    /// single biggest quality win for hand-panning a tripod and also a real share of the heat,
    /// so it's exposed rather than buried.
    var stabilizationEnabled: Bool = true

    /// Shorter segments mean finer retention granularity and a faster flush after a bookmark;
    /// longer segments mean fewer files and slightly better compression.
    var segmentSeconds: Double = 4

    var preRollSeconds: Double = 25
    /// The net rippling and the celebration are the highlight. Post-roll is not an afterthought.
    var postRollSeconds: Double = 8

    /// How much unbookmarked history to keep on disk. Bookmarked footage is exempt.
    var retentionMinutes: Double = 5

    var stabilization: AVCaptureVideoStabilizationMode {
        stabilizationEnabled ? .cinematicExtended : .off
    }

    /// Opt-in because it can misfire and because App Review scrutinises volume-button capture.
    var volumeButtonTriggerEnabled: Bool = false

    var showSafeFrame: Bool = true

    /// Optical zoom, expressed the way the Camera app does — relative to the main camera, so 1.0
    /// is the wide lens and 5.0 is the telephoto.
    ///
    /// The original design said "always shoot wide, crop later", on the theory that a 2x lossless
    /// crop out of 4K was reach enough. From an actual sideline it isn't: at a youth pitch you can
    /// easily be 40 yards from play, and 2x leaves a player too small to enjoy. Real optical zoom
    /// costs crop latitude and makes panning less forgiving, but no amount of cropping invents
    /// detail the sensor never resolved.
    var zoomFactor: Double = 1.0

    /// Export resolution is mostly a consequence of how far you zoomed, not an independent dial.
    ///
    /// The crop window is taken from a 4K frame at its native pixels, so an uncropped clip *is*
    /// 4K and a 2× crop *is* exactly 1080p — in both cases with no scaling whatsoever. Forcing
    /// 1080p only matters when you didn't zoom and want smaller files.
    enum ExportQuality: String, Codable, CaseIterable {
        /// Native pixels of the crop region: 4K when uncropped, 1080p at 2×, and never upscaled.
        case matchZoom
        /// Always 1080p, upscaling if the crop is tighter than 2×.
        case fullHD

        var label: String {
            switch self {
            case .matchZoom: "Match zoom (up to 4K)"
            case .fullHD: "Always 1080p"
            }
        }

        /// Render size for a given crop, rounded to even dimensions because H.264/HEVC chroma
        /// subsampling requires it and odd sizes get silently rejected by the encoder.
        func renderSize(forCropFraction fraction: Double, sourceSize: CGSize) -> CGSize {
            let aspect = 16.0 / 9.0
            let width: Double
            switch self {
            case .fullHD:
                width = 1920
            case .matchZoom:
                // Never exceed the pixels we actually have — beyond that we'd only be inventing
                // detail — and never fall below 1080p, which is the floor worth delivering.
                width = min(max(fraction * sourceSize.width, 1920), sourceSize.width)
            }
            let evenWidth = (width / 2).rounded() * 2
            let evenHeight = ((evenWidth / aspect) / 2).rounded() * 2
            return CGSize(width: evenWidth, height: evenHeight)
        }
    }

    var exportQuality: ExportQuality = .matchZoom

    /// Keep a clip's footage in the app after it's been saved to Photos.
    ///
    /// On by default: the exported clip is cropped and flattened, so the local copy is the only
    /// way back to the full 4K frame if you later want to reframe it.
    var keepFootageAfterExport: Bool = true

    var retention: CMTime {
        CMTime(seconds: retentionMinutes * 60, preferredTimescale: 600)
    }

    var clipWindowSeconds: Double { preRollSeconds + postRollSeconds }

    /// Rough disk burn rate, used for the "you have room for N more minutes" readout.
    var bytesPerSecond: Double { Double(bitRate) / 8 * 1.05 }

    // MARK: - Persistence

    private static let key = "capture.settings"

    static func load() -> CaptureSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else { return CaptureSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
