import SwiftUI
import AppKit
@preconcurrency import Vision
import UniformTypeIdentifiers
import CoreImage

enum AnnotationTool: String, CaseIterable {
    case select, arrow, line, rectangle, oval, freehand, text, counter
    case blur, pixelate, highlight
    case crop, ruler, colorPicker, ocr

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
        case .crop: return L10n.string("Crop")
        case .ruler: return L10n.string("Ruler")
        case .colorPicker: return L10n.string("Color Picker")
        case .ocr: return L10n.string("OCR")
        }
    }
}

struct Annotation: Identifiable {
    let id: UUID
    var type: AnnotationTool
    var startPoint: CGPoint
    var endPoint: CGPoint
    var points: [CGPoint]
    var color: Color
    var lineWidth: CGFloat
    var text: String
    var counterNumber: Int

    init(type: AnnotationTool, startPoint: CGPoint, endPoint: CGPoint, points: [CGPoint], color: Color, lineWidth: CGFloat, text: String, counterNumber: Int) {
        self.id = UUID()
        self.type = type
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.counterNumber = counterNumber
    }

    var boundingRect: CGRect {
        switch type {
        case .arrow, .line:
            return CGRect(
                x: min(startPoint.x, endPoint.x) - lineWidth,
                y: min(startPoint.y, endPoint.y) - lineWidth,
                width: abs(endPoint.x - startPoint.x) + lineWidth * 2,
                height: abs(endPoint.y - startPoint.y) + lineWidth * 2
            )
        case .rectangle, .oval, .blur, .pixelate, .highlight:
            return CGRect(
                x: min(startPoint.x, endPoint.x),
                y: min(startPoint.y, endPoint.y),
                width: abs(endPoint.x - startPoint.x),
                height: abs(endPoint.y - startPoint.y)
            )
        case .freehand:
            guard !points.isEmpty else { return .zero }
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!
            let minY = ys.min()!, maxY = ys.max()!
            return CGRect(x: minX - lineWidth, y: minY - lineWidth, width: maxX - minX + lineWidth * 2, height: maxY - minY + lineWidth * 2)
        case .text:
            return CGRect(x: startPoint.x, y: startPoint.y, width: 200, height: 30)
        case .counter:
            return CGRect(x: startPoint.x - 14, y: startPoint.y - 14, width: 28, height: 28)
        default:
            return .zero
        }
    }

    func hitTest(point: CGPoint, tolerance: CGFloat) -> Bool {
        switch type {
        case .arrow, .line:
            return distanceToLine(point: point, lineStart: startPoint, lineEnd: endPoint) < tolerance + lineWidth
        case .rectangle:
            let rect = boundingRect
            let expanded = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return expanded.contains(point) && !inner.contains(point)
        case .oval:
            let rect = boundingRect
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width / 2, ry = rect.height / 2
            let dx = (point.x - cx) / rx
            let dy = (point.y - cy) / ry
            let dist = dx * dx + dy * dy
            return dist > 0.7 && dist < 1.3
        case .freehand:
            for p in points {
                if hypot(point.x - p.x, point.y - p.y) < tolerance + lineWidth {
                    return true
                }
            }
            return false
        case .text, .counter, .blur, .pixelate, .highlight:
            return boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        default:
            return false
        }
    }

    private func distanceToLine(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return hypot(point.x - lineStart.x, point.y - lineStart.y) }
        var t = ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lenSq
        t = max(0, min(1, t))
        let projX = lineStart.x + t * dx
        let projY = lineStart.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }

    mutating func translate(by delta: CGSize) {
        startPoint.x += delta.width
        startPoint.y += delta.height
        endPoint.x += delta.width
        endPoint.y += delta.height
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }
}

enum AnnotationGeometry {
    /// Shift constrains arrows/lines to 45-degree increments and rectangles/ovals to squares.
    nonisolated static func constrainedEndpoint(
        start: CGPoint,
        end: CGPoint,
        tool: AnnotationTool,
        isShiftPressed: Bool
    ) -> CGPoint {
        guard isShiftPressed else { return end }

        let dx = end.x - start.x
        let dy = end.y - start.y
        switch tool {
        case .arrow, .line:
            let length = hypot(dx, dy)
            guard length > 0 else { return end }
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(
                x: start.x + cos(angle) * length,
                y: start.y + sin(angle) * length
            )
        case .rectangle, .oval:
            let side = max(abs(dx), abs(dy))
            return CGPoint(
                x: start.x + (dx < 0 ? -side : side),
                y: start.y + (dy < 0 ? -side : side)
            )
        default:
            return end
        }
    }
}

