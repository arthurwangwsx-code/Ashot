import Foundation
import CryptoKit
import AppKit
import ImageIO
import Darwin

enum HistoryFileNaming {
    nonisolated static func safeBase(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in cleaned {
            let next = result + String(character)
            if next.utf8.count > 120 { break }; result = next
        }
        return result.isEmpty || result == "." || result == ".." ? "Screenshot" : result
    }
    nonisolated static func uniqueFilename(base: String, in folder: URL, reserved: Set<URL>) -> String {
        let safe = safeBase(base); var filename = "\(safe).png", suffix = 2
        while reserved.contains(folder.appendingPathComponent(filename)) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path) {
            filename = "\(safe)-\(suffix).png"; suffix += 1
        }
        return filename
    }
    nonisolated static func expanded(_ template: String, source: String, date: Date) -> String {
        let day = DateFormatter(), time = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        time.locale = Locale(identifier: "en_US_POSIX"); time.dateFormat = "HH-mm-ss-SSS"
        return safeBase(String(template.prefix(4096)).replacingOccurrences(of: "{date}", with: day.string(from: date))
            .replacingOccurrences(of: "{time}", with: time.string(from: date)).replacingOccurrences(of: "{source}", with: source)
            .replacingOccurrences(of: "{uuid}", with: UUID().uuidString.prefix(8).lowercased()))
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let date: Date
    let source: String
    let width: Int
    let height: Int
    let bytes: Int64?
    let digest: String?
    nonisolated init(id: UUID = UUID(), filename: String, date: Date, source: String, width: Int, height: Int,
                     bytes: Int64? = nil, digest: String? = nil) {
        self.id = id; self.filename = filename; self.date = date; self.source = source
        self.width = width; self.height = height; self.bytes = bytes; self.digest = digest
    }
    var image: NSImage? {
        guard let url = HistoryManager.shared.fileURL(for: self) else { return nil }
        return try? ImageImportService.load(url)
    }
}

struct HistoryRetentionPolicy: Equatable, Sendable {
    let maximumCount: Int
    let maximumAgeDays: Int
    let maximumBytes: Int64 // 0 means unlimited; legacy installations retain their prior policy.
    nonisolated init(maximumCount: Int = 200, maximumAgeDays: Int = 0, maximumBytes: Int64 = 0) {
        self.maximumCount = max(1, min(10_000, maximumCount))
        self.maximumAgeDays = max(0, min(3650, maximumAgeDays)); self.maximumBytes = max(0, maximumBytes)
    }
    static func current(defaults: UserDefaults = .standard) -> Self {
        let count = defaults.object(forKey: "historyMaximumCount") as? Int ?? 200
        let days = defaults.object(forKey: "historyMaximumDays") as? Int ?? 0
        let mb = defaults.object(forKey: "historyMaximumMB") as? Int ?? (defaults.bool(forKey: "existingUserMigration") ? 0 : 1024)
        return Self(maximumCount: count, maximumAgeDays: days, maximumBytes: Int64(max(0, min(51_200, mb))) * 1_000_000)
    }
    nonisolated func retained(_ entries: [HistoryEntry], sizes: [UUID: Int64], now: Date) -> [HistoryEntry] {
        var result: [HistoryEntry] = [], bytes: Int64 = 0
        let cutoff = now.addingTimeInterval(-Double(maximumAgeDays) * 86_400)
        for entry in entries.sorted(by: { $0.date > $1.date }) {
            guard result.count < maximumCount else { continue }
            if maximumAgeDays > 0 && entry.date < cutoff { continue }
            let size = max(0, sizes[entry.id] ?? entry.bytes ?? 0)
            if maximumBytes > 0 && (size > maximumBytes || bytes > maximumBytes - size) { continue }
            result.append(entry)
            bytes = size > Int64.max - bytes ? Int64.max : bytes + size
        }
        return result
    }
}

