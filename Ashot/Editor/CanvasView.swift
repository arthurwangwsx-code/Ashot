import SwiftUI
import AppKit

struct CanvasView: NSViewRepresentable {
    var viewModel: EditorViewModel

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView(viewModel: viewModel)
        return view
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.viewModel = viewModel
        nsView.needsDisplay = true
    }
}

final class CanvasNSView: NSView {
    var viewModel: EditorViewModel
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var dragUsesConstraint = false
    private var freehandPoints: [CGPoint] = []
    private var textField: NSTextField?

    private var isDraggingAnnotation = false
    private var draggedAnnotationID: UUID?
    private var dragAnnotationStart: CGPoint?
    private var activeResizeHandle: ResizeHandle?

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private var imageRect: NSRect {
        let imageSize = viewModel.image.size
        let viewSize = bounds.size
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height, 1.0)
        let scale = baseScale * viewModel.zoomScale
        let scaledSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = NSPoint(
            x: (viewSize.width - scaledSize.width) / 2 + viewModel.panOffset.width,
            y: (viewSize.height - scaledSize.height) / 2 + viewModel.panOffset.height
        )
        return NSRect(origin: origin, size: scaledSize)
    }

    private func imagePoint(from viewPoint: NSPoint) -> NSPoint {
        let rect = imageRect
        let imageSize = viewModel.image.size
        return NSPoint(
            x: (viewPoint.x - rect.origin.x) / rect.width * imageSize.width,
            y: (viewPoint.y - rect.origin.y) / rect.height * imageSize.height
        )
    }

    private func viewPoint(from imgPoint: NSPoint) -> NSPoint {
        let rect = imageRect
        let imageSize = viewModel.image.size
        return NSPoint(
            x: rect.origin.x + imgPoint.x / imageSize.width * rect.width,
            y: rect.origin.y + imgPoint.y / imageSize.height * rect.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()

        let rect = imageRect
        viewModel.image.draw(in: rect)

        let scaleX = rect.width / viewModel.image.size.width
        let scaleY = rect.height / viewModel.image.size.height

        NSGraphicsContext.current?.saveGraphicsState()

        for annotation in viewModel.annotations {
            drawAnnotationInView(annotation, scaleX: scaleX, scaleY: scaleY, origin: rect.origin)
        }

        if let selectedID = viewModel.selectedAnnotationID,
           let annotation = viewModel.annotations.first(where: { $0.id == selectedID }) {
            drawSelectionHandles(for: annotation, scaleX: scaleX, scaleY: scaleY, origin: rect.origin)
        }

        if let start = dragStart, let current = dragCurrent, !isDraggingAnnotation {
            drawCurrentDrag(start: start, current: current)
        }

        NSGraphicsContext.current?.restoreGraphicsState()

        if viewModel.selectedTool == .ruler, let start = viewModel.rulerStart, let end = viewModel.rulerEnd {
            drawRuler(from: start, to: end, scaleX: scaleX, scaleY: scaleY, origin: rect.origin)
        }
    }

    private func drawSelectionHandles(for annotation: Annotation, scaleX: CGFloat, scaleY: CGFloat, origin: NSPoint) {
        let bbox = annotation.boundingRect
        let topLeft = NSPoint(x: origin.x + bbox.minX * scaleX, y: origin.y + bbox.minY * scaleY)
        let topRight = NSPoint(x: origin.x + bbox.maxX * scaleX, y: origin.y + bbox.minY * scaleY)
        let bottomLeft = NSPoint(x: origin.x + bbox.minX * scaleX, y: origin.y + bbox.maxY * scaleY)
        let bottomRight = NSPoint(x: origin.x + bbox.maxX * scaleX, y: origin.y + bbox.maxY * scaleY)

        let borderRect = NSRect(
            x: topLeft.x, y: topLeft.y,
            width: topRight.x - topLeft.x,
            height: bottomLeft.y - topLeft.y
        )
        let borderPath = NSBezierPath(rect: borderRect)
        borderPath.lineWidth = 1
        NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
        borderPath.setLineDash([3, 3], count: 2, phase: 0)
        borderPath.stroke()

        let handleSize: CGFloat = 8
        for point in [topLeft, topRight, bottomLeft, bottomRight] {
            let handleRect = NSRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2, width: handleSize, height: handleSize)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handleRect).fill()
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(ovalIn: handleRect)
            border.lineWidth = 1.5
            border.stroke()
        }
    }

    private func hitTestHandle(at point: CGPoint, scaleX: CGFloat, scaleY: CGFloat, origin: NSPoint) -> ResizeHandle? {
        guard let selectedID = viewModel.selectedAnnotationID,
              let annotation = viewModel.annotations.first(where: { $0.id == selectedID }) else { return nil }

        let bbox = annotation.boundingRect
        let handles: [(ResizeHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: origin.x + bbox.minX * scaleX, y: origin.y + bbox.minY * scaleY)),
            (.topRight, CGPoint(x: origin.x + bbox.maxX * scaleX, y: origin.y + bbox.minY * scaleY)),
            (.bottomLeft, CGPoint(x: origin.x + bbox.minX * scaleX, y: origin.y + bbox.maxY * scaleY)),
            (.bottomRight, CGPoint(x: origin.x + bbox.maxX * scaleX, y: origin.y + bbox.maxY * scaleY))
        ]

        for (handle, handlePoint) in handles {
            if hypot(point.x - handlePoint.x, point.y - handlePoint.y) < 10 {
                return handle
            }
        }
        return nil
    }

    private func drawAnnotationInView(_ annotation: Annotation, scaleX: CGFloat, scaleY: CGFloat, origin: NSPoint) {
        let nsColor = NSColor(annotation.color)
        nsColor.setStroke()
        nsColor.setFill()

        let transformPoint = { (p: CGPoint) -> CGPoint in
            CGPoint(x: origin.x + p.x * scaleX, y: origin.y + p.y * scaleY)
        }

        switch annotation.type {
        case .arrow:
            let start = transformPoint(annotation.startPoint)
            let end = transformPoint(annotation.endPoint)
            let path = NSBezierPath()
            path.lineWidth = annotation.lineWidth
            path.move(to: start)
            path.line(to: end)
            path.stroke()
            drawArrowheadInView(from: start, to: end, color: nsColor)

        case .line:
            let start = transformPoint(annotation.startPoint)
            let end = transformPoint(annotation.endPoint)
            let path = NSBezierPath()
            path.lineWidth = annotation.lineWidth
            path.lineCapStyle = .round
            path.move(to: start)
            path.line(to: end)
            path.stroke()

        case .rectangle:
            let p1 = transformPoint(annotation.startPoint)
            let p2 = transformPoint(annotation.endPoint)
            let rect = NSRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
            let path = NSBezierPath(rect: rect)
            path.lineWidth = annotation.lineWidth
            path.stroke()

        case .oval:
            let p1 = transformPoint(annotation.startPoint)
            let p2 = transformPoint(annotation.endPoint)
            let rect = NSRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = annotation.lineWidth
            path.stroke()

        case .freehand:
            guard annotation.points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = annotation.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let first = transformPoint(annotation.points[0])
            path.move(to: first)
            for point in annotation.points.dropFirst() {
                path.line(to: transformPoint(point))
            }
            path.stroke()

        case .text:
            let pos = transformPoint(annotation.startPoint)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: annotation.lineWidth * 5 * scaleX),
                .foregroundColor: nsColor
            ]
            (annotation.text as NSString).draw(at: pos, withAttributes: attrs)

        case .counter:
            let center = transformPoint(annotation.startPoint)
            let radius: CGFloat = 14 * scaleX
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            circle.fill()
            let text = "\(annotation.counterNumber)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 14 * scaleX),
                .foregroundColor: NSColor.white
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)

        case .blur:
            let p1 = transformPoint(annotation.startPoint)
            let p2 = transformPoint(annotation.endPoint)
            let rect = NSRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: rect).fill()

        case .pixelate:
            let p1 = transformPoint(annotation.startPoint)
            let p2 = transformPoint(annotation.endPoint)
            let rect = NSRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
            drawPixelatePlaceholder(in: rect)

        case .highlight:
            let p1 = transformPoint(annotation.startPoint)
            let p2 = transformPoint(annotation.endPoint)
            let rect = NSRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
            nsColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: rect).fill()

        default:
            break
        }
    }

    private func drawCurrentDrag(start: CGPoint, current: CGPoint) {
        let nsColor = NSColor(viewModel.strokeColor)
        nsColor.setStroke()
        let constrainedCurrent = AnnotationGeometry.constrainedEndpoint(
            start: start,
            end: current,
            tool: viewModel.selectedTool,
            isShiftPressed: dragUsesConstraint
        )

        switch viewModel.selectedTool {
        case .arrow:
            let path = NSBezierPath()
            path.lineWidth = viewModel.strokeWidth
            path.move(to: start)
            path.line(to: constrainedCurrent)
            path.stroke()
            drawArrowheadInView(from: start, to: constrainedCurrent, color: nsColor)

        case .line:
            let path = NSBezierPath()
            path.lineWidth = viewModel.strokeWidth
            path.lineCapStyle = .round
            path.move(to: start)
            path.line(to: constrainedCurrent)
            path.stroke()

        case .rectangle:
            let rect = NSRect(x: min(start.x, constrainedCurrent.x), y: min(start.y, constrainedCurrent.y), width: abs(constrainedCurrent.x - start.x), height: abs(constrainedCurrent.y - start.y))
            let path = NSBezierPath(rect: rect)
            path.lineWidth = viewModel.strokeWidth
            path.stroke()

        case .oval:
            let rect = NSRect(x: min(start.x, constrainedCurrent.x), y: min(start.y, constrainedCurrent.y), width: abs(constrainedCurrent.x - start.x), height: abs(constrainedCurrent.y - start.y))
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = viewModel.strokeWidth
            path.stroke()

        case .freehand:
            guard freehandPoints.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = viewModel.strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: freehandPoints[0])
            for point in freehandPoints.dropFirst() {
                path.line(to: point)
            }
            path.stroke()

        case .blur, .pixelate, .highlight, .crop:
            let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            NSColor.white.withAlphaComponent(0.2).setFill()
            NSBezierPath(rect: rect).fill()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.setLineDash([4, 4], count: 2, phase: 0)
            border.stroke()

        default:
            break
        }
    }

    private func drawArrowheadInView(from start: CGPoint, to end: CGPoint, color: NSColor) {
        let arrowLength: CGFloat = 15
        let arrowAngle: CGFloat = .pi / 6
        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)

        let path = NSBezierPath()
        path.move(to: end)
        path.line(to: NSPoint(x: end.x - arrowLength * cos(angle - arrowAngle), y: end.y - arrowLength * sin(angle - arrowAngle)))
        path.line(to: NSPoint(x: end.x - arrowLength * cos(angle + arrowAngle), y: end.y - arrowLength * sin(angle + arrowAngle)))
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawPixelatePlaceholder(in rect: NSRect) {
        NSColor.gray.withAlphaComponent(0.55).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let grid = NSBezierPath()
        let cell: CGFloat = 8
        var x = rect.minX + cell
        while x < rect.maxX {
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.line(to: CGPoint(x: x, y: rect.maxY))
            x += cell
        }
        var y = rect.minY + cell
        while y < rect.maxY {
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.line(to: CGPoint(x: rect.maxX, y: y))
            y += cell
        }
        grid.lineWidth = 0.5
        grid.stroke()
    }

    private func drawRuler(from start: CGPoint, to end: CGPoint, scaleX: CGFloat, scaleY: CGFloat, origin: NSPoint) {
        let viewStart = NSPoint(x: origin.x + start.x * scaleX, y: origin.y + start.y * scaleY)
        let viewEnd = NSPoint(x: origin.x + end.x * scaleX, y: origin.y + end.y * scaleY)

        NSColor.systemYellow.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: viewStart)
        path.line(to: viewEnd)
        path.stroke()

        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = sqrt(dx * dx + dy * dy)

        let text = String(format: "%.0f px", distance)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.systemYellow,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let midPoint = NSPoint(x: (viewStart.x + viewEnd.x) / 2, y: (viewStart.y + viewEnd.y) / 2 + 10)
        (text as NSString).draw(at: midPoint, withAttributes: attrs)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let imgPoint = imagePoint(from: point)
        let rect = imageRect
        let scaleX = rect.width / viewModel.image.size.width
        let scaleY = rect.height / viewModel.image.size.height

        if viewModel.selectedTool == .select {
            if let handle = hitTestHandle(at: point, scaleX: scaleX, scaleY: scaleY, origin: rect.origin) {
                activeResizeHandle = handle
                isDraggingAnnotation = true
                dragAnnotationStart = imgPoint
                return
            }

            if let hitID = viewModel.hitTest(at: imgPoint) {
                viewModel.selectedAnnotationID = hitID
                isDraggingAnnotation = true
                draggedAnnotationID = hitID
                dragAnnotationStart = imgPoint
                needsDisplay = true
                return
            } else {
                viewModel.selectedAnnotationID = nil
                needsDisplay = true
            }
        }

        dragStart = point
        dragCurrent = point

        switch viewModel.selectedTool {
        case .freehand:
            freehandPoints = [point]
        case .text:
            showTextField(at: point)
        case .counter:
            let annotation = Annotation(
                type: .counter,
                startPoint: imgPoint,
                endPoint: imgPoint,
                points: [],
                color: viewModel.strokeColor,
                lineWidth: viewModel.strokeWidth,
                text: "",
                counterNumber: viewModel.counterValue
            )
            viewModel.addAnnotation(annotation)
            viewModel.counterValue += 1
            needsDisplay = true
        case .ruler:
            viewModel.rulerStart = imgPoint
            viewModel.rulerEnd = nil
        case .colorPicker:
            pickColor(at: point)
        case .ocr:
            viewModel.performOCR()
            viewModel.performQRDetection()
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let imgPoint = imagePoint(from: point)

        if isDraggingAnnotation {
            guard let startPt = dragAnnotationStart else { return }
            let delta = CGSize(width: imgPoint.x - startPt.x, height: imgPoint.y - startPt.y)

            if let handle = activeResizeHandle, let id = viewModel.selectedAnnotationID {
                viewModel.resizeAnnotation(id: id, handle: handle, delta: delta)
            } else if let id = draggedAnnotationID {
                viewModel.moveAnnotation(id: id, delta: delta)
            }
            dragAnnotationStart = imgPoint
            needsDisplay = true
            return
        }

        dragCurrent = point
        dragUsesConstraint = event.modifierFlags.contains(.shift)

        switch viewModel.selectedTool {
        case .freehand:
            freehandPoints.append(point)
        case .ruler:
            viewModel.rulerEnd = imgPoint
        default:
            break
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDraggingAnnotation {
            isDraggingAnnotation = false
            draggedAnnotationID = nil
            dragAnnotationStart = nil
            activeResizeHandle = nil
            needsDisplay = true
            return
        }

        dragCurrent = point
        guard let start = dragStart else { return }

        let imgStart = imagePoint(from: start)
        let rawImgEnd = imagePoint(from: point)
        let imgEnd = AnnotationGeometry.constrainedEndpoint(
            start: imgStart,
            end: rawImgEnd,
            tool: viewModel.selectedTool,
            isShiftPressed: event.modifierFlags.contains(.shift)
        )

        switch viewModel.selectedTool {
        case .arrow, .line, .rectangle, .oval:
            if abs(imgEnd.x - imgStart.x) > 2 || abs(imgEnd.y - imgStart.y) > 2 {
                let annotation = Annotation(
                    type: viewModel.selectedTool,
                    startPoint: imgStart,
                    endPoint: imgEnd,
                    points: [],
                    color: viewModel.strokeColor,
                    lineWidth: viewModel.strokeWidth,
                    text: "",
                    counterNumber: 0
                )
                viewModel.addAnnotation(annotation)
            }

        case .freehand:
            if freehandPoints.count > 2 {
                let imgPoints = freehandPoints.map { imagePoint(from: $0) }
                guard let firstPoint = imgPoints.first, let lastPoint = imgPoints.last else {
                    freehandPoints.removeAll()
                    return
                }
                let annotation = Annotation(
                    type: .freehand,
                    startPoint: firstPoint,
                    endPoint: lastPoint,
                    points: imgPoints,
                    color: viewModel.strokeColor,
                    lineWidth: viewModel.strokeWidth,
                    text: "",
                    counterNumber: 0
                )
                viewModel.addAnnotation(annotation)
            }
            freehandPoints.removeAll()

        case .blur, .pixelate, .highlight:
            if abs(imgEnd.x - imgStart.x) > 2 || abs(imgEnd.y - imgStart.y) > 2 {
                let annotation = Annotation(
                    type: viewModel.selectedTool,
                    startPoint: imgStart,
                    endPoint: imgEnd,
                    points: [],
                    color: viewModel.strokeColor,
                    lineWidth: viewModel.strokeWidth,
                    text: "",
                    counterNumber: 0
                )
                viewModel.addAnnotation(annotation)
            }

        case .crop:
            if abs(imgEnd.x - imgStart.x) > 5 || abs(imgEnd.y - imgStart.y) > 5 {
                applyCrop(from: imgStart, to: imgEnd)
            }

        case .ruler:
            viewModel.rulerEnd = imgEnd

        default:
            break
        }

        dragStart = nil
        dragCurrent = nil
        dragUsesConstraint = false
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY > 0 ? 1.1 : 0.9
            viewModel.zoomScale = max(0.25, min(5.0, viewModel.zoomScale * delta))
        } else {
            viewModel.panOffset.width += event.scrollingDeltaX
            viewModel.panOffset.height -= event.scrollingDeltaY
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        viewModel.zoomScale = max(0.25, min(5.0, viewModel.zoomScale * (1 + event.magnification)))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            dragStart = nil
            dragCurrent = nil
            dragUsesConstraint = false
            freehandPoints.removeAll()
            viewModel.rulerStart = nil
            viewModel.rulerEnd = nil
            viewModel.selectedAnnotationID = nil
            needsDisplay = true
        } else if event.keyCode == 51 || event.keyCode == 117 { // Delete/Backspace
            viewModel.deleteSelected()
            needsDisplay = true
        } else if event.characters == "d" && event.modifierFlags.contains(.command) {
            viewModel.duplicateSelected()
            needsDisplay = true
        } else if event.characters == "0" && event.modifierFlags.contains(.command) {
            viewModel.zoomScale = 1.0
            viewModel.panOffset = .zero
            needsDisplay = true
        } else if event.characters == "+" && event.modifierFlags.contains(.command) {
            viewModel.zoomScale = min(5.0, viewModel.zoomScale * 1.25)
            needsDisplay = true
        } else if event.characters == "-" && event.modifierFlags.contains(.command) {
            viewModel.zoomScale = max(0.25, viewModel.zoomScale / 1.25)
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Helpers

    private func showTextField(at point: CGPoint) {
        textField?.removeFromSuperview()

        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 12, width: 200, height: 24))
        field.font = .systemFont(ofSize: viewModel.strokeWidth * 5)
        field.textColor = NSColor(viewModel.strokeColor)
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Type text..."
        field.target = self
        field.action = #selector(textFieldDone(_:))
        addSubview(field)
        field.becomeFirstResponder()
        textField = field
    }

    @objc private func textFieldDone(_ sender: NSTextField) {
        let text = sender.stringValue
        guard !text.isEmpty else {
            sender.removeFromSuperview()
            textField = nil
            return
        }

        let point = NSPoint(x: sender.frame.origin.x, y: sender.frame.origin.y + 12)
        let imgPoint = imagePoint(from: point)

        let annotation = Annotation(
            type: .text,
            startPoint: imgPoint,
            endPoint: imgPoint,
            points: [],
            color: viewModel.strokeColor,
            lineWidth: viewModel.strokeWidth,
            text: text,
            counterNumber: 0
        )
        viewModel.addAnnotation(annotation)

        sender.removeFromSuperview()
        textField = nil
        needsDisplay = true
    }

    private func applyCrop(from start: CGPoint, to end: CGPoint) {
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let w = abs(end.x - start.x)
        let h = abs(end.y - start.y)

        let cropRect = CGRect(x: x, y: y, width: w, height: h)

        guard let tiffData = viewModel.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let scaleX = imgW / viewModel.image.size.width
        let scaleY = imgH / viewModel.image.size.height

        let scaledRect = CGRect(
            x: cropRect.origin.x * scaleX,
            y: (viewModel.image.size.height - cropRect.maxY) * scaleY,
            width: cropRect.width * scaleX,
            height: cropRect.height * scaleY
        )

        if let cropped = cgImage.cropping(to: scaledRect) {
            viewModel.image = NSImage(cgImage: cropped, size: NSSize(width: cropRect.width, height: cropRect.height))
            viewModel.annotations.removeAll()
            viewModel.redoStack.removeAll()
        }
    }

    private func pickColor(at point: CGPoint) {
        guard let tiffData = viewModel.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return }

        let imgPoint = imagePoint(from: point)
        let scaleX = CGFloat(bitmap.pixelsWide) / viewModel.image.size.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / viewModel.image.size.height

        let pixelX = Int(imgPoint.x * scaleX)
        let pixelY = bitmap.pixelsHigh - Int(imgPoint.y * scaleY)

        guard pixelX >= 0, pixelX < bitmap.pixelsWide, pixelY >= 0, pixelY < bitmap.pixelsHigh else { return }

        if let color = bitmap.colorAt(x: pixelX, y: pixelY) {
            let hex = String(format: "#%02X%02X%02X",
                             Int(color.redComponent * 255),
                             Int(color.greenComponent * 255),
                             Int(color.blueComponent * 255))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(hex, forType: .string)
            viewModel.strokeColor = Color(nsColor: color)
        }
    }
}
