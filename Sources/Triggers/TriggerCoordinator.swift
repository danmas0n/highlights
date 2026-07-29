import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Collects every way a highlight can be marked and funnels them into one callback.
@MainActor
@Observable
final class TriggerCoordinator {

    enum Source: String {
        case tap
        case remoteButton
        case hardwareKey
    }

    /// Fired when any trigger lands. Set by the capture view.
    var onTrigger: ((Source) -> Void)?

    private(set) var lastTrigger: (source: Source, at: Date)?

    private let volumeMonitor = VolumeButtonMonitor()

    /// A clicker press can register as two events, and a nervous parent double-taps. Both would
    /// otherwise produce two near-identical clips of the same moment.
    private var lastFireTime: Date?
    private let debounceInterval: TimeInterval = 1.0

    init() {
        volumeMonitor.onPress = { [weak self] in
            self?.fire(.remoteButton)
        }
    }

    func setVolumeTriggerEnabled(_ enabled: Bool) {
        if enabled { volumeMonitor.start() } else { volumeMonitor.stop() }
    }

    func fire(_ source: Source) {
        let now = Date()
        if let last = lastFireTime, now.timeIntervalSince(last) < debounceInterval { return }
        lastFireTime = now
        lastTrigger = (source, now)
        onTrigger?(source)
    }
}

/// Watches for hardware volume changes, which is how the cheap Bluetooth camera clickers
/// announce themselves — most of them pair as a BLE HID device that sends volume-up.
///
/// Caveats worth knowing, because this is the one genuinely fragile trigger:
///  - No change event fires if the volume is already pinned at 0 or 1, so we re-centre it after
///    every press to keep the next one detectable.
///  - Re-centring is done through `MPVolumeView`'s slider. That's a public control, but App
///    Review has historically been inconsistent about apps that repurpose volume as a shutter,
///    which is why this is opt-in rather than the default.
///  - Clickers that send a keyboard key instead of volume are handled by `KeyCommandCatcher`,
///    which uses entirely sanctioned API and should be preferred where the hardware allows.
@MainActor
final class VolumeButtonMonitor {
    var onPress: (() -> Void)?

    private var observation: NSKeyValueObservation?
    private let hiddenVolumeView = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
    private var isAdjustingProgrammatically = false
    private let session = AVAudioSession.sharedInstance()

    func start() {
        guard observation == nil else { return }

        // The view must be in a window for its slider to be live, but it never needs to be seen.
        if hiddenVolumeView.superview == nil,
           let window = UIApplication.shared.connectedScenes
               .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            hiddenVolumeView.alpha = 0.001
            hiddenVolumeView.isUserInteractionEnabled = false
            window.addSubview(hiddenVolumeView)
        }

        try? session.setActive(true)
        recenter()

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isAdjustingProgrammatically else { return }
                self.onPress?()
                self.recenter()
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        hiddenVolumeView.removeFromSuperview()
    }

    /// Parks the volume mid-range so the next press in either direction produces a change event.
    private func recenter() {
        guard let slider = hiddenVolumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        isAdjustingProgrammatically = true
        slider.value = 0.5
        // The KVO notification for our own change arrives asynchronously; hold the guard until
        // after it would have landed or we'd treat our own re-centring as a button press.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isAdjustingProgrammatically = false
        }
    }

    deinit {
        observation?.invalidate()
    }
}
