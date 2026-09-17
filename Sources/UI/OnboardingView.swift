import SwiftUI

/// The quick tour. Shown once on first launch, before the camera permission prompt, so the
/// request arrives with context — and reachable again from About.
///
/// This also does quiet double duty for App Review: a reviewer at a desk who taps through these
/// four screens knows to open the eye, wait, tap, close it, and open Clips — which is otherwise easy
/// to miss in an app whose main screen is just a camera.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(
            symbol: "arrow.counterclockwise.circle.fill",
            title: "It watches. You just say when.",
            body: """
            Tap the eye at kickoff and forget about it. When something good happens, tap anywhere \
            on the screen — the last 25 seconds, plus a few after, become a clip. No filming the \
            whole game. Nothing to scrub through later.
            """
        ),
        Page(
            symbol: "camera.metering.center.weighted",
            title: "Frame wide. Zoom later.",
            body: """
            It records in 4K, so you can crop in afterwards with no loss of quality. On the \
            sideline, just keep your player somewhere in the frame — the yellow brackets show how \
            much room you've got. Far from the action? The zoom buttons above the eye \
            use your phone's real lenses.
            """
        ),
        Page(
            symbol: "hand.tap.fill",
            title: "Tap. That's the whole job.",
            body: """
            Anywhere on the screen. A flash and a buzz confirm it. A Bluetooth camera clicker works \
            too if you'd rather not touch the phone. Miss the moment? You have 25 seconds of grace \
            — tap late and it's still there.
            """
        ),
        Page(
            symbol: "scissors",
            title: "Trim, frame, and save.",
            body: """
            Open Clips, pick a moment, drag the handles to trim and the yellow box to frame. Tap \
            the video to see it full-screen. Save to Photos and it's in your camera roll, ready to \
            send to grandparents (or college coaches…).
            """
        ),
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageView(pages[index]).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Next" : "Let's go")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)

                Button("Skip") { dismiss() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
        }
    }

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: page.symbol)
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(.yellow)
                .symbolRenderingMode(.hierarchical)
            Text(page.title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}
