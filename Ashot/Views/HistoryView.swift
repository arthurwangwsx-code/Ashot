import SwiftUI
import AppKit

struct HistoryView: View {
    @Bindable private var manager = HistoryManager.shared
    @State private var query = ""
    @State private var source = "All"
    @State private var sort = "newest"
    @State private var selection: Set<UUID> = []
    @AppStorage("historyEnabled") private var enabled = false
    private var filtered: [HistoryEntry] {
        let entries = manager.entries.filter {
            (source == "All" || $0.source == source) && (query.isEmpty || $0.filename.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query))
        }
        switch sort {
        case "oldest": return entries.sorted { $0.date < $1.date }
        case "name": return entries.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case "size": return entries.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        default: return entries.sorted { $0.date > $1.date }
        }
    }
    private var selected: HistoryEntry? { selection.count == 1 ? manager.entries.first { selection.contains($0.id) } : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 140)
                Picker("Source", selection: $source) {
                    ForEach(["All", "Area", "Fullscreen", "Window", "Delayed", "Scrolling"], id: \.self) { Text(L10n.string($0)).tag($0) }
                }.frame(width: 160)
                Picker("Sort", selection: $sort) {
                    Text("Newest first").tag("newest"); Text("Oldest first").tag("oldest"); Text("Filename").tag("name"); Text("Largest files").tag("size")
                }.frame(width: 190)
                if manager.isBusy { ProgressView().controlSize(.small) }
                Menu {
                    Button("Delete Selected", role: .destructive) { manager.delete(ids: selection); selection.removeAll() }.disabled(selection.isEmpty)
                    Button("Clear History", role: .destructive, action: manager.clear).disabled(manager.entries.isEmpty)
                    Button("Clear Recent Session Images") { RecentCaptureStore.shared.clear() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28).accessibilityLabel(Text("History Actions"))
            }.padding(12).background(.bar)
            if !enabled {
                Label("Persistent history is off. Existing images stay here; new screenshots are kept only for this session.", systemImage: "pause.circle")
                    .font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if manager.pendingCleanup > 0 {
                Text("Some history files could not be removed or were changed outside Ashot. They were preserved; inspect the folder in Finder.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
            if let error = manager.errorMessage {
                HStack { Text(error).font(.callout); Spacer(); Button("Dismiss") { manager.errorMessage = nil } }.padding(12)
            }
            Divider()
            HSplitView {
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                        Text(query.isEmpty ? "No saved screenshots" : "No matching screenshots")
                        Text("Use Recent Screenshots in the menu for this session, or enable persistent history in Settings.").font(.caption).foregroundStyle(.secondary)
                    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, selection: $selection) { entry in
                        HStack(spacing: 12) {
                            HistoryThumbnail(entry: entry).frame(width: 104, height: 70)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.filename).font(.callout).lineLimit(1)
                                Text("\(L10n.string(entry.source)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                Text("\(entry.width) × \(entry.height) px").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(.vertical, 4).tag(entry.id)
                        .onTapGesture(count: 2) { manager.open(entry) }
                        .contextMenu {
                            Button("Edit") { manager.open(entry) }
                            Button("Copy") { manager.copy(entry) }
                            Button("Save As...") { manager.export(entry) }
                            Button("Reveal in Finder") { reveal(entry) }
                            Button("Delete", role: .destructive) { manager.delete(entry) }
                        }
                    }.frame(minWidth: 360)
                }
                if let entry = selected {
                    VStack(alignment: .leading, spacing: 16) {
                        HistoryThumbnail(entry: entry).frame(maxWidth: .infinity).frame(height: 220)
                        Text(entry.filename).font(.headline).textSelection(.enabled)
                        Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
                        HStack { Button("Edit") { manager.open(entry) }; Button("Copy") { manager.copy(entry) }; Button("Pin") { manager.pin(entry) } }
                        Button("Save As...") { manager.export(entry) }
                        Button("Reveal in Finder") { reveal(entry) }
                        Spacer()
                    }.padding(18).frame(minWidth: 250, idealWidth: 290)
                }
            }
            Divider()
            HStack {
                Text("\(manager.entries.count) images")
                Text(ByteCountFormatter.string(fromByteCount: manager.usedBytes, countStyle: .file))
                Spacer()
                if manager.isMigrating { Text("Copying and verifying history…") }
                Button("Open Folder") { if let folder = manager.storageFolder { NSWorkspace.shared.open(folder) } }
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }.frame(minWidth: 780, minHeight: 520)
        .onChange(of: manager.entries.map(\.id)) { selection.formIntersection(Set(manager.entries.map(\.id))) }
    }
    private func reveal(_ entry: HistoryEntry) { if let url = manager.fileURL(for: entry) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
}

private struct HistoryThumbnail: View {
    let entry: HistoryEntry
    @State private var image: NSImage?
    private var url: URL? { HistoryManager.shared.fileURL(for: entry) }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").resizable().scaledToFit().padding(20).foregroundStyle(.secondary) }
        }
        .accessibilityLabel(Text("Screenshot preview"))
        .task(id: url) {
            guard let url else { image = nil; return }
            let raster = await HistoryThumbnailCache.shared.image(at: url)
            guard !Task.isCancelled else { return }
            image = raster.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
        }
    }
}
