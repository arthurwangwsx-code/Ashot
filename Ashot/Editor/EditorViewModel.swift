import SwiftUI
import AppKit

enum AnnotationTool: String, CaseIterable, Sendable {
    case select, arrow, line, rectangle, oval, freehand, text, counter
    case blur, pixelate, highlight, redact
    case crop, ruler, colorPicker, ocr, image

    var displayName: String {
        switch self {
        case .select: return L10n.string("Select")
        case .arrow: return L10n.string("Arrow")
        case .line: return L10n.string("Line")
        case .rectangle: return L10n.string("Rectangle")
        case .oval: return L10n.string("Oval")
        case .freehand: return L10n.string("Freehand")
        case .text: return L10n.string("Text")
        case .counter: return L10n.string("Step Counter")
        case .blur: return L10n.string("Blur")
        case .pixelate: return L10n.string("Pixelate")
        case .highlight: return L10n.string("Highlight")
        case .redact: return L10n.string("Solid Redaction")
        case .crop: return L10n.string("Crop")
        case .ruler: return L10n.string("Ruler")
        case .colorPicker: return L10n.string("Color Picker")
        case .ocr: return L10n.string("OCR")
        case .image: return L10n.string("Image Layer")
        }
    }
}

/// Coordinates are always in original-image points, even while the document is cropped.
/// Images are immutable after insertion, so undo frames share their pixel storage.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var type: AnnotationTool
    var startPoint: CGPoint
    var endPoint: CGPoint
    var points: [CGPoint]
    var color: Color
    var lineWidth: CGFloat
    var text: String
    var counterNumber: Int
    var image: NSImage?

    init(id: UUID = UUID(), type: AnnotationTool, startPoint: CGPoint, endPoint: CGPoint,
         points: [CGPoint], color: Color, lineWidth: CGFloat, text: String,
         counterNumber: Int, image: NSImage? = nil) {
        self.id = id
        self.type = type
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.counterNumber = counterNumber
        self.image = image
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type && lhs.startPoint == rhs.startPoint &&
        lhs.endPoint == rhs.endPoint && lhs.points == rhs.points && lhs.color == rhs.color &&
        lhs.lineWidth == rhs.lineWidth && lhs.text == rhs.text &&
        lhs.counterNumber == rhs.counterNumber && lhs.image === rhs.image
    }

    var boundingRect: CGRect {
        switch type {
        case .arrow, .line:
            return rectBetweenPoints.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .rectangle, .oval, .blur, .pixelate, .highlight, .redact, .image:
            return rectBetweenPoints
        case .freehand:
            guard let first = points.first else { return .zero }
            var bounds = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
            return bounds.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .text:
            let font = NSFont.systemFont(ofSize: max(5, lineWidth * 5))
            let lines = text.components(separatedBy: "\n")
            let width = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            return CGRect(origin: startPoint, size: CGSize(width: max(8, width), height: max(1, CGFloat(lines.count)) * font.pointSize * 1.25))
        case .counter:
            let radius = max(8, lineWidth * 14 / 3)
            return CGRect(x: startPoint.x - radius, y: startPoint.y - radius, width: radius * 2, height: radius * 2)
        default: return .zero
        }
    }

    var rectBetweenPoints: CGRect {
        CGRect(x: min(startPoint.x, endPoint.x), y: min(startPoint.y, endPoint.y),
               width: abs(endPoint.x - startPoint.x), height: abs(endPoint.y - startPoint.y))
    }

    func hitTest(point: CGPoint, tolerance: CGFloat) -> Bool {
        switch type {
        case .arrow, .line:
            return Self.distance(point, from: startPoint, to: endPoint) < tolerance + lineWidth
        case .rectangle:
            return boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) &&
                !boundingRect.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .oval:
            let rect = boundingRect
            guard rect.width > 0, rect.height > 0 else { return false }
            let dx = (point.x - rect.midX) / (rect.width / 2)
            let dy = (point.y - rect.midY) / (rect.height / 2)
            return (0.7...1.3).contains(dx * dx + dy * dy)
        case .freehand:
            return zip(points, points.dropFirst()).contains {
                Self.distance(point, from: $0.0, to: $0.1) < tolerance + lineWidth
            }
        case .text, .counter, .blur, .pixelate, .highlight, .redact, .image:
            return boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        default: return false
        }
    }

    private static func distance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squared))
        return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
    }

    mutating func translate(by delta: CGSize) {
        startPoint.x += delta.width; startPoint.y += delta.height
        endPoint.x += delta.width; endPoint.y += delta.height
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }
}

