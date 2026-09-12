import AppKit
import Foundation
import Testing
@testable import Ashot

@MainActor
private struct HistoryFixture {
    let base: URL, root: URL, destination: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("AshotHistoryTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        root = base.appendingPathComponent("library", isDirectory: true)
        destination = base.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
    func image() throws -> CapturedImageSnapshot { try #require(CapturedImageSnapshot(image: ProductTestImage.make())) }
}

@MainActor
struct HistoryRepositoryTests {
    @Test func addPersistsChecksumsAndReloadsFromDisk() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root), image = try fixture.image()
        let state = try await store.add(image, source: "Area", template: "same", expectedEpoch: 0, retention: .init())
        let entry = try #require(state.entries.first)
        let data = try Data(contentsOf: fixture.root.appendingPathComponent(entry.filename))
        #expect(entry.digest == HistoryPathPolicy.digest(data))
        #expect(entry.bytes == Int64(data.count)); #expect(state.usedBytes == Int64(data.count))
        let reloaded = try await HistoryRepository(root: fixture.root).snapshot()
        #expect(reloaded.entries == state.entries)
    }
    @Test func sameTemplateDoesNotOverwriteAndCountLimitCleansOwnedFiles() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root), image = try fixture.image()
        let first = try await store.add(image, source: "Area", template: "same", date: Date(timeIntervalSince1970: 1), expectedEpoch: 0, retention: .init(maximumCount: 2))
        let second = try await store.add(image, source: "Area", template: "same", date: Date(timeIntervalSince1970: 2), expectedEpoch: 0, retention: .init(maximumCount: 2))
        #expect(Set(second.entries.map(\.filename)).count == 2)
        let third = try await store.add(image, source: "Area", template: "same", date: Date(timeIntervalSince1970: 3), expectedEpoch: 0, retention: .init(maximumCount: 2))
        #expect(third.entries.count == 2); #expect(third.pendingCleanup == 0)
        let oldest = try #require(first.entries.first)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(oldest.filename).path))
    }
    @Test func clearPreventsLateCaptureResurrectionAndPreservesUnmanagedFiles() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root), image = try fixture.image()
        _ = try await store.add(image, source: "Area", template: "shot", expectedEpoch: 1, retention: .init())
        let foreign = fixture.root.appendingPathComponent("my-personal-file.png")
        try Data([9, 9]).write(to: foreign)
        let cleared = try await store.clear(expectedEpoch: 2)
        #expect(cleared.entries.isEmpty)
        let late = try await store.add(image, source: "Area", template: "late", expectedEpoch: 1, retention: .init())
        #expect(late.entries.isEmpty); #expect(try Data(contentsOf: foreign) == Data([9, 9]))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("late.png").path))
    }
    @Test func successfulMigrationVerifiesImagesAndKeepsOriginalBackup() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root)
        let original = try await store.add(fixture.image(), source: "Area", template: "shot", expectedEpoch: 0, retention: .init())
        let entry = try #require(original.entries.first)
        let migrated = try await store.migrate(to: fixture.destination, expectedEpoch: 0)
        #expect(migrated.folder == fixture.destination); #expect(migrated.entries.map(\.id) == [entry.id])
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(entry.filename)) == Data(contentsOf: fixture.destination.appendingPathComponent(entry.filename)))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("history_metadata.json").path))
        let reloaded = try await HistoryRepository(root: fixture.destination).snapshot()
        #expect(reloaded.entries == migrated.entries)
    }
    @Test func destinationCollisionPreservesBothLibraries() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root)
        let original = try await store.add(fixture.image(), source: "Area", template: "shot", expectedEpoch: 0, retention: .init())
        let entry = try #require(original.entries.first)
        let foreign = fixture.destination.appendingPathComponent(entry.filename); try Data([7]).write(to: foreign)
        await #expect(throws: HistoryStorageError.self) { try await store.migrate(to: fixture.destination, expectedEpoch: 0) }
        #expect(try Data(contentsOf: foreign) == Data([7]))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("history_metadata.json").path))
        let state = try await store.snapshot(); #expect(state.folder == fixture.root && state.entries == original.entries)
    }
    @Test func failedPublishRollsBackOnlyCreatedDestinationFiles() async throws {
        enum Failure: Error { case injected }
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root, migrationPublishGate: { throw Failure.injected })
        let original = try await store.add(fixture.image(), source: "Area", template: "shot", expectedEpoch: 0, retention: .init())
        let unrelated = fixture.destination.appendingPathComponent("notes.txt"); try Data([4]).write(to: unrelated)
        await #expect(throws: Failure.self) { try await store.migrate(to: fixture.destination, expectedEpoch: 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path) == ["notes.txt"])
        #expect(try Data(contentsOf: unrelated) == Data([4]))
        let state = try await store.snapshot(); #expect(state.entries == original.entries)
    }
    @Test func corruptIndexIsPreservedAndNewImagesAreNotWritten() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let index = fixture.root.appendingPathComponent("history_metadata.json"), data = Data("broken index".utf8)
        try data.write(to: index)
        let store = HistoryRepository(root: fixture.root), image = try fixture.image()
        await #expect(throws: HistoryStorageError.self) { try await store.add(image, source: "Area", template: "shot", expectedEpoch: 0, retention: .init()) }
        #expect(try Data(contentsOf: index) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["history_metadata.json"])
    }
    @Test func pathTraversalInIndexCannotReadOrDeleteOutsideLibrary() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let victim = fixture.base.appendingPathComponent("victim.png"); try Data([8]).write(to: victim)
        let entry = HistoryEntry(filename: "../victim.png", date: Date(), source: "Area", width: 10, height: 10)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([entry]).write(to: fixture.root.appendingPathComponent("history_metadata.json"))
        let store = HistoryRepository(root: fixture.root)
        await #expect(throws: HistoryStorageError.self) { try await store.clear(expectedEpoch: 1) }
        #expect(try Data(contentsOf: victim) == Data([8]))
    }
    @Test func replacedImageSymlinkDoesNotDeleteItsTarget() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root)
        let initial = try await store.add(fixture.image(), source: "Area", template: "shot", expectedEpoch: 0, retention: .init())
        let entry = try #require(initial.entries.first), path = fixture.root.appendingPathComponent(entry.filename)
        let victim = fixture.base.appendingPathComponent("victim.png"); try Data([8]).write(to: victim)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: victim)
        let state = try await store.clear(expectedEpoch: 1)
        #expect(state.entries.isEmpty && state.pendingCleanup == 1)
        #expect(try Data(contentsOf: victim) == Data([8]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == victim.path)
    }
    @Test func externallyModifiedImageIsPreservedWithVisibleCleanupObligation() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root)
        let initial = try await store.add(fixture.image(), source: "Area", template: "shot", expectedEpoch: 0, retention: .init())
        let entry = try #require(initial.entries.first), path = fixture.root.appendingPathComponent(entry.filename)
        try Data([4, 5]).write(to: path)
        let state = try await store.clear(expectedEpoch: 1)
        #expect(state.pendingCleanup == 1); #expect(try Data(contentsOf: path) == Data([4, 5]))
        let reloaded = try await HistoryRepository(root: fixture.root).snapshot()
        #expect(reloaded.pendingCleanup == 1)
    }
    @Test func legacyArrayIndexLoadsWithoutConsentChanges() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let image = try fixture.image(), entry = HistoryEntry(filename: "legacy.png", date: Date(timeIntervalSince1970: 1000), source: "Area", width: 40, height: 30)
        try ExportService.encode(image.cgImage, options: .init()).write(to: fixture.root.appendingPathComponent(entry.filename))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode([entry]); try original.write(to: fixture.root.appendingPathComponent("history_metadata.json"))
        let state = try await HistoryRepository(root: fixture.root).snapshot()
        #expect(state.entries == [entry])
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("history_metadata.json")) == original)
    }
    @Test func nestedOrAncestorMigrationIsRejected() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root)
        await #expect(throws: HistoryStorageError.self) { try await store.migrate(to: fixture.root.appendingPathComponent("nested"), expectedEpoch: 0) }
        await #expect(throws: HistoryStorageError.self) { try await store.migrate(to: fixture.base, expectedEpoch: 0) }
    }
    @Test func historyRejectsImageExceedingConfiguredByteBudget() async throws {
        let fixture = try HistoryFixture(); defer { fixture.cleanup() }
        let store = HistoryRepository(root: fixture.root), image = try fixture.image()
        await #expect(throws: HistoryStorageError.self) { try await store.add(image, source: "Area", template: "shot", expectedEpoch: 0, retention: .init(maximumBytes: 1)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }
    @Test func ageAndByteRetentionUsesNewestFirstWithoutOverflow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = HistoryEntry(filename: "a.png", date: now, source: "Area", width: 1, height: 1, bytes: 60)
        let b = HistoryEntry(filename: "b.png", date: now.addingTimeInterval(-1), source: "Area", width: 1, height: 1, bytes: 60)
        let c = HistoryEntry(filename: "c.png", date: now.addingTimeInterval(-86_401), source: "Area", width: 1, height: 1, bytes: 1)
        let policy = HistoryRetentionPolicy(maximumCount: 10, maximumAgeDays: 1, maximumBytes: 100)
        #expect(policy.retained([b, c, a], sizes: [:], now: now).map(\.id) == [a.id])
        #expect(HistoryRetentionPolicy(maximumBytes: 100).retained([a], sizes: [a.id: .max], now: now).isEmpty)
    }
}
