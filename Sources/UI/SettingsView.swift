import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // `@Observable` types reached through `@Environment` need this to hand out bindings.
        @Bindable var model = model

        return NavigationStack {
            Form {
                Section {
                    LabeledContent("Before the tap") {
                        Stepper("\(Int(model.settings.preRollSeconds))s",
                                value: $model.settings.preRollSeconds, in: 5...60, step: 5)
                    }
                    LabeledContent("After the tap") {
                        Stepper("\(Int(model.settings.postRollSeconds))s",
                                value: $model.settings.postRollSeconds, in: 0...30, step: 2)
                    }
                } header: {
                    Text("Clip length")
                } footer: {
                    Text("A goal is usually 20–30 seconds of build-up plus the finish. Keeping a few seconds after the tap catches the net and the celebration.")
                }

                Section {
                    LabeledContent("Keep history for") {
                        Stepper("\(Int(model.settings.retentionMinutes)) min",
                                value: $model.settings.retentionMinutes, in: 1...30, step: 1)
                    }
                    LabeledContent("Rolling buffer") {
                        Text(estimatedFootprint).foregroundStyle(.secondary)
                    }
                    LabeledContent("Stored now") {
                        Text(model.engine.bytesOnDisk > 0
                             ? ByteCountFormatter.string(fromByteCount: model.engine.bytesOnDisk, countStyle: .file)
                             : "Nothing")
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        Task { await model.engine.purgeAllFootage() }
                    } label: {
                        Text("Delete all stored footage")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("""
                    While recording, footage older than the window above is deleted continuously — \
                    except anything a marked clip needs, which is kept until you save that clip to \
                    Photos, then freed. Stopping the recording deletes everything no clip depends on.

                    Marks and their footage survive quitting the app, so an overheating phone at \
                    halftime doesn't cost you the first half.
                    """)
                }

                Section {
                    Picker("Resolution", selection: $model.settings.exportQuality) {
                        ForEach(CaptureSettings.ExportQuality.allCases, id: \.self) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    Toggle("Keep footage after saving", isOn: $model.settings.keepFootageAfterExport)
                } header: {
                    Text("Export")
                } footer: {
                    Text("""
                    Export resolution is mostly just your zoom level. The crop is taken from the 4K \
                    frame at its native pixels, so an uncropped clip is genuinely 4K and a 2× crop \
                    is exactly 1080p — neither is scaled at all. Zoom past 2× and there aren't \
                    enough pixels left for 1080p, so "Match zoom" delivers a smaller file rather \
                    than an upscaled one.

                    Keeping footage after saving means a clip stays playable in the app and can be \
                    reframed later — the saved file is cropped and flattened, so it's a one-way \
                    door. Swipe a clip away in Clips to free its footage.
                    """)
                }

                Section {
                    Toggle("Slow down when hot", isOn: $model.settings.reduceQualityWhenHot)
                    Toggle("Cinematic stabilization", isOn: $model.settings.stabilizationEnabled)
                } header: {
                    Text("Heat")
                } footer: {
                    Text("""
                    Recording 4K is genuinely demanding and the phone will get warm. \
                    "Slow down when hot" drops to 24 fps under thermal pressure — never resolution, \
                    because 4K is what gives you the free 2× zoom in the editor.

                    Stabilization is the biggest single quality win for panning a tripod by hand, \
                    and also a real share of the heat. Turn it off if the phone struggles.

                    Biggest wins are physical: keep the phone out of direct sun, take the case off, \
                    and only record when play is live.
                    """)
                }

                Section {
                    Toggle("Safe-frame guides", isOn: $model.settings.showSafeFrame)
                } header: {
                    Text("Framing")
                } footer: {
                    Text("Shows the tightest crop you can pull losslessly. Keep your player inside the yellow brackets for a tight highlight, or anywhere in frame for a usable one. Don't zoom the camera — you have a free 2× waiting in the editor.")
                }

                Section {
                    Toggle("Bluetooth clicker (volume)", isOn: $model.settings.volumeButtonTriggerEnabled)
                } header: {
                    Text("Triggers")
                } footer: {
                    Text("Tapping the screen always works. Clickers that send a keyboard key work automatically. Turn this on for clickers that send volume up/down instead — it takes over your volume buttons while the app is open.")
                }

                Section {
                    LabeledContent("Recording") {
                        Text("\(model.settings.resolution.label) · \(model.settings.frameRate) fps · \(model.settings.codec == .hevc ? "HEVC" : "H.264")")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("4K isn't vanity here — it's the zoom. Recording at 1080p would make every crop an upscale. About \(gigabytesPerHour) GB per hour.")
                }

                Section {
                    Button(role: .destructive) {
                        model.library.removeAll()
                    } label: {
                        Text("Clear all marks")
                    }
                } footer: {
                    Text("Removes the marks and lets their footage be discarded. Clips already saved to Photos are untouched.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var estimatedFootprint: String {
        let bytes = model.settings.bytesPerSecond * model.settings.retentionMinutes * 60
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var gigabytesPerHour: String {
        String(format: "%.0f", model.settings.bytesPerSecond * 3600 / 1_000_000_000)
    }
}