enum HistoryStorageError: LocalizedError {
    case unsafePath, invalidIndex, destinationNotEmpty, changedFile, missingFile, nestedDestination, exceedsRetention
    nonisolated var errorDescription: String? {
        switch self {
        case .unsafePath: return "The history path contains an unsafe filename or symbolic link. No unrelated files were changed."
        case .invalidIndex: return "The history index is damaged or unsupported. It was preserved instead of overwritten."
        case .destinationNotEmpty: return "The destination already contains history files. Choose a different empty folder."
        case .changedFile: return "A history file changed outside Ashot. It was preserved; inspect it in Finder before retrying."
        case .missingFile: return "A history image is missing. Remove its entry or restore the file before migrating."
        case .nestedDestination: return "Choose a history folder outside the current library and its parent folders."
        case .exceedsRetention: return "This image exceeds the configured history size limit. Increase the limit or save it separately."
        }
    }
}

enum HistoryPathPolicy {
    nonisolated static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) ||
               (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return nil }
            throw error
        }
    }
    nonisolated static func validFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename.utf8.count <= 255 && filename != "." && filename != ".." &&
        !filename.contains("/") && !filename.contains("\\") && !filename.contains(":") &&
        !filename.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        (filename as NSString).pathExtension.lowercased() == "png"
    }
    nonisolated static func validateDirectory(_ folder: URL, create: Bool = false) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            if create { try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            else { return }
        }
        let attributes = try manager.attributesOfItem(atPath: folder.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw HistoryStorageError.unsafePath }
    }
    nonisolated static func file(_ filename: String, in folder: URL, mustExist: Bool = true) throws -> URL {
        guard validFilename(filename) else { throw HistoryStorageError.unsafePath }
        try validateDirectory(folder)
        let url = folder.appendingPathComponent(filename)
        if let attributes = try attributesIfPresent(url) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw HistoryStorageError.unsafePath }
        } else if mustExist { throw HistoryStorageError.missingFile }
        return url
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private struct HistoryManifest: Codable, Sendable {
    var version = 2
    var entries: [HistoryEntry] = []
    // Persist cleanup obligations before deleting pixels. A failed cleanup is visible and can be
    // retried; an index-write failure never leaves a valid index pointing at deleted images.
    var pendingDeletion: [HistoryEntry] = []
}

struct HistoryState: Sendable {
    let folder: URL
    let entries: [HistoryEntry]
    let usedBytes: Int64
    let pendingCleanup: Int
}