enum ResizeHandle {
    case topLeft, topRight, bottomLeft, bottomRight
}

@MainActor
@Observable
final class EditorViewModel {
    var image: NSImage
    var selectedTool: AnnotationTool = .select
    var annotations: [Annotation] = []
    var redoStack: [Annotation] = []
    var strokeColor: Color = .red
    var strokeWidth: CGFloat = 3
    var counterValue: Int = 1
    var cropRect: CGRect?
    var ocrText: String = ""
    var showOCRResult: Bool = false
    var rulerStart: CGPoint?
    var rulerEnd: CGPoint?
    var selectedAnnotationID: UUID?
    var zoomScale: CGFloat = 1.0
    var panOffset: CGSize = .zero

    init(image: NSImage) {
        self.image = image
    }

    func addAnnotation(_ annotation: Annotation) {
        annotations.append(annotation)
        redoStack.removeAll()
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        if selectedAnnotationID == last.id { selectedAnnotationID = nil }
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
    }

    func deleteSelected() {
        guard let id = selectedAnnotationID else { return }
        if let idx = annotations.firstIndex(where: { $0.id == id }) {
            let removed = annotations.remove(at: idx)
            redoStack.append(removed)
            selectedAnnotationID = nil
        }
    }

    func duplicateSelected() {
        guard let id = selectedAnnotationID,
              let original = annotations.first(where: { $0.id == id }) else { return }
        let copy = Annotation(
            type: original.type,
            startPoint: CGPoint(x: original.startPoint.x + 20, y: original.startPoint.y + 20),
            endPoint: CGPoint(x: original.endPoint.x + 20, y: original.endPoint.y + 20),
            points: original.points.map { CGPoint(x: $0.x + 20, y: $0.y + 20) },
            color: original.color,
            lineWidth: original.lineWidth,
            text: original.text,
            counterNumber: original.counterNumber
        )
        annotations.append(copy)
        selectedAnnotationID = copy.id
    }