enum AnnotationGeometry {
    nonisolated static func constrainedEndpoint(start: CGPoint, end: CGPoint, tool: AnnotationTool, isShiftPressed: Bool) -> CGPoint {
        guard isShiftPressed else { return end }
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .arrow, .line:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: start.x + cos(angle) * hypot(dx, dy), y: start.y + sin(angle) * hypot(dx, dy))
        case .rectangle, .oval:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default: return end
        }
    }
}

enum ResizeHandle { case topLeft, topRight, bottomLeft, bottomRight }

struct CaptureDocument {
    let id: UUID
    var revision = UUID()
    let source: NSImage
    var annotations: [Annotation] = []
    var cropRect: CGRect?
    var background: ImageBackground?
    var counter = 1
    let sensitive: Bool

    init(image: NSImage, sensitive: Bool = false, id: UUID = UUID()) {
        self.id = id; source = image; self.sensitive = sensitive
    }

    var visibleRect: CGRect { cropRect ?? CGRect(origin: .zero, size: source.size) }
    var padding: CGFloat { background?.padding ?? 0 }
    var canvasSize: CGSize {
        CGSize(width: visibleRect.width + padding * 2, height: visibleRect.height + padding * 2)
    }
    var coordinateOrigin: CGPoint {
        CGPoint(x: visibleRect.minX - padding, y: visibleRect.minY - padding)
    }
    func hasSameContent(as other: Self) -> Bool {
        source === other.source && annotations == other.annotations && cropRect == other.cropRect &&
        background == other.background && counter == other.counter
    }
}

@MainActor
@Observable
final class EditorViewModel {
    private(set) var document: CaptureDocument
    private var undoFrames: [(CaptureDocument, String)] = []
    private var redoFrames: [(CaptureDocument, String)] = []
    private var transaction: (CaptureDocument, String)?
    private var exportedRevision: UUID
    private var defaultColor: Color = .red
    private var defaultWidth: CGFloat = 3
    private var previewCache: (UUID, CGFloat, NSImage)?
    private var recognitionID = UUID()
    private var recognitionJob: RecognitionJob?

    var selectedTool: AnnotationTool = .select
    var selectedAnnotationID: UUID?
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
    var rulerStart: CGPoint?
    var rulerEnd: CGPoint?
    var ocrText = ""
    var showOCRResult = false
    var isRecognizing = false
    var recognitionIsBarcode = false
    var recognitionError: String?
    var isExporting = false
    var feedback: String?
    var exportError: String?

    init(image: NSImage, sensitive: Bool = false) {
        let document = CaptureDocument(image: image, sensitive: sensitive)
        self.document = document
        exportedRevision = document.revision
    }

    var image: NSImage { document.source }
    var annotations: [Annotation] { document.annotations }
    var cropRect: CGRect? { document.cropRect }
    var canvasSize: CGSize { document.canvasSize }
    var coordinateOrigin: CGPoint { document.coordinateOrigin }
    var canUndo: Bool { !undoFrames.isEmpty }
    var canRedo: Bool { !redoFrames.isEmpty }
    var undoTitle: String { undoFrames.last?.1 ?? L10n.string("Undo") }
    var redoTitle: String { redoFrames.last?.1 ?? L10n.string("Redo") }
    var hasUnsavedChanges: Bool { exportedRevision != document.revision }
    var selectedAnnotation: Annotation? { annotations.first { $0.id == selectedAnnotationID } }
    var counterValue: Int { document.counter }

