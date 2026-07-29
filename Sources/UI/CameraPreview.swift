import AVFoundation
import SwiftUI
import UIKit

/// Live preview layer. `resizeAspect` rather than `resizeAspectFill` on purpose — the operator
/// must see the *entire* recorded frame, because the safe-frame overlay's whole job is to show
/// how much slack is left before the subject leaves the footage. A fill crop would hide exactly
/// the margin we're asking them to use.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.startTrackingRotation()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.stopTrackingRotation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        /// The preview needs its own rotation tracking, separate from the capture connection's.
        ///
        /// Two reasons they can't share: the preview angle is derived with knowledge of the
        /// layer's own transform (hence passing `previewLayer` to the coordinator), and the
        /// preview should follow the *interface* so it looks right in the hand, while capture
        /// follows the *horizon* so the recorded file is upright regardless of the UI.
        func startTrackingRotation() {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            else { return }

            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: device, previewLayer: videoPreviewLayer
            )
            rotationCoordinator = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)

            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview, options: [.new]
            ) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                Task { @MainActor in self?.apply(angle) }
            }
        }

        func stopTrackingRotation() {
            rotationObservation?.invalidate()
            rotationObservation = nil
            rotationCoordinator = nil
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = videoPreviewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }

        deinit { rotationObservation?.invalidate() }

        /// Converts a point in this view to the camera's normalized coordinate space, for focus.
        func devicePoint(for point: CGPoint) -> CGPoint {
            videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        }

        /// The rect the video actually occupies inside the view, which with `resizeAspect` is
        /// smaller than `bounds`. The safe-frame overlay needs this to line up.
        var videoRect: CGRect {
            videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