    func moveAnnotation(id: UUID, delta: CGSize) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[idx].translate(by: delta)
    }

    func resizeAnnotation(id: UUID, handle: ResizeHandle, delta: CGSize) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch handle {
        case .topLeft:
            annotations[idx].startPoint.x += delta.width
            annotations[idx].startPoint.y += delta.height
        case .topRight:
            annotations[idx].endPoint.x += delta.width
            annotations[idx].startPoint.y += delta.height
        case .bottomLeft:
            annotations[idx].startPoint.x += delta.width
            annotations[idx].endPoint.y += delta.height
        case .bottomRight:
            annotations[idx].endPoint.x += delta.width
            annotations[idx].endPoint.y += delta.height
        }
    }

    func hitTest(at point: CGPoint) -> UUID? {
        for annotation in annotations.reversed() {
            if annotation.hitTest(point: point, tolerance: 6) {
                return annotation.id
            }
        }
        return nil
    }

    func pasteImage(_ pastedImage: NSImage) {
        let size = image.size
        let pasteSize = pastedImage.size
        let composite = NSImage(size: size)
        composite.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        let origin = NSPoint(x: (size.width - pasteSize.width) / 2, y: (size.height - pasteSize.height) / 2)
        pastedImage.draw(in: NSRect(origin: origin, size: pasteSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        composite.unlockFocus()
        image = composite
        annotations.removeAll()
        redoStack.removeAll()
    }

    func copyToClipboard() {
        let rendered = renderFinalImage()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([rendered])
    }

    func saveToFile() {
        let rendered = renderFinalImage()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot_\(formattedDate()).png"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let tiffData = rendered.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiffData),
                   let pngData = rep.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: url)
                }
            }
        }
    }

    func pinAsFloating() {
        let rendered = renderFinalImage()
        PinService.shared.pinImage(rendered)
    }

    func performOCR() {
        OCRService.recognizeText(in: image) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.ocrText = text
                self.showOCRResult = true
            case .failure:
                self.ocrText = "No readable text was found."
                self.showOCRResult = true
            }
        }
    }

    func performQRDetection() {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

        let request = VNDetectBarcodesRequest { [weak self] request, error in
            guard let observations = request.results as? [VNBarcodeObservation] else { return }
            let texts = observations.compactMap { $0.payloadStringValue }
            let combined = texts.joined(separator: "\n")
            DispatchQueue.main.async {
                if !combined.isEmpty {
                    self?.ocrText = combined
                    self?.showOCRResult = true
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(combined, forType: .string)
                }
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }

    func renderFinalImage() -> NSImage {
        let size = image.size
        let finalImage = NSImage(size: size)
        finalImage.lockFocus()

        image.draw(in: NSRect(origin: .zero, size: size))

        for annotation in annotations {
            drawAnnotation(annotation, in: size)
        }

        finalImage.unlockFocus()
        return finalImage
    }

    private func drawAnnotation(_ annotation: Annotation, in size: NSSize) {
        let nsColor = NSColor(annotation.color)
        nsColor.setStroke()
        nsColor.setFill()

        switch annotation.type {
        case .arrow:
            let path = NSBezierPath()
            path.lineWidth = annotation.lineWidth
            path.move(to: annotation.startPoint)
            path.line(to: annotation.endPoint)
            path.stroke()
            drawArrowhead(from: annotation.startPoint, to: annotation.endPoint, color: nsColor, lineWidth: annotation.lineWidth)

        case .line:
            let path = NSBezierPath()
            path.lineWidth = annotation.lineWidth
            path.lineCapStyle = .round
            path.move(to: annotation.startPoint)
            path.line(to: annotation.endPoint)
            path.stroke()

        case .rectangle:
            let rect = rectFrom(annotation.startPoint, annotation.endPoint)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = annotation.lineWidth
            path.stroke()

        case .oval:
            let rect = rectFrom(annotation.startPoint, annotation.endPoint)
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = annotation.lineWidth
            path.stroke()

        case .freehand:
            guard annotation.points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = annotation.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: annotation.points[0])
            for point in annotation.points.dropFirst() {
                path.line(to: point)
            }
            path.stroke()

        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: annotation.lineWidth * 5),
                .foregroundColor: nsColor
            ]
            (annotation.text as NSString).draw(at: annotation.startPoint, withAttributes: attrs)

        case .counter:
            let center = annotation.startPoint
            let radius: CGFloat = 14
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            nsColor.setFill()
            circle.fill()

            let text = "\(annotation.counterNumber)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 14),
                .foregroundColor: NSColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let textOrigin = NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2)
            (text as NSString).draw(at: textOrigin, withAttributes: attrs)

        case .blur:
            let rect = rectFrom(annotation.startPoint, annotation.endPoint)
            applyBlurToRect(rect, in: size)

        case .pixelate:
            let rect = rectFrom(annotation.startPoint, annotation.endPoint)
            applyPixelateToRect(rect, in: size)

        case .highlight:
            let rect = rectFrom(annotation.startPoint, annotation.endPoint)
            nsColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: rect).fill()

        default:
            break
        }
    }

    private func drawArrowhead(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        let arrowLength: CGFloat = 15
        let arrowAngle: CGFloat = .pi / 6

        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)

        let path = NSBezierPath()
        path.move(to: end)
        path.line(to: NSPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        ))
        path.line(to: NSPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        ))
        path.close()
        color.setFill()
        path.fill()
    }

    private func applyBlurToRect(_ rect: NSRect, in size: NSSize) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

        let scaleX = CGFloat(cgImage.width) / size.width
        let scaleY = CGFloat(cgImage.height) / size.height
        let scaledRect = CGRect(
            x: rect.origin.x * scaleX,
            y: (size.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        guard let cropped = cgImage.cropping(to: scaledRect) else { return }
        let ciImage = CIImage(cgImage: cropped)
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(10.0, forKey: kCIInputRadiusKey)

        let context = CIContext()
        if let output = filter.outputImage,
           let blurred = context.createCGImage(output, from: ciImage.extent) {
            let blurredImage = NSImage(cgImage: blurred, size: rect.size)
            blurredImage.draw(in: rect)
        }
    }

    private func applyPixelateToRect(_ rect: NSRect, in size: NSSize) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

        let scaleX = CGFloat(cgImage.width) / size.width
        let scaleY = CGFloat(cgImage.height) / size.height
        let scaledRect = CGRect(
            x: rect.origin.x * scaleX,
            y: (size.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        guard let cropped = cgImage.cropping(to: scaledRect) else { return }
        let ciImage = CIImage(cgImage: cropped)
        guard let filter = CIFilter(name: "CIPixellate") else { return }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(max(8, 12 * scaleX), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY), forKey: kCIInputCenterKey)

        let context = CIContext()
        if let output = filter.outputImage?.cropped(to: ciImage.extent),
           let pixelated = context.createCGImage(output, from: ciImage.extent) {
            NSImage(cgImage: pixelated, size: rect.size).draw(in: rect)
        }
    }

    private func rectFrom(_ p1: CGPoint, _ p2: CGPoint) -> NSRect {
        NSRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}
