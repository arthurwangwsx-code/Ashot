import AppKit

@Observable
final class HistoryManager {
    static let shared = HistoryManager()
    private(set) var entries: [HistoryEntry] = []
    private(set) var storageFolder: URL?
    private(set) var usedBytes: Int64 = 0
    private(set) var pendingCleanup = 0
    private(set) var isMigrating = false
    private(set) var pendingOperations = 0
    private(set) var storageBlocked = false
    var errorMessage: String?
    var enabled: Bool { UserDefaults.standard.bool(forKey: "historyEnabled") }
    var isBusy: Bool { pendingOperations > 0 || isMigrating }
    var filenameTemplate: String { UserDefaults.standard.string(forKey: "historyFilenameTemplate") ?? "Screenshot_{date}_{time}" }
    private let repository: HistoryRepository
    private var tail: Task<Void, Never>?
    private var epoch = 0
    private var exportModels: [UUID: EditorViewModel] = [:]

    private init() {
        let path = UserDefaults.standard.string(forKey: "historyFolder") ?? ""
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let folder = (path.isEmpty ? fallback.appendingPathComponent("Ashot/History") : URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)).standardizedFileURL.resolvingSymlinksInPath()
        storageFolder = folder; repository = HistoryRepository(root: folder)
        enqueue { store, _ in try await store.snapshot() }
    }
    private func enqueue(_ operation: @escaping (HistoryRepository, Int) async throws -> HistoryState) {
        let previous = tail, expectedEpoch = epoch
        pendingOperations += 1
        tail = Task {
            await previous?.value
            defer { pendingOperations -= 1 }
            do {
                let state = try await operation(repository, expectedEpoch)
                if expectedEpoch == epoch { apply(state); storageBlocked = false }
            } catch {
                if expectedEpoch == epoch {
                    let previous = errorMessage
                    storageBlocked = true; errorMessage = error.localizedDescription
                    if previous != errorMessage { UserNotice.show("History could not be updated", detail: error.localizedDescription, duration: 10) }
                }
            }
        }
    }
    private func apply(_ state: HistoryState) {
        storageFolder = state.folder; entries = state.entries; usedBytes = state.usedBytes; pendingCleanup = state.pendingCleanup
    }
    func add(snapshot: CapturedImageSnapshot, source: String) {
        guard enabled, !storageBlocked else { return }
        guard !isMigrating, pendingOperations < 12 else { UserNotice.show("History is busy. This screenshot remains available for this session."); return }
        let expected = epoch, policy = HistoryRetentionPolicy.current(), template = filenameTemplate, date = Date()
        enqueue { [weak self] store, _ in
            guard let self, self.epoch == expected, self.enabled else { return try await store.snapshot() }
            return try await store.add(snapshot, source: source, template: template, date: date, expectedEpoch: expected, retention: policy)
        }
    }
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "historyEnabled")
        epoch += 1
        enqueue { store, epoch in try await store.advanceEpoch(epoch) }
    }
    func retryStorage() {
        guard !isBusy else { return }
        errorMessage = nil
        enqueue { store, _ in try await store.snapshot() }
    }
    func clear() {
        guard !entries.isEmpty, !isMigrating else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("Clear screenshot history?")
        alert.informativeText = L10n.string("This removes Ashot-managed images in the current history folder. Other files and old-folder backups are not deleted. This cannot clear copies in clipboard managers or backups.")
        alert.addButton(withTitle: L10n.string("Cancel")); alert.addButton(withTitle: L10n.string("Clear History"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        epoch += 1; enqueue { store, epoch in try await store.clear(expectedEpoch: epoch) }
    }
    func delete(_ entry: HistoryEntry) { delete(ids: [entry.id]) }
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty, !isMigrating else { return }
        enqueue { store, epoch in try await store.remove(ids: ids, expectedEpoch: epoch) }
    }
    func applyRetention() {
        guard !isMigrating else { return }
        let policy = HistoryRetentionPolicy.current()
        enqueue { store, epoch in try await store.prune(policy, expectedEpoch: epoch) }
    }
    func chooseMigrationDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = L10n.string("Choose an empty history folder")
        panel.message = L10n.string("Images will be copied and verified before switching. The previous folder stays as a backup; it is not deleted automatically.")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }; self?.migrate(to: url)
        }
    }
    func migrate(to destination: URL) {
        guard !isMigrating else { return }
        let old = storageFolder
        // Flush captures already in the queue before copying. New captures are explicitly kept
        // session-only while this migration is active.
        isMigrating = true
        enqueue { [weak self] store, epoch in
            guard let self else { return try await store.snapshot() }
            defer { self.isMigrating = false }
            let result = try await store.migrate(to: destination, expectedEpoch: epoch)
            UserDefaults.standard.set(result.folder.path, forKey: "historyFolder")
            if let old { UserDefaults.standard.set(old.path, forKey: "historyPreviousFolder") }
            UserNotice.show("History copied and verified. The previous folder was kept as a backup.", duration: 10)
            return result
        }
    }
    func fileURL(for entry: HistoryEntry) -> URL? {
        guard let folder = storageFolder else { return nil }
        return try? HistoryPathPolicy.file(entry.filename, in: folder)
    }
    func open(_ entry: HistoryEntry) { withImage(entry) { CaptureService.shared.openEditor(with: $0) } }
    func copy(_ entry: HistoryEntry) {
        withImage(entry) { image in
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.writeObjects([image]) { UserNotice.show("Copied") }
            else { UserNotice.show("The clipboard could not be updated. Try copying again.") }
        }
    }
    func pin(_ entry: HistoryEntry) { withImage(entry) { PinService.shared.pinImage($0) } }
    func export(_ entry: HistoryEntry) {
        guard exportModels.count < 4 else { return }
        withImage(entry) { [weak self] image in
            guard let self else { return }
            let id = UUID(), model = EditorViewModel(image: image)
            self.exportModels[id] = model
            model.saveToFile { [weak self, weak model] success in
                if !success, let error = model?.exportError { self?.errorMessage = error }
                self?.exportModels.removeValue(forKey: id)
            }
        }
    }
    private func withImage(_ entry: HistoryEntry, action: @escaping (NSImage) -> Void) {
        guard let url = fileURL(for: entry) else { errorMessage = L10n.string("A history image is missing or unsafe. Inspect the history folder in Finder."); return }
        Task {
            do {
                let raster = try await Task.detached(priority: .userInitiated) { try ImageImportService.readRaster(url) }.value
                action(NSImage(cgImage: raster, size: CGSize(width: raster.width, height: raster.height)))
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

actor HistoryThumbnailCache {
    static let shared = HistoryThumbnailCache()
    private var thumbnails: [URL: CGImage] = [:]
    private var order: [URL] = []
    func image(at url: URL) -> CGImage? {
        if let image = thumbnails[url] { return image }
        guard let image = try? ImageImportService.thumbnail(url, maximumPixels: 320) else { return nil }
        while order.count >= 80 { thumbnails.removeValue(forKey: order.removeFirst()) }
        order.append(url); thumbnails[url] = image; return image
    }
}