    var strokeColor: Color {
        get { selectedAnnotation?.color ?? defaultColor }
        set {
            defaultColor = newValue
            guard let id = selectedAnnotationID else { return }
            edit(L10n.string("Change Color")) { doc in
                guard let index = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
                doc.annotations[index].color = newValue
            }
        }
    }
    var strokeWidth: CGFloat {
        get { selectedAnnotation?.lineWidth ?? defaultWidth }
        set {
            let width = max(1, min(30, newValue))
            defaultWidth = width
            guard let id = selectedAnnotationID else { return }
            edit(L10n.string("Change Style")) { doc in
                guard let index = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
                doc.annotations[index].lineWidth = width
            }
        }
    }

    private func edit(_ title: String, _ body: (inout CaptureDocument) -> Void) {
        let old = document
        body(&document)
        guard !document.hasSameContent(as: old) else { return }
        document.revision = UUID()
        previewCache = nil
        cancelRecognition()
        if transaction == nil { appendUndo(old, title); redoFrames.removeAll() }
    }
    private func appendUndo(_ doc: CaptureDocument, _ title: String) {
        undoFrames.append((doc, title))
        if undoFrames.count > 100 { undoFrames.removeFirst(undoFrames.count - 100) }
    }
    func beginTransaction(_ title: String) {
        guard transaction == nil else { return }
        transaction = (document, title)
    }
    func endTransaction() {
        guard let (old, title) = transaction else { return }
        transaction = nil
        if document.hasSameContent(as: old) { document.revision = old.revision; return }
        appendUndo(old, title); redoFrames.removeAll()
    }
    func cancelTransaction() {
        guard let old = transaction?.0 else { return }
        transaction = nil; document = old; previewCache = nil
    }
    func undo() {
        endTransaction()
        guard let frame = undoFrames.popLast() else { return }
        redoFrames.append((document, frame.1)); restore(frame.0)
    }
    func redo() {
        endTransaction()
        guard let frame = redoFrames.popLast() else { return }
        appendUndo(document, frame.1); restore(frame.0)
    }
    private func restore(_ state: CaptureDocument) {
        document = state; selectedAnnotationID = nil; previewCache = nil
        zoomScale = 1; panOffset = .zero; cancelRecognition()
    }

