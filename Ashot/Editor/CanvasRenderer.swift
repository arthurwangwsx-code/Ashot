import AppKit
import SwiftUI
import CoreGraphics
import CoreImage
import CoreText

struct RGBA: Equatable, Codable, Sendable {
    var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    nonisolated var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent; alpha = rgb.alphaComponent
    }
    nonisolated init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

struct ImageBackground: Equatable, Codable, Sendable {
    var padding: CGFloat = 48
    var cornerRadius: CGFloat = 12
    var shadow: CGFloat = 16
    var color = RGBA(red: 0.15, green: 0.24, blue: 0.46)
    var secondColor: RGBA? = RGBA(red: 0.42, green: 0.3, blue: 0.65)
}

/// CGImage and CGColor are immutable. All AppKit/SwiftUI values are converted on the main actor
/// before this snapshot crosses to a render/export worker. There is no mutable NSImage here.
struct RenderAnnotation: @unchecked Sendable {
    let type: AnnotationTool
    let start: CGPoint, end: CGPoint
    let points: [CGPoint]
    let color: RGBA
    let lineWidth: CGFloat
    let text: String
    let counter: Int
    let image: CGImage?

    init(_ annotation: Annotation) {
        type = annotation.type; start = annotation.startPoint; end = annotation.endPoint
        points = annotation.points; color = RGBA(NSColor(annotation.color))
        lineWidth = annotation.lineWidth; text = annotation.text; counter = annotation.counterNumber
        image = annotation.image.flatMap { CapturedImageSnapshot(image: $0)?.cgImage }
    }
    nonisolated var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

struct RenderSnapshot: @unchecked Sendable {
    let source: CGImage
    let logicalSize: CGSize
    let visibleRect: CGRect
    let background: ImageBackground?
    let annotations: [RenderAnnotation]
    let nativeScale: CGFloat
    nonisolated var padding: CGFloat { background?.padding ?? 0 }
    nonisolated var canvasSize: CGSize {
        CGSize(width: visibleRect.width + 2 * padding, height: visibleRect.height + 2 * padding)
    }

    init(document: CaptureDocument) throws {
        guard let image = CapturedImageSnapshot(image: document.source)?.cgImage,
              document.source.size.width.isFinite, document.source.size.height.isFinite,
              document.source.size.width > 0, document.source.size.height > 0 else { throw RenderFailure.invalidImage }
        source = image; logicalSize = document.source.size; visibleRect = document.visibleRect
        background = document.background; annotations = document.annotations.map(RenderAnnotation.init)
        nativeScale = CGFloat(image.width) / document.source.size.width
    }
}

enum RenderFailure: LocalizedError {
    case invalidImage, tooLarge, allocationFailed, effectFailed
    nonisolated var errorDescription: String? {
        switch self {
        case .invalidImage: return "The image or crop region is invalid. Your edits have been kept."
        case .tooLarge: return "The image exceeds the safe pixel budget. Crop it or export at a smaller scale."
        case .allocationFailed: return "The image could not be rendered. Close unused images and try again."
        case .effectFailed: return "An image effect could not be rendered. Your edits have been kept."
        }
    }
}

/// One renderer for preview, clipboard, files, OCR and pinning. Uses explicit pixel dimensions
/// rather than lockFocus(), whose resolution depends on the window's current display.
enum CanvasRenderer {
    nonisolated static let maximumPixels = 64_000_000

