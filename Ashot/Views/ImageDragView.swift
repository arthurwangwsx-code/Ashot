import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A real PNG file promise supports Finder, email, and apps expecting a file. No temporary
/// screenshot is written until the receiving application requests this explicit drag export.
struct ImageDragView: NSViewRepresentable {
    let image: NSImage
    var snapshotProvider: (() -> CapturedImageSnapshot?)?
    var onDragChanged: ((Bool) -> Void)?
    func makeNSView(context: Context) -> ImageDragNSView { ImageDragNSView() }
    func updateNSView(_ view: ImageDragNSView, context: Context) {
        view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
        view.snapshotProvider = snapshotProvider ?? { CapturedImageSnapshot(image: image) }
        view.onDragChanged = onDragChanged
        view.toolTip = L10n.string("Drag to export a PNG image")
        view.setAccessibilityLabel(L10n.string("Screenshot. Drag to export a PNG image."))
    }
}

final class ImageDragNSView: NSImageView, NSDraggingSource {
    var snapshotProvider: (() -> CapturedImageSnapshot?)?
    var onDragChanged: ((Bool) -> Void)?
    private var start: CGPoint?
    private var promiseID: UUID?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start, hypot(point.x - start.x, point.y - start.y) > 4,
              let snapshot = snapshotProvider?(), let payload = ImagePromisePayload.register(snapshot) else { return }
        self.start = nil; promiseID = payload.id
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: payload)
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: image)
        onDragChanged?(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty, let id = promiseID { ImagePromisePayload.release(id) }
        promiseID = nil; onDragChanged?(false)
    }
}

private final class ImagePromisePayload: NSObject, NSFilePromiseProviderDelegate {
    private static var retained: [UUID: ImagePromisePayload] = [:]
    nonisolated let id = UUID()
    nonisolated let snapshot: CapturedImageSnapshot
    init(snapshot: CapturedImageSnapshot) { self.snapshot = snapshot }
    static func register(_ snapshot: CapturedImageSnapshot) -> ImagePromisePayload? {
        let cost = snapshot.cgImage.width * snapshot.cgImage.height
        let total = retained.values.reduce(0) { $0 + $1.snapshot.cgImage.width * $1.snapshot.cgImage.height }
        guard retained.count < 8, total + cost <= 64_000_000 else {
            UserNotice.show("Finish the current image exports before starting another drag."); return nil
        }
        let payload = ImagePromisePayload(snapshot: snapshot); retained[payload.id] = payload
        // Abandoned file promises must not retain image buffers forever.
        let id = payload.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { retained.removeValue(forKey: id) }
        return payload
    }
    static func release(_ id: UUID) { retained.removeValue(forKey: id) }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "Ashot-\(id.uuidString.prefix(8)).png"
    }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                        completionHandler: @escaping (Error?) -> Void) {
        let snapshot = self.snapshot, id = self.id
        Task.detached(priority: .userInitiated) {
            do {
                let data = try ExportService.encode(snapshot.cgImage, options: ExportOptions(format: .png))
                // The receiver reserves the destination; never overwrite a file already present.
                try AtomicFileWriter.writeExclusive(data, to: url)
                completionHandler(nil)
            } catch { completionHandler(error) }
            await MainActor.run { ImagePromisePayload.release(id) }
        }
    }
}
