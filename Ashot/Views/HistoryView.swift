import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum HistoryFileNaming {
    nonisolated static func safeBase(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Leave byte space for the suffix and extension even for multibyte filenames.
        var result = ""
        for character in cleaned {
            let next = result + String(character)
            if next.utf8.count > 120 { break }
            result = next
        }
        return result.isEmpty || result == "." || result == ".." ? "Screenshot" : result
    }

    nonisolated static func uniqueFilename(base: String, in folder: URL, reserved: Set<URL>) -> String {
        let safe = safeBase(base)
        var filename = "\(safe).png"
        var suffix = 2
        while reserved.contains(folder.appendingPathComponent(filename)) ||
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path) {
            filename = "\(safe)-\(suffix).png"
            suffix += 1
        }
        return filename
    }
}

struct HistoryEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let filename: String
    let date: Date
    let source: String
    let width: Int
    let height: Int

    var image: NSImage? {
        guard let folder = HistoryManager.shared.storageFolder else { return nil }
        let url = folder.appendingPathComponent(filename)
        return NSImage(contentsOf: url)
    }
}

enum HistorySortOrder: String, CaseIterable {
    case dateNewest = "Date (Newest)"
    case dateOldest = "Date (Oldest)"
    case nameAsc = "Name (A-Z)"
    case nameDesc = "Name (Z-A)"
    case sizeDesc = "Size (Largest)"
    case sizeAsc = "Size (Smallest)"

    var displayName: String { L10n.string(rawValue) }
}

enum HistoryFilterSource: String, CaseIterable {
    case all = "All"
    case area = "Area"
    case fullscreen = "Fullscreen"
    case window = "Window"
    case delayed = "Delayed"
    case scrolling = "Scrolling"

    var displayName: String { L10n.string(rawValue) }
}

@MainActor
@Observable
final class HistoryManager {
    static let shared = HistoryManager()
    var entries: [HistoryEntry] = []

    private let metadataFile = "history_metadata.json"
    private let maxEntries = 200
    private var pendingURLs: Set<URL> = []
    private var revision = UUID()

    var storageFolder: URL? {
        let path = UserDefaults.standard.string(forKey: "historyFolder") ?? ""
        if path.isEmpty {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            let folder = appSupport.appendingPathComponent("Ashot/History")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var filenameTemplate: String {
        UserDefaults.standard.string(forKey: "historyFilenameTemplate") ?? "Screenshot_{date}_{time}"
    }

    private init() {
        loadMetadata()
    }

    func add(snapshot: CapturedImageSnapshot, source: String) {
        guard let folder = storageFolder else { return }

        let filename = uniqueFilename(in: folder, source: source)
        let url = folder.appendingPathComponent(filename)

        // Reserve on the main actor before encoding starts: checking the disk alone races
        // when several captures finish within the same filename-template timestamp.
        pendingURLs.insert(url)
        let expectedRevision = revision

        let entry = HistoryEntry(
            id: UUID(),
            filename: filename,
            date: Date(),
            source: source,
            width: Int(snapshot.logicalSize.width),
            height: Int(snapshot.logicalSize.height)
        )

        Task.detached(priority: .utility) {
            do {
                guard let pngData = snapshot.data(format: .png) else { throw ImageSaveError.encodingFailed }
                try pngData.write(to: url, options: .atomic)
            } catch {
                NSLog("Ashot: failed to write history image: \(error.localizedDescription)")
                await HistoryManager.shared.releasePendingURL(url)
                return
            }

            await HistoryManager.shared.commitPersistedEntry(entry, in: folder, expectedRevision: expectedRevision)
        }
    }

    private func releasePendingURL(_ url: URL) {
        pendingURLs.remove(url)
    }

    private func commitPersistedEntry(_ entry: HistoryEntry, in folder: URL, expectedRevision: UUID) {
        let url = folder.appendingPathComponent(entry.filename)
        defer { pendingURLs.remove(url) }
        // A late encoding must not resurrect cleared history or write old-folder metadata
        // into a newly selected history directory.
        guard revision == expectedRevision, folder == storageFolder else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        entries.insert(entry, at: 0)
        entries.sort { $0.date > $1.date }

        if entries.count > maxEntries {
            let removed = entries.removeLast()
            let removedURL = folder.appendingPathComponent(removed.filename)
            try? FileManager.default.removeItem(at: removedURL)
        }

        saveMetadata()
    }

    func delete(_ entry: HistoryEntry) {
        if let folder = storageFolder {
            let url = folder.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: url)
        }
        entries.removeAll { $0.id == entry.id }
        saveMetadata()
    }

    func clear() {
        revision = UUID()
        if let folder = storageFolder {
            for entry in entries {
                let url = folder.appendingPathComponent(entry.filename)
                try? FileManager.default.removeItem(at: url)
            }
        }
        entries.removeAll()
        saveMetadata()
    }

    private func generateFilename(source: String) -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"

        var name = filenameTemplate
        name = name.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: now))
        name = name.replacingOccurrences(of: "{time}", with: timeFormatter.string(from: now))
        name = name.replacingOccurrences(of: "{source}", with: source)
        name = name.replacingOccurrences(of: "{uuid}", with: UUID().uuidString.prefix(8).lowercased())

        return name
    }

    private func uniqueFilename(in folder: URL, source: String) -> String {
        HistoryFileNaming.uniqueFilename(base: generateFilename(source: source), in: folder, reserved: pendingURLs)
    }

    private func metadataURL() -> URL? {
        storageFolder?.appendingPathComponent(metadataFile)
    }

    private func saveMetadata() {
        guard let url = metadataURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadMetadata() {
        guard let url = metadataURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let loaded = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = loaded
        }
    }
}