    nonisolated static func render(_ snapshot: RenderSnapshot, scale requestedScale: CGFloat? = nil) throws -> CGImage {
        let scale = requestedScale ?? snapshot.nativeScale
        let size = snapshot.canvasSize
        guard scale.isFinite, scale > 0, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              snapshot.visibleRect.minX.isFinite, snapshot.visibleRect.minY.isFinite else { throw RenderFailure.invalidImage }
        let dw = ceil(size.width * scale), dh = ceil(size.height * scale)
        guard dw <= 32_768, dh <= 32_768, dw * dh <= CGFloat(maximumPixels), dw >= 1, dh >= 1 else { throw RenderFailure.tooLarge }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(dw), height: Int(dh), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderFailure.allocationFailed }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        if let background = snapshot.background {
            let frame = CGRect(origin: .zero, size: size)
            context.setFillColor(background.color.cgColor); context.fill(frame)
            if let end = background.secondColor,
               let gradient = CGGradient(colorsSpace: space, colors: [background.color.cgColor, end.cgColor] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -background.shadow / 3), blur: background.shadow,
                              color: CGColor(gray: 0, alpha: 0.28))
            let imageFrame = CGRect(x: snapshot.padding, y: snapshot.padding, width: snapshot.visibleRect.width, height: snapshot.visibleRect.height)
            context.addPath(CGPath(roundedRect: imageFrame, cornerWidth: background.cornerRadius, cornerHeight: background.cornerRadius, transform: nil))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillPath()
            context.restoreGState()
        }
        context.translateBy(x: snapshot.padding - snapshot.visibleRect.minX, y: snapshot.padding - snapshot.visibleRect.minY)
        if let background = snapshot.background {
            context.addPath(CGPath(roundedRect: snapshot.visibleRect, cornerWidth: background.cornerRadius, cornerHeight: background.cornerRadius, transform: nil))
            context.clip()
        } else { context.clip(to: snapshot.visibleRect) }
        context.draw(snapshot.source, in: CGRect(origin: .zero, size: snapshot.logicalSize))
        for annotation in snapshot.annotations {
            context.saveGState()
            try draw(annotation, context: context, snapshot: snapshot, scale: scale)
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw RenderFailure.allocationFailed }
        return result
    }

    nonisolated private static func draw(_ a: RenderAnnotation, context c: CGContext, snapshot: RenderSnapshot, scale: CGFloat) throws {
        c.setStrokeColor(a.color.cgColor); c.setFillColor(a.color.cgColor)
        c.setLineWidth(max(0.25, a.lineWidth)); c.setLineCap(.round); c.setLineJoin(.round)
        switch a.type {
        case .arrow, .line:
            c.move(to: a.start); c.addLine(to: a.end); c.strokePath()
            if a.type == .arrow {
                let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
                let length = max(10, a.lineWidth * 5), spread = CGFloat.pi / 6
                c.move(to: a.end)
                c.addLine(to: CGPoint(x: a.end.x - length * cos(angle - spread), y: a.end.y - length * sin(angle - spread)))
                c.addLine(to: CGPoint(x: a.end.x - length * cos(angle + spread), y: a.end.y - length * sin(angle + spread)))
                c.closePath(); c.fillPath()
            }
        case .rectangle: c.stroke(a.rect)
        case .oval: c.strokeEllipse(in: a.rect)
        case .freehand:
            guard let first = a.points.first else { return }
            c.move(to: first); for point in a.points.dropFirst() { c.addLine(to: point) }; c.strokePath()
        case .text:
            let fontSize = max(5, a.lineWidth * 5)
            let lines = a.text.components(separatedBy: "\n")
            for (index, text) in lines.enumerated() {
                drawText(text, at: CGPoint(x: a.start.x, y: a.start.y + CGFloat(lines.count - index - 1) * fontSize * 1.25 + fontSize * 0.22),
                         fontSize: fontSize, color: a.color.cgColor, context: c)
            }
        case .counter:
            let radius = max(8, a.lineWidth * 14 / 3)
            c.fillEllipse(in: CGRect(x: a.start.x - radius, y: a.start.y - radius, width: radius * 2, height: radius * 2))
            drawText(String(a.counter), at: a.start, fontSize: radius, color: CGColor(gray: 1, alpha: 1), centered: true, context: c)
        case .highlight:
            c.setFillColor(CGColor(red: a.color.red, green: a.color.green, blue: a.color.blue, alpha: 0.3)); c.fill(a.rect)
        case .redact:
            // Always opaque. Never let a color-picker alpha silently turn a redaction transparent.
            c.setShouldAntialias(false); c.setFillColor(CGColor(gray: 0, alpha: 1))
            let r = a.rect
            let x = floor(r.minX * scale) / scale, y = floor(r.minY * scale) / scale
            c.fill(CGRect(x: x, y: y, width: ceil(r.maxX * scale) / scale - x, height: ceil(r.maxY * scale) / scale - y))
        case .image:
            // The layer's pixels define its opacity, independently of the annotation style.
            c.setAlpha(1)
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            if let image = a.image { c.draw(image, in: a.rect) }
        case .blur, .pixelate:
            let rect = a.rect.intersection(snapshot.visibleRect)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
            // Effects sample the already-composited result, never bypass earlier redactions/layers.
            guard let composed = c.makeImage() else { throw RenderFailure.effectFailed }
            let crop = CGRect(x: (rect.minX - snapshot.visibleRect.minX + snapshot.padding) * scale,
                              y: CGFloat(composed.height) - (rect.maxY - snapshot.visibleRect.minY + snapshot.padding) * scale,
                              width: rect.width * scale, height: rect.height * scale).integral
                .intersection(CGRect(x: 0, y: 0, width: composed.width, height: composed.height))
            guard let pixels = composed.cropping(to: crop) else { throw RenderFailure.effectFailed }
            let source = CIImage(cgImage: pixels)
            let output: CIImage
            if a.type == .blur {
                output = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(3, a.lineWidth * 3) * scale]).cropped(to: source.extent)
            } else {
                output = source.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(6, a.lineWidth * 4) * scale,
                    kCIInputCenterKey: CIVector(x: source.extent.midX, y: source.extent.midY)]).cropped(to: source.extent)
            }
            guard let filtered = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: source.extent) else { throw RenderFailure.effectFailed }
            c.draw(filtered, in: rect)
        default: break
        }
    }

    nonisolated private static func drawText(_ text: String, at point: CGPoint, fontSize: CGFloat, color: CGColor, centered: Bool = false, context c: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        c.textMatrix = .identity
        if centered {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            c.textPosition = CGPoint(x: point.x - width / 2, y: point.y - (ascent - descent) / 2)
        } else { c.textPosition = point }
        CTLineDraw(line, c)
    }
}
