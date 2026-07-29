import SwiftUI
import UIKit

/// Catches keyboard events from Bluetooth clickers that present as a HID keyboard.
///
/// Preferred over the volume-button route wherever the hardware allows it: this is entirely
/// sanctioned API with no App Review ambiguity and no fighting with the system volume. Most
/// cheap clickers send space, return, or the media play/pause key; some send volume, which is
/// what `VolumeButtonMonitor` is for.
struct KeyCommandCatcher: UIViewControllerRepresentable {
    let onKey: () -> Void

    func makeUIViewController(context: Context) -> KeyCatchingController {
        let controller = KeyCatchingController()
        controller.onKey = onKey
        return controller
    }

    func updateUIViewController(_ controller: KeyCatchingController, context: Context) {
        controller.onKey = onKey
    }

    final class KeyCatchingController: UIViewController {
        var onKey: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        override var keyCommands: [UIKeyCommand]? {
            let inputs = [" ", "\r", UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow]
            return inputs.map { input in
                let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleKey))
                // Without this the system beeps and swallows the event when no text field is focused.
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }

        @objc private func handleKey() {
            onKey?()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            // Media keys arrive here rather than through keyCommands.
            for press in presses {
                switch press.type {
                case .playPause, .select:
                    onKey?()
                    return
                default:
                    continue
                }
            }
            super.pressesBegan(presses, with: event)
        }
    }
}
