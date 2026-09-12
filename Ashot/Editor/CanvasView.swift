import SwiftUI
import AppKit

struct CanvasView: NSViewRepresentable {
    var viewModel: EditorViewModel
    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(viewModel: viewModel) }
    func updateNSView(_ view: CanvasNSView, context: Context) {
        // Register observable reads so toolbar edits also invalidate the AppKit canvas.
        _ = viewModel.document.revision; _ = viewModel.selectedAnnotationID
        _ = viewModel.zoomScale; _ = viewModel.panOffset; _ = viewModel.selectedTool
        view.viewModel = viewModel; view.needsDisplay = true
    }
}

final class CanvasNSView: NSView, NSTextFieldDelegate {
    var viewModel: EditorViewModel
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var constrained = false
    private var freehand: [CGPoint] = []
    private var draggingID: UUID?
    private var resizeHandle: ResizeHandle?
    private var previousPoint: CGPoint?
    private var textField: NSTextField?
    private var editingTextID: UUID?
    private var textOrigin: CGPoint?

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Screenshot canvas. Use the toolbar to select a tool."))
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    private var scale: CGFloat {
        let size = viewModel.canvasSize
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(0.001, min(bounds.width / size.width, bounds.height / size.height, 1) * viewModel.zoomScale)
    }
    private var imageRect: CGRect {
        let size = CGSize(width: viewModel.canvasSize.width * scale, height: viewModel.canvasSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2 + viewModel.panOffset.width,
                      y: (bounds.height - size.height) / 2 + viewModel.panOffset.height, width: size.width, height: size.height)
    }
    private func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - imageRect.minX) / scale + viewModel.coordinateOrigin.x,
                y: (point.y - imageRect.minY) / scale + viewModel.coordinateOrigin.y)
    }
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + (point.x - viewModel.coordinateOrigin.x) * scale,
                y: imageRect.minY + (point.y - viewModel.coordinateOrigin.y) * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        do {
            try viewModel.previewImage(scale: scale * (window?.backingScaleFactor ?? 2)).draw(in: imageRect)
        } catch {
            (error.localizedDescription as NSString).draw(in: bounds.insetBy(dx: 24, dy: 24),
                withAttributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 14)])
        }
        if let annotation = viewModel.selectedAnnotation { drawHandles(annotation) }
        if let start = dragStart, let current = dragCurrent, draggingID == nil { drawDrag(start: start, end: current) }
        if let start = viewModel.rulerStart, let end = viewModel.rulerEnd { drawRuler(start, end) }
    }

    private func handles(_ a: Annotation) -> [(ResizeHandle, CGPoint)] {
        let r = a.boundingRect
        return [(.topLeft, viewPoint(CGPoint(x: r.minX, y: r.minY))),
                (.topRight, viewPoint(CGPoint(x: r.maxX, y: r.minY))),
                (.bottomLeft, viewPoint(CGPoint(x: r.minX, y: r.maxY))),
                (.bottomRight, viewPoint(CGPoint(x: r.maxX, y: r.maxY)))]
    }
    private func drawHandles(_ a: Annotation) {
        let points = handles(a).map(\.1)
        let frame = NSRect(x: points[0].x, y: points[0].y, width: points[3].x - points[0].x, height: points[3].y - points[0].y)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: frame); path.lineWidth = 1; path.setLineDash([3, 3], count: 2, phase: 0); path.stroke()
        for point in points {
            let knob = NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            NSColor.windowBackgroundColor.setFill(); knob.fill(); knob.stroke()
        }
    }
    private func drawDrag(start: CGPoint, end: CGPoint) {
        let a = viewPoint(start)
        let constrainedEnd = AnnotationGeometry.constrainedEndpoint(start: start, end: end,
            tool: viewModel.selectedTool, isShiftPressed: constrained)
        let b = viewPoint(constrainedEnd)
        let path = NSBezierPath()
        path.lineWidth = max(1, viewModel.strokeWidth * scale); path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor(viewModel.strokeColor).setStroke()
        switch viewModel.selectedTool {
        case .arrow, .line: path.move(to: a); path.line(to: b)
        case .freehand:
            guard let first = freehand.first else { return }
            path.move(to: viewPoint(first)); for point in freehand.dropFirst() { path.line(to: viewPoint(point)) }
        case .rectangle, .oval, .blur, .pixelate, .highlight, .crop, .redact, .ocr:
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            if viewModel.selectedTool == .oval { path.appendOval(in: rect) } else { path.appendRect(rect) }
            if [.crop, .ocr].contains(viewModel.selectedTool) { path.setLineDash([4, 4], count: 2, phase: 0) }
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); path.fill()
        default: return
        }
        path.stroke()
    }
    private func drawRuler(_ start: CGPoint, _ end: CGPoint) {
        let a = viewPoint(start), b = viewPoint(end)
        NSColor.controlAccentColor.setStroke()
        let line = NSBezierPath(); line.lineWidth = 1.5; line.move(to: a); line.line(to: b); line.stroke()
        let points = hypot(end.x - start.x, end.y - start.y)
        let nativeScale = (try? viewModel.renderSnapshot().nativeScale) ?? 1
        let text = String(format: "%.0f pt / %.0f px", points, points * nativeScale)
        (text as NSString).draw(at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 10),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                             .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.windowBackgroundColor])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let image = imagePoint(point)
        if viewModel.selectedTool == .select {
            if let selected = viewModel.selectedAnnotation,
               let handle = handles(selected).first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) < 10 })?.0 {
                draggingID = selected.id; resizeHandle = handle; previousPoint = image
                viewModel.beginTransaction(L10n.string("Resize Annotation")); return
            }
            viewModel.selectedAnnotationID = viewModel.hitTest(at: image)
            if let selected = viewModel.selectedAnnotation {
                if event.clickCount == 2, selected.type == .text { beginText(at: selected.startPoint, annotation: selected); return }
                draggingID = selected.id; previousPoint = image
                viewModel.beginTransaction(L10n.string("Move Annotation")); needsDisplay = true; return
            }
        }
        guard viewModel.document.visibleRect.contains(image) else { needsDisplay = true; return }
        dragStart = image; dragCurrent = image
        switch viewModel.selectedTool {
        case .text: beginText(at: image, annotation: nil)
        case .counter:
            viewModel.addAnnotation(Annotation(type: .counter, startPoint: image, endPoint: image, points: [],
                color: viewModel.strokeColor, lineWidth: viewModel.strokeWidth, text: "", counterNumber: viewModel.counterValue))
        case .freehand: freehand = [image]
        case .ruler: viewModel.rulerStart = image; viewModel.rulerEnd = nil
        case .colorPicker: pickColor(at: image)
        default: break
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        if let id = draggingID, let previous = previousPoint {
            let delta = CGSize(width: point.x - previous.x, height: point.y - previous.y)
            if let handle = resizeHandle { viewModel.resizeAnnotation(id: id, handle: handle, delta: delta) }
            else { viewModel.moveAnnotation(id: id, delta: delta) }
            previousPoint = point
        } else {
            dragCurrent = point; constrained = event.modifierFlags.contains(.shift)
            if viewModel.selectedTool == .freehand { freehand.append(point) }
            if viewModel.selectedTool == .ruler { viewModel.rulerEnd = point }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { resetDrag(); needsDisplay = true }
        if draggingID != nil { viewModel.endTransaction(); return }
        guard let start = dragStart else { return }
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        let end = AnnotationGeometry.constrainedEndpoint(start: start, end: point, tool: viewModel.selectedTool,
                                                          isShiftPressed: event.modifierFlags.contains(.shift))
        let area = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch viewModel.selectedTool {
        case .arrow, .line, .rectangle, .oval, .blur, .pixelate, .highlight, .redact:
            guard area.width > 2 || area.height > 2 else { return }
            viewModel.addAnnotation(Annotation(type: viewModel.selectedTool, startPoint: start, endPoint: end, points: [],
                color: viewModel.strokeColor, lineWidth: viewModel.strokeWidth, text: "", counterNumber: 0))
        case .freehand:
            guard freehand.count > 1, let first = freehand.first, let last = freehand.last else { return }
            viewModel.addAnnotation(Annotation(type: .freehand, startPoint: first, endPoint: last, points: freehand,
                color: viewModel.strokeColor, lineWidth: viewModel.strokeWidth, text: "", counterNumber: 0))
        case .crop: if area.width > 2, area.height > 2 { viewModel.crop(to: area) }
        case .ocr: viewModel.performOCR(in: area.width > 3 && area.height > 3 ? area : nil)
        case .ruler: viewModel.rulerEnd = end
        default: break
        }
    }
    private func resetDrag() {
        draggingID = nil; resizeHandle = nil; previousPoint = nil
        dragStart = nil; dragCurrent = nil; freehand.removeAll(); constrained = false
    }
    override func scrollWheel(with event: NSEvent) {
        guard textField == nil else { return }
        if event.modifierFlags.contains(.command) {
            viewModel.zoomScale = max(0.1, min(8, viewModel.zoomScale * (event.scrollingDeltaY > 0 ? 1.1 : 0.9)))
        } else { viewModel.panOffset.width += event.scrollingDeltaX; viewModel.panOffset.height -= event.scrollingDeltaY }
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard textField == nil else { return }
        viewModel.zoomScale = max(0.1, min(8, viewModel.zoomScale * (1 + event.magnification))); needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            viewModel.cancelTransaction(); resetDrag(); cancelText()
            viewModel.selectedAnnotationID = nil; viewModel.rulerStart = nil; viewModel.rulerEnd = nil
        } else if event.keyCode == 51 || event.keyCode == 117 { viewModel.deleteSelected() }
        else if let id = viewModel.selectedAnnotationID, (123...126).contains(event.keyCode) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGSize
            switch event.keyCode {
            case 123: delta = CGSize(width: -step, height: 0)
            case 124: delta = CGSize(width: step, height: 0)
            case 125: delta = CGSize(width: 0, height: -step)
            default: delta = CGSize(width: 0, height: step)
            }
            viewModel.moveAnnotation(id: id, delta: delta)
        } else { super.keyDown(with: event) }
        needsDisplay = true
    }

    private func beginText(at point: CGPoint, annotation: Annotation?) {
        cancelText()
        let display = viewPoint(point)
        let field = NSTextField(frame: CGRect(x: display.x, y: display.y, width: max(220, annotation?.boundingRect.width ?? 0), height: 28))
        field.font = .systemFont(ofSize: max(12, (annotation?.lineWidth ?? viewModel.strokeWidth) * 5 * scale))
        field.stringValue = annotation?.text ?? ""; field.placeholderString = L10n.string("Type text...")
        field.delegate = self; field.target = self; field.action = #selector(commitText(_:))
        field.setAccessibilityLabel(L10n.string("Annotation Text"))
        textOrigin = point; editingTextID = annotation?.id; textField = field
        addSubview(field); window?.makeFirstResponder(field)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { commitText(field) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelText(); window?.makeFirstResponder(self); return true }
        return false
    }
    @objc private func commitText(_ sender: NSTextField) {
        guard sender === textField, let origin = textOrigin else { return }
        let text = String(sender.stringValue.prefix(100_000))
        if let id = editingTextID {
            viewModel.selectedAnnotationID = id; viewModel.updateSelectedText(text)
        } else if !text.isEmpty {
            viewModel.addAnnotation(Annotation(type: .text, startPoint: origin, endPoint: origin, points: [],
                color: viewModel.strokeColor, lineWidth: viewModel.strokeWidth, text: text, counterNumber: 0))
        }
        cancelText(); needsDisplay = true
    }
    private func cancelText() {
        let old = textField; textField = nil; editingTextID = nil; textOrigin = nil
        old?.delegate = nil; old?.removeFromSuperview()
    }
    private func pickColor(at point: CGPoint) {
        do {
            let rendered = try viewModel.renderFinalImage()
            guard let bitmap = rendered.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return }
            let local = CGPoint(x: point.x - viewModel.coordinateOrigin.x, y: point.y - viewModel.coordinateOrigin.y)
            let x = Int(floor(local.x / viewModel.canvasSize.width * CGFloat(bitmap.pixelsWide)))
            let y = bitmap.pixelsHigh - 1 - Int(floor(local.y / viewModel.canvasSize.height * CGFloat(bitmap.pixelsHigh)))
            guard let raster = bitmap.cgImage, let sample = RasterColorSampler.sample(raster, x: x, yFromTop: y) else { return }
            let color = NSColor(srgbRed: sample.red, green: sample.green, blue: sample.blue, alpha: sample.alpha)
            let format = ColorFormat(rawValue: UserDefaults.standard.string(forKey: "colorFormat") ?? "HEX") ?? .hex
            let text = ColorPickerService.shared.formatColor(color, format: format)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            viewModel.feedback = L10n.string("Copied") + " " + text
        } catch { viewModel.exportError = error.localizedDescription }
    }
}