struct HistoryView: View {
    var manager = HistoryManager.shared
    @State private var searchText = ""
    @State private var sortOrder: HistorySortOrder = .dateNewest
    @State private var filterSource: HistoryFilterSource = .all
    @State private var selectedEntry: HistoryEntry?
    @State private var viewMode: HistoryViewMode = .grid

    enum HistoryViewMode: String {
        case grid, list
    }

    private var filteredAndSorted: [HistoryEntry] {
        var results = manager.entries

        if filterSource != .all {
            results = results.filter { $0.source == filterSource.rawValue }
        }

        if !searchText.isEmpty {
            results = results.filter {
                $0.filename.localizedCaseInsensitiveContains(searchText) ||
                $0.source.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOrder {
        case .dateNewest: results.sort { $0.date > $1.date }
        case .dateOldest: results.sort { $0.date < $1.date }
        case .nameAsc: results.sort { $0.filename < $1.filename }
        case .nameDesc: results.sort { $0.filename > $1.filename }
        case .sizeDesc: results.sort { ($0.width * $0.height) > ($1.width * $1.height) }
        case .sizeAsc: results.sort { ($0.width * $0.height) < ($1.width * $1.height) }
        }

        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            historyToolbar
            Divider()
            if filteredAndSorted.isEmpty {
                emptyState
            } else {
                HSplitView {
                    contentView
                        .frame(minWidth: 350)
                    if let entry = selectedEntry {
                        detailPanel(entry)
                            .frame(minWidth: 250, idealWidth: 280)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: selectedEntry?.id)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .animation(.easeInOut(duration: 0.2), value: viewMode.rawValue)
    }

    private var historyToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .foregroundColor(.accentColor)
                .font(.system(size: 14, weight: .semibold))
            Text("History")
                .font(.headline)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: 150)

            Picker("", selection: $filterSource) {
                ForEach(HistoryFilterSource.allCases, id: \.rawValue) { src in
                    Text(src.displayName).tag(src)
                }
            }
            .frame(width: 100)
            .controlSize(.small)

            Picker("", selection: $sortOrder) {
                ForEach(HistorySortOrder.allCases, id: \.rawValue) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .frame(width: 130)
            .controlSize(.small)

            Picker("", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(HistoryViewMode.grid)
                Image(systemName: "list.bullet").tag(HistoryViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 70)

            Button(action: { manager.clear() }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(manager.entries.isEmpty)
            .help("Clear all history")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .grid:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 14) {
                    ForEach(filteredAndSorted) { entry in
                        HistoryGridItem(entry: entry, isSelected: selectedEntry?.id == entry.id)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedEntry = entry } }
                    }
                }
                .padding(14)
            }
        case .list:
            List(filteredAndSorted, selection: Binding(
                get: { selectedEntry?.id },
                set: { id in selectedEntry = filteredAndSorted.first { $0.id == id } }
            )) { entry in
                HistoryListRow(entry: entry)
                    .tag(entry.id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
                .symbolEffect(.pulse, options: .repeating.speed(0.3))
            Text(L10n.string(searchText.isEmpty && filterSource == .all ? "No screenshots yet" : "No results matching filters"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            if !searchText.isEmpty || filterSource != .all {
                Button("Clear Filters") {
                    searchText = ""
                    filterSource = .all
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailPanel(_ entry: HistoryEntry) -> some View {
        VStack(spacing: 14) {
            if let img = entry.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
            }

            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: L10n.string("Filename"), value: entry.filename)
                DetailRow(label: L10n.string("Source"), value: entry.source)
                DetailRow(label: L10n.string("Date"), value: entry.date.formatted(.dateTime))
                DetailRow(label: L10n.string("Size"), value: "\(entry.width) × \(entry.height)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: {
                        if let img = entry.image { CaptureService.shared.openEditor(with: img) }
                    }) {
                        Label("Edit", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: {
                        if let img = entry.image {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.writeObjects([img])
                            StatusBarAnimator.shared.flash(type: .copy)
                        }
                    }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: {
                    if let folder = manager.storageFolder {
                        let url = folder.appendingPathComponent(entry.filename)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }) {
                    Label("Reveal in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive, action: {
                    withAnimation { manager.delete(entry); selectedEntry = nil }
                }) {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
        .padding(14)
        .background(.regularMaterial)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 12))
                .lineLimit(1)
        }
    }
}

struct HistoryGridItem: View {
    let entry: HistoryEntry
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let img = entry.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay(Image(systemName: "photo").foregroundColor(.secondary.opacity(0.4)))
                }
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 0.5)
            )
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 6 : 3, y: isHovered ? 3 : 1)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .overlay {
                if isHovered {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            GridActionButton(icon: "pencil") {
                                if let img = entry.image { CaptureService.shared.openEditor(with: img) }
                            }
                            GridActionButton(icon: "doc.on.doc") {
                                if let img = entry.image {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.writeObjects([img])
                                    StatusBarAnimator.shared.flash(type: .copy)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .transition(.opacity)
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }

            HStack(spacing: 4) {
                Text(entry.source)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())

                Spacer()

                Text(entry.date, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(4)
    }
}

private struct GridActionButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

struct HistoryListRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = entry.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.08))
                }
            }
            .frame(width: 56, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.source)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.08))
                        .clipShape(Capsule())
                    Text("\(entry.width)×\(entry.height)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