actor HistoryRepository {
    private var root: URL
    private var manifest = HistoryManifest()
    private var loaded = false
    private var epoch = 0
    private let metadataFilename = "history_metadata.json"
    private let migrationPublishGate: (@Sendable () throws -> Void)?

    init(root: URL, migrationPublishGate: (@Sendable () throws -> Void)? = nil) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.migrationPublishGate = migrationPublishGate
    }

    func snapshot() throws -> HistoryState { try load(); return state() }
    func advanceEpoch(_ newEpoch: Int) throws -> HistoryState { epoch = max(epoch, newEpoch); try load(); return state() }

    func add(_ image: CapturedImageSnapshot, source: String, template: String, date: Date = Date(),
             expectedEpoch: Int, retention: HistoryRetentionPolicy) throws -> HistoryState {
        guard expectedEpoch >= epoch else { return state() }
        epoch = expectedEpoch; try load(); try HistoryPathPolicy.validateDirectory(root, create: true)
        let data = try ExportService.encode(image.cgImage, options: ExportOptions(format: .png))
        if retention.maximumBytes > 0 && Int64(data.count) > retention.maximumBytes { throw HistoryStorageError.exceedsRetention }
        let name = HistoryFileNaming.expanded(template, source: source, date: date)
        let output = try AtomicFileWriter.writeUnique(data, in: root, base: name, extension: "png")
        let entry = HistoryEntry(filename: output.lastPathComponent, date: date, source: source,
            width: image.cgImage.width, height: image.cgImage.height, bytes: Int64(data.count), digest: HistoryPathPolicy.digest(data))
        let old = manifest
        manifest.entries.insert(entry, at: 0)
        apply(retention, now: date)
        do { try save() }
        catch { manifest = old; try? FileManager.default.removeItem(at: output); throw error }
        try reap(); return state()
    }

    func remove(ids: Set<UUID>, expectedEpoch: Int) throws -> HistoryState {
        epoch = max(epoch, expectedEpoch); try load()
        let old = manifest
        manifest.pendingDeletion += manifest.entries.filter { ids.contains($0.id) }
        manifest.entries.removeAll { ids.contains($0.id) }
        do { try save() } catch { manifest = old; throw error }
        try reap(); return state()
    }
    func clear(expectedEpoch: Int) throws -> HistoryState {
        epoch = max(epoch, expectedEpoch); try load()
        return try remove(ids: Set(manifest.entries.map(\.id)), expectedEpoch: epoch)
    }
    func prune(_ retention: HistoryRetentionPolicy, now: Date = Date(), expectedEpoch: Int) throws -> HistoryState {
        epoch = max(epoch, expectedEpoch); try load()
        let old = manifest; apply(retention, now: now)
        do { try save() } catch { manifest = old; throw error }
        try reap(); return state()
    }

    /// Copy, verify and publish the destination index last. Existing destination files are never
    /// overwritten. The old directory remains an explicit backup until the user removes it.
    func migrate(to destination: URL, expectedEpoch: Int) throws -> HistoryState {
        epoch = max(epoch, expectedEpoch); try load()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard target.path != root.path, !target.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(target.path + "/") else { throw HistoryStorageError.nestedDestination }
        try HistoryPathPolicy.validateDirectory(target, create: true)
        let index = target.appendingPathComponent(metadataFilename)
        guard !FileManager.default.fileExists(atPath: index.path),
              (try? FileManager.default.attributesOfItem(atPath: index.path)) == nil else { throw HistoryStorageError.destinationNotEmpty }
        let stage = target.appendingPathComponent(".ashot-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        var migrated: [HistoryEntry] = [], created: [URL] = []
        do {
            for entry in manifest.entries {
                let source = try HistoryPathPolicy.file(entry.filename, in: root)
                let output = target.appendingPathComponent(entry.filename)
                guard (try? FileManager.default.attributesOfItem(atPath: output.path)) == nil else { throw HistoryStorageError.destinationNotEmpty }
                let data = try verifiedData(for: entry, at: source)
                let staged = stage.appendingPathComponent(entry.filename)
                try AtomicFileWriter.writeExclusive(data, to: staged)
                let stagedData = try Data(contentsOf: staged, options: .mappedIfSafe)
                guard HistoryPathPolicy.digest(stagedData) == HistoryPathPolicy.digest(data) else { throw HistoryStorageError.changedFile }
                migrated.append(HistoryEntry(id: entry.id, filename: entry.filename, date: entry.date, source: entry.source,
                    width: entry.width, height: entry.height, bytes: Int64(data.count), digest: HistoryPathPolicy.digest(data)))
            }
            for entry in migrated {
                let staged = stage.appendingPathComponent(entry.filename), output = target.appendingPathComponent(entry.filename)
                try AtomicFileWriter.writeExclusive(Data(contentsOf: staged, options: .mappedIfSafe), to: output)
                created.append(output)
            }
            var next = HistoryManifest(); next.entries = migrated
            try migrationPublishGate?()
            try AtomicFileWriter.writeExclusive(try encode(next), to: index)
            root = target; manifest = next; loaded = true
            return state()
        } catch {
            // These paths were successfully created by this transaction, never pre-existing files.
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func load() throws {
        guard !loaded else { return }
        try HistoryPathPolicy.validateDirectory(root)
        let url = root.appendingPathComponent(metadataFilename)
        guard let attrs = try HistoryPathPolicy.attributesIfPresent(url) else { loaded = true; return }
        guard attrs[.type] as? FileAttributeType == .typeRegular, ((attrs[.size] as? NSNumber)?.int64Value ?? .max) <= 10_000_000 else { throw HistoryStorageError.invalidIndex }
        let data = try Data(contentsOf: url), decoder = JSONDecoder()
        let legacyDecoder = JSONDecoder(); legacyDecoder.dateDecodingStrategy = .iso8601
        let parsed: HistoryManifest
        if let legacy = try? legacyDecoder.decode([HistoryEntry].self, from: data) {
            var migrated = HistoryManifest(); migrated.entries = legacy; parsed = migrated
        } else if let current = try? decoder.decode(HistoryManifest.self, from: data), current.version == 2 { parsed = current }
        else { throw HistoryStorageError.invalidIndex }
        let all = parsed.entries + parsed.pendingDeletion
        guard all.count <= 20_000, Set(all.map(\.id)).count == all.count,
              Set(all.map { $0.filename.precomposedStringWithCanonicalMapping.lowercased() }).count == all.count,
              all.allSatisfy({ HistoryPathPolicy.validFilename($0.filename) && $0.width > 0 && $0.height > 0 && $0.width <= 32_768 && $0.height <= 32_768 }) else { throw HistoryStorageError.invalidIndex }
        for entry in all { _ = try HistoryPathPolicy.file(entry.filename, in: root, mustExist: false) }
        manifest = parsed; manifest.entries.sort { $0.date > $1.date }; loaded = true
    }
    private func save() throws {
        try HistoryPathPolicy.validateDirectory(root, create: true)
        let url = root.appendingPathComponent(metadataFilename)
        if let attrs = try HistoryPathPolicy.attributesIfPresent(url), attrs[.type] as? FileAttributeType != .typeRegular { throw HistoryStorageError.unsafePath }
        try AtomicFileWriter.replace(encode(manifest), at: url)
    }
    private func encode(_ manifest: HistoryManifest) throws -> Data {
        // The versioned manifest preserves Date's reference-epoch Double exactly. The legacy
        // ISO8601 array had second-only timestamps and remains supported by the legacy decoder.
        return try JSONEncoder().encode(manifest)
    }
    private func fileSize(_ entry: HistoryEntry) -> Int64 {
        guard let url = try? HistoryPathPolicy.file(entry.filename, in: root),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    private func apply(_ policy: HistoryRetentionPolicy, now: Date) {
        let sizes = Dictionary(manifest.entries.map { ($0.id, fileSize($0)) }, uniquingKeysWith: max)
        let retained = policy.retained(manifest.entries, sizes: sizes, now: now)
        let ids = Set(retained.map(\.id))
        manifest.pendingDeletion += manifest.entries.filter { !ids.contains($0.id) }
        manifest.entries = retained
    }
    private func verifiedData(for entry: HistoryEntry, at url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0, size <= 300_000_000 else { throw HistoryStorageError.changedFile }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let digest = entry.digest, HistoryPathPolicy.digest(data) != digest { throw HistoryStorageError.changedFile }
        return data
    }
    private func reap() throws {
        guard !manifest.pendingDeletion.isEmpty else { return }
        let previous = manifest.pendingDeletion
        manifest.pendingDeletion = previous.filter { entry in
            do {
                let url = try HistoryPathPolicy.file(entry.filename, in: root, mustExist: false)
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                _ = try verifiedData(for: entry, at: url)
                try FileManager.default.removeItem(at: url)
                return false
            } catch { return true }
        }
        if manifest.pendingDeletion != previous { try save() }
    }
    private func state() -> HistoryState {
        let used = (manifest.entries + manifest.pendingDeletion).reduce(Int64(0)) { total, entry in
            let size = max(0, fileSize(entry)); return size > Int64.max - total ? Int64.max : total + size
        }
        return HistoryState(folder: root, entries: manifest.entries, usedBytes: used, pendingCleanup: manifest.pendingDeletion.count)
    }
}
