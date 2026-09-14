import StoreKit
import SwiftUI

/// Who made this and why, plus the tip jar. Written in the first person on purpose: this is one
/// parent's app that other parents might like, and the About screen should sound like that.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showTutorial = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            Image("AppIconPreview")
                                .resizable()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Highlights")
                                    .font(.title2.weight(.bold))
                                Text("Youth Sports Clips")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text("Version \(version)")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Text("""
                        I built this for myself. My son plays high school and club soccer, and I \
                        wanted the good moments without filming — and then scrubbing through — \
                        ninety minutes of game every weekend.

                        The idea is simple: the phone is always recording, and when something \
                        happens you tap the screen and the last half-minute becomes a clip. \
                        Frame it, trim it, save it. That's the whole app.

                        If you've got a kid who plays anything, I hope it's useful to you too.
                        """)
                        .font(.body)
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Button {
                        showTutorial = true
                    } label: {
                        Label("Show the quick tour again", systemImage: "play.rectangle")
                    }
                }

                tipJar

                Section {
                    Link(destination: URL(string: "https://jpsj.me")!) {
                        Label("Website", systemImage: "globe")
                    }
                    Link(destination: URL(string: "https://jpsj.me/highlights/privacy")!) {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                } footer: {
                    Text("Nothing you record leaves your phone. There's no account, no server, and no analytics.")
                }

                Section {
                    Text("© 2026 JPSJ Consulting LLC")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await model.tipJar.load() }
            .fullScreenCover(isPresented: $showTutorial) { OnboardingView() }
        }
    }

    @ViewBuilder
    private var tipJar: some View {
        Section {
            if let thanks = model.tipJar.thanks {
                Label(thanks, systemImage: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.callout.weight(.medium))
            } else if model.tipJar.isLoading {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            } else if model.tipJar.products.isEmpty {
                Text(model.tipJar.loadError ?? "Tips aren't available right now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.tipJar.products, id: \.id) { product in
                    Button {
                        Task { await model.tipJar.tip(product) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName).foregroundStyle(.primary)
                                Text(product.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.tipJar.purchasing == product.id {
                                ProgressView()
                            } else {
                                Text(product.displayPrice)
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(.tint.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    .disabled(model.tipJar.purchasing != nil)
                }
            }
        } header: {
            Text("Tip jar")
        } footer: {
            Text("""
            Entirely optional, and it unlocks nothing — everything in the app is already yours. \
            If it's earned you a highlight you'd have missed, this is a way to say so.
            """)
        }
    }
}
