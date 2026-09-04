import SwiftUI

/// The post-game screen: everything marked, waiting to be framed and exported.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Highlight?
    @AppStorage("clips.sortOrder") private var sortOrderRaw = HighlightLibrary.SortOrder.newestFirst.rawValue
    @State private var exportingAll = false
    @State private var exportProgress: (done: Int, total: Int)?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.library.highlights.isEmpty {
                    ContentUnavailableView(
                        "No clips yet",
                        systemImage: "hand.tap",
                        description: Text("Tap anywhere on the capture screen when something good happens.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $sortOrderRaw) {
                            ForEach(HighlightLibrary.SortOrder.allCases, id: \.rawValue) { order in
                                Text(order.label).tag(order.rawValue)
                            }
                        }
                        Divider()
                        Button("Export All") { Task { await exportAll() } }
                            .disabled(model.library.highlights.isEmpty || exportingAll)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $editing) { HighlightEditorView(highlight: $0) }
            .alert("Export problem", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                if let progress = exportProgress {
                    Text("Exporting \(progress.done) of \(progress.total)…")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 20)
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(sortedHighlights) { highlight in
                Button {
                    editing = highlight
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.quaternary)
                                .frame(width: 72, height: 40)
                            Image(systemName: highlight.isExported ? "checkmark.circle.fill" : "scissors")
                                .foregroundStyle(highlight.isExported ? .green : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            // Lead with the wall clock. "Mark at 0:32" is ambiguous once there's
                            // more than one recording, since each starts counting from zero again.
                            Text(highlight.title.isEmpty
                                 ? highlight.markedAt.formatted(date: .omitted, time: .shortened)
                                 : highlight.title)
                                .font(.body.weight(.medium))
                            Text("\(Int(highlight.trimmedDurationSeconds))s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if highlight.cropPath != nil {
                            Image(systemName: "crop")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { indexSet in
                let doomed = indexSet.map { sortedHighlights[$0] }
                Task { for highlight in doomed { await model.delete(highlight) } }
            }
        }
    }

    /// Bulk export with no crop applied — the "just give me everything, I'll look later" path.
    /// Runs serially: two concurrent 4K exports on a phone that has just spent 90 minutes
    /// encoding is a reliable way to get thermally throttled.
    private func exportAll() async {
        exportingAll = true
        defer { exportingAll = false; exportProgress = nil }

        let pending = sortedHighlights.filter { !$0.isExported }
        for (index, highlight) in pending.enumerated() {
            exportProgress = (index + 1, pending.count)
            do {
                let output = try await model.extractor.export(
                    highlight: highlight, quality: model.settings.exportQuality
                )
                var updated = highlight
                updated.exportedAssetIdentifier = output.assetIdentifier
                model.library.update(updated)
                await model.releaseFootageIfConfigured(for: highlight)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    private var sortedHighlights: [Highlight] {
        model.library.sorted(
            by: HighlightLibrary.SortOrder(rawValue: sortOrderRaw) ?? .newestFirst
        )
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