    func addAnnotation(_ annotation: Annotation) {
        edit(L10n.string("Add Annotation")) { doc in
            doc.annotations.append(annotation)
            if annotation.type == .counter { doc.counter = max(doc.counter, annotation.counterNumber + 1) }
        }
    }
    func deleteSelected() {
        guard let id = selectedAnnotationID else { return }
        edit(L10n.string("Delete Annotation")) { $0.annotations.removeAll { $0.id == id } }
        selectedAnnotationID = nil
    }
    func duplicateSelected() {
        guard let original = selectedAnnotation else { return }
        var copy = Annotation(type: original.type, startPoint: original.startPoint, endPoint: original.endPoint,
                              points: original.points, color: original.color, lineWidth: original.lineWidth,
                              text: original.text, counterNumber: original.counterNumber, image: original.image)
        copy.translate(by: CGSize(width: 20, height: -20))
        addAnnotation(copy); selectedAnnotationID = copy.id
    }
    func updateSelectedText(_ text: String) {
        guard let id = selectedAnnotationID else { return }
        edit(L10n.string("Edit Text")) { doc in
            guard let i = doc.annotations.firstIndex(where: { $0.id == id && $0.type == .text }) else { return }
            doc.annotations[i].text = text
        }
    }
    func moveAnnotation(id: UUID, delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        edit(L10n.string("Move Annotation")) { doc in
            guard let i = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
            doc.annotations[i].translate(by: delta)
        }
    }
    func resizeAnnotation(id: UUID, handle: ResizeHandle, delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        edit(L10n.string("Resize Annotation")) { doc in
            guard let i = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
            let old = doc.annotations[i].boundingRect
            guard old.width > 0, old.height > 0 else { return }
            var minX = old.minX, maxX = old.maxX, minY = old.minY, maxY = old.maxY
            switch handle {
            case .topLeft: minX = min(maxX - 2, minX + delta.width); minY = min(maxY - 2, minY + delta.height)
            case .topRight: maxX = max(minX + 2, maxX + delta.width); minY = min(maxY - 2, minY + delta.height)
            case .bottomLeft: minX = min(maxX - 2, minX + delta.width); maxY = max(minY + 2, maxY + delta.height)
            case .bottomRight: maxX = max(minX + 2, maxX + delta.width); maxY = max(minY + 2, maxY + delta.height)
            }
            let sx = (maxX - minX) / old.width, sy = (maxY - minY) / old.height
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: minX + (p.x - old.minX) * sx, y: minY + (p.y - old.minY) * sy) }
            doc.annotations[i].startPoint = map(doc.annotations[i].startPoint)
            doc.annotations[i].endPoint = map(doc.annotations[i].endPoint)
            doc.annotations[i].points = doc.annotations[i].points.map(map)
            if [.text, .counter].contains(doc.annotations[i].type) {
                doc.annotations[i].lineWidth = max(1, min(100, doc.annotations[i].lineWidth * sy))
            }
        }
    }
    func hitTest(at point: CGPoint) -> UUID? {
        guard document.visibleRect.contains(point) else { return nil }
        return annotations.reversed().first { $0.hitTest(point: point, tolerance: 6) }?.id
    }
    func crop(to rect: CGRect) {
        guard AreaSelectionView.isFinite(rect) else { return }
        let clipped = rect.standardized.intersection(document.visibleRect)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        edit(L10n.string("Crop")) { $0.cropRect = clipped }
        selectedAnnotationID = nil; zoomScale = 1; panOffset = .zero
    }
    func resetCrop() { edit(L10n.string("Reset Crop")) { $0.cropRect = nil } }
    func applyBackground(_ background: ImageBackground?) {
        edit(L10n.string("Beautify")) { $0.background = background }
        zoomScale = 1; panOffset = .zero
    }
    func pasteImage(_ pastedImage: NSImage) {
        guard let snapshot = CapturedImageSnapshot(image: pastedImage),
              snapshot.cgImage.width * snapshot.cgImage.height <= 32_000_000,
              pastedImage.size.width > 0, pastedImage.size.height > 0 else {
            exportError = L10n.string("The image is invalid or too large to insert."); return
        }
        let rect = document.visibleRect
        let factor = min(1, rect.width * 0.8 / pastedImage.size.width, rect.height * 0.8 / pastedImage.size.height)
        let size = CGSize(width: pastedImage.size.width * factor, height: pastedImage.size.height * factor)
        let start = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        let annotation = Annotation(type: .image, startPoint: start,
                                    endPoint: CGPoint(x: start.x + size.width, y: start.y + size.height),
                                    points: [], color: .clear, lineWidth: 1, text: "", counterNumber: 0,
                                    image: NSImage(cgImage: snapshot.cgImage, size: pastedImage.size))
        addAnnotation(annotation); selectedTool = .select; selectedAnnotationID = annotation.id
    }

    func renderSnapshot() throws -> RenderSnapshot { try RenderSnapshot(document: document) }
    func renderFinalImage() throws -> NSImage {
        let snapshot = try renderSnapshot()
        return NSImage(cgImage: try CanvasRenderer.render(snapshot), size: canvasSize)
    }
    func previewImage(scale: CGFloat) throws -> NSImage {
        let boundedScale = max(0.05, min(2, scale))
        if let cache = previewCache, cache.0 == document.revision, cache.1 == boundedScale { return cache.2 }
        let result = NSImage(cgImage: try CanvasRenderer.render(renderSnapshot(), scale: boundedScale), size: canvasSize)
        previewCache = (document.revision, boundedScale, result)
        return result
    }

    func copyToClipboard() {
        guard !isExporting else { return }
        do {
            let snapshot = try renderSnapshot(), revision = document.revision
            isExporting = true
            Task {
                defer { isExporting = false }
                do {
                    let raster = try await Task.detached(priority: .userInitiated) { try CanvasRenderer.render(snapshot) }.value
                    let image = NSImage(cgImage: raster, size: snapshot.canvasSize)
                    let board = NSPasteboard.general
                    board.clearContents()
                    guard board.writeObjects([image]) else { throw ExportFailure.clipboardFailed }
                    exportedRevision = revision; feedback = L10n.string("Copied")
                } catch { exportError = error.localizedDescription }
            }
        } catch { exportError = error.localizedDescription }
    }
    func saveToFile(completion: ((Bool) -> Void)? = nil) {
        guard !isExporting else { completion?(false); return }
        do {
            let snapshot = try renderSnapshot(), revision = document.revision
            isExporting = true
            ExportService.chooseDestination { [weak self] selection in
                guard let self else { completion?(false); return }
                guard let (url, options) = selection else { self.isExporting = false; completion?(false); return }
                self.isExporting = true
                Task {
                    defer { self.isExporting = false }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            let raster = try CanvasRenderer.render(snapshot, scale: options.pixelScale(native: snapshot.nativeScale))
                            let data = try ExportService.encode(raster, options: options)
                            try data.write(to: url, options: .atomic)
                        }.value
                        self.exportedRevision = revision; self.feedback = L10n.string("Saved")
                        completion?(true)
                    } catch { self.exportError = error.localizedDescription; completion?(false) }
                }
            }
        } catch { exportError = error.localizedDescription; completion?(false) }
    }
    func pinAsFloating() {
        do { PinService.shared.pinImage(try renderFinalImage()) }
        catch { exportError = error.localizedDescription }
    }

    func performOCR(in selection: CGRect? = nil) { startRecognition(barcode: false, selection: selection) }
    func performQRDetection() { startRecognition(barcode: true, selection: nil) }
    private func startRecognition(barcode: Bool, selection: CGRect?) {
        cancelRecognition()
        let id = UUID(); recognitionID = id
        ocrText = ""; recognitionError = nil; recognitionIsBarcode = barcode
        showOCRResult = true; isRecognizing = true
        do {
            var input = document
            if let selection, AreaSelectionView.isFinite(selection) {
                let clipped = selection.intersection(document.visibleRect)
                guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { throw RenderFailure.invalidImage }
                input.cropRect = clipped; input.background = nil
            }
            let snapshot = try RenderSnapshot(document: input)
            let rendered = NSImage(cgImage: try CanvasRenderer.render(snapshot), size: input.canvasSize)
            let callback: @MainActor (Result<String, Error>) -> Void = { [weak self] result in
                guard let self, self.recognitionID == id else { return }
                self.isRecognizing = false; self.recognitionJob = nil
                switch result {
                case .success(let text): self.ocrText = text
                case .failure(let error): self.recognitionError = error.localizedDescription
                }
            }
            recognitionJob = barcode ? OCRService.recognizeBarcodes(in: rendered, completion: callback) :
                OCRService.recognizeText(in: rendered, completion: callback)
        } catch { isRecognizing = false; recognitionError = error.localizedDescription }
    }
    func cancelRecognition() {
        recognitionID = UUID(); recognitionJob?.cancel(); recognitionJob = nil
        isRecognizing = false
    }
    func closeRecognition() { cancelRecognition(); showOCRResult = false }
}
