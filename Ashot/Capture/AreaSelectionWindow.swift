import AppKit
import ScreenCaptureKit

enum AreaSelectionResult: Equatable {
    case area(rect: CGRect, displayID: CGDirectDisplayID)
    case frontmostWindow
    case cancelled
}

/// Drives area selection across every connected display by placing a borderless overlay on each
/// screen. Whichever screen the drag finishes on reports the rect in that display's coordinate
/// space, so multi-monitor selection works.
final class AreaSelectionController {
    private var windows: [AreaSelectionWindow] = []
    private var keyMonitor: Any?
    private var completion: ((AreaSelectionResult) -> Void)?
    private var finished = false
    private var didPushCursor = false

    func beginSelection(requireConfirmation: Bool? = nil, completion: @escaping (AreaSelectionResult) -> Void) {
        guard windows.isEmpty, self.completion == nil else {
            completion(.cancelled)
            return
        }
        self.completion = completion

        for screen in NSScreen.screens {
            let window = AreaSelectionWindow(screen: screen, requireConfirmation: requireConfirmation ?? UserDefaults.standard.bool(forKey: "confirmAreaSelection"))
            window.onComplete = { [weak self] rect, displayID in
                self?.finish(with: .area(rect: rect, displayID: displayID))
            }
            window.onCancel = { [weak self] in
                self?.finish(with: .cancelled)
            }
            window.onCaptureFrontmostWindow = { [weak self] in
                self?.finish(with: .frontmostWindow)
            }
            windows.append(window)
            window.orderFrontRegardless()
        }

        guard !windows.isEmpty else {
            finish(with: .cancelled)
            return
        }

        // Make the overlay under the cursor key so Esc works immediately, before any click.
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.targetScreen.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKey()

        NSCursor.crosshair.push()
        didPushCursor = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let result = Self.selectionResult(forKeyCode: event.keyCode) {
                self?.finish(with: result)
                return nil
            }
            return event
        }
    }

    nonisolated static func selectionResult(forKeyCode keyCode: UInt16) -> AreaSelectionResult? {
        switch keyCode {
        case 53: return .cancelled
        case 49: return .frontmostWindow
        default: return nil
        }
    }

    func cancel() {
        finish(with: .cancelled)
    }

    private func finish(with result: AreaSelectionResult) {
        guard !finished else { return }
        finished = true

        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        windows.forEach {
            $0.onComplete = nil
            $0.onCancel = nil
            $0.onCaptureFrontmostWindow = nil
            $0.orderOut(nil)
        }
        windows.removeAll()

        let callback = completion
        completion = nil
        callback?(result)
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if didPushCursor {
            NSCursor.pop()
        }
        windows.forEach { $0.orderOut(nil) }
    }
}

final class AreaSelectionWindow: NSWindow {
    var onComplete: ((CGRect, CGDirectDisplayID) -> Void)?
    var onCancel: (() -> Void)?
    var onCaptureFrontmostWindow: (() -> Void)?
    let targetScreen: NSScreen
    private var selectionView: AreaSelectionView!

    init(screen: NSScreen, requireConfirmation: Bool = false) {
        self.targetScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        selectionView = AreaSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        selectionView.requireConfirmation = requireConfirmation
        selectionView.onSelectionComplete = { [weak self] rect in
            self?.handleSelection(rect)
        }
        selectionView.onCancel = { [weak self] in
            self?.onCancel?()
        }
        selectionView.onCaptureFrontmostWindow = { [weak self] in
            self?.onCaptureFrontmostWindow?()
        }
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }

    private func handleSelection(_ rect: CGRect?) {
        guard let rect else {
            onCancel?()
            return
        }
        // rect is in this overlay's view coordinates (bottom-left origin). Convert to a top-left
        // sourceRect relative to this display for ScreenCaptureKit.
        let flippedY = targetScreen.frame.height - rect.maxY
        let captureRect = CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        onComplete?(captureRect, targetScreen.displayID)
    }
}

final class AreaSelectionView: NSView {
    var requireConfirmation = false
    var onSelectionComplete: ((CGRect?) -> Void)?
    var onCancel: (() -> Void)?
    var onCaptureFrontmostWindow: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var isSelecting = false
    private var magnetizedRect: NSRect?
    private var movingSelection: (rect: CGRect, origin: CGPoint)?
    private var resizeOrigin: CGPoint?

    private var selectionRect: NSRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        return NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()

        if let rect = selectionRect, rect.width > 3, rect.height > 3 {
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: rect).fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            drawCrosshairs(for: rect)
            drawSelectionBorder(for: rect)
            drawDimensions(for: rect)
        } else if let current = currentPoint {
            drawGlobalCrosshairs(at: current)
            drawMagnifier(at: current)
        }
        if requireConfirmation {
            let text = L10n.string("Drag to select • Drag inside to move • Drag a corner to resize • Return: capture • Space: window • Esc: cancel")
            let frame = CGRect(x: 20, y: 20, width: max(80, min(bounds.width - 40, 790)), height: 48)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            (text as NSString).draw(in: frame.insetBy(dx: 12, dy: 8), withAttributes: Self.safeTextAttributes(size: 12, weight: .regular, color: .white))
        }
    }

    private func drawGlobalCrosshairs(at point: NSPoint) {
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let hLine = NSBezierPath()
        hLine.lineWidth = 0.5
        hLine.move(to: NSPoint(x: bounds.minX, y: point.y))
        hLine.line(to: NSPoint(x: bounds.maxX, y: point.y))
        hLine.setLineDash([4, 4], count: 2, phase: 0)
        hLine.stroke()

        let vLine = NSBezierPath()
        vLine.lineWidth = 0.5
        vLine.move(to: NSPoint(x: point.x, y: bounds.minY))
        vLine.line(to: NSPoint(x: point.x, y: bounds.maxY))
        vLine.setLineDash([4, 4], count: 2, phase: 0)
        vLine.stroke()
    }

    private func drawCrosshairs(for rect: NSRect) {
        NSColor.white.withAlphaComponent(0.3).setStroke()

        let edges: [(NSPoint, NSPoint)] = [
            (NSPoint(x: rect.minX, y: bounds.minY), NSPoint(x: rect.minX, y: bounds.maxY)),
            (NSPoint(x: rect.maxX, y: bounds.minY), NSPoint(x: rect.maxX, y: bounds.maxY)),
            (NSPoint(x: bounds.minX, y: rect.minY), NSPoint(x: bounds.maxX, y: rect.minY)),
            (NSPoint(x: bounds.minX, y: rect.maxY), NSPoint(x: bounds.maxX, y: rect.maxY))
        ]

        for (start, end) in edges {
            let line = NSBezierPath()
            line.lineWidth = 0.5
            line.move(to: start)
            line.line(to: end)
            line.setLineDash([2, 4], count: 2, phase: 0)
            line.stroke()
        }
    }

    private func drawSelectionBorder(for rect: NSRect) {
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()

        let handleSize: CGFloat = 6
        let handles = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.midX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.midY),
            NSPoint(x: rect.maxX, y: rect.midY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.midX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY),
        ]

        NSColor.white.setFill()
        for handle in handles {
            let handleRect = NSRect(x: handle.x - handleSize / 2, y: handle.y - handleSize / 2, width: handleSize, height: handleSize)
            NSBezierPath(roundedRect: handleRect, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawDimensions(for rect: NSRect) {
        guard Self.isFinite(rect), rect.width > 0, rect.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attrs = Self.safeTextAttributes(
            size: 12,
            weight: .medium,
            color: .white
        )
        let size = (text as NSString).size(withAttributes: attrs)

        let bgRect = NSRect(
            x: rect.midX - size.width / 2 - 6,
            y: rect.maxY + 8,
            width: size.width + 12,
            height: size.height + 6
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()

        let labelOrigin = NSPoint(x: bgRect.origin.x + 6, y: bgRect.origin.y + 3)
        (text as NSString).draw(at: labelOrigin, withAttributes: attrs)
    }

    private func drawMagnifier(at point: NSPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        let magnifierSize: CGFloat = 120
        let magnifierOrigin = NSPoint(
            x: point.x + 20,
            y: point.y + 20
        )
        let magnifierRect = NSRect(origin: magnifierOrigin, size: NSSize(width: magnifierSize, height: magnifierSize))

        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: magnifierRect, xRadius: 8, yRadius: 8).fill()

        NSColor.white.withAlphaComponent(0.3).setStroke()
        let crossH = NSBezierPath()
        crossH.move(to: NSPoint(x: magnifierRect.minX + 10, y: magnifierRect.midY))
        crossH.line(to: NSPoint(x: magnifierRect.maxX - 10, y: magnifierRect.midY))
        crossH.lineWidth = 0.5
        crossH.stroke()

        let crossV = NSBezierPath()
        crossV.move(to: NSPoint(x: magnifierRect.midX, y: magnifierRect.minY + 10))
        crossV.line(to: NSPoint(x: magnifierRect.midX, y: magnifierRect.maxY - 10))
        crossV.lineWidth = 0.5
        crossV.stroke()

        let coordText = "\(Int(point.x)), \(Int(point.y))"
        let coordAttrs = Self.safeTextAttributes(
            size: 10,
            weight: .regular,
            color: NSColor.white.withAlphaComponent(0.8)
        )
        let coordSize = (coordText as NSString).size(withAttributes: coordAttrs)
        (coordText as NSString).draw(
            at: NSPoint(x: magnifierRect.midX - coordSize.width / 2, y: magnifierRect.minY + 4),
            withAttributes: coordAttrs
        )
    }

    override var acceptsFirstResponder: Bool { true }

    /// The overlay must receive the first contact even when Ashot was previously inactive.
    /// macOS three-finger dragging can otherwise use the first contact only to activate the app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        if startPoint == nil { currentPoint = point }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        window?.makeFirstResponder(self)
        if requireConfirmation, let rect = selectionRect, rect.width > 3, rect.height > 3 {
            if event.clickCount > 1, rect.contains(point) { onSelectionComplete?(rect); return }
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            if let index = corners.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 12 }) {
                resizeOrigin = corners[3 - index]; startPoint = resizeOrigin; currentPoint = point; isSelecting = true; return
            }
            if rect.contains(point) { movingSelection = (rect, point); return }
        }
        startPoint = point
        currentPoint = startPoint
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let dragPoint = convert(event.locationInWindow, from: nil)
        guard dragPoint.x.isFinite, dragPoint.y.isFinite else { return }
        if let move = movingSelection {
            let x = min(bounds.maxX - move.rect.width, max(bounds.minX, move.rect.minX + dragPoint.x - move.origin.x))
            let y = min(bounds.maxY - move.rect.height, max(bounds.minY, move.rect.minY + dragPoint.y - move.origin.y))
            startPoint = CGPoint(x: x, y: y); currentPoint = CGPoint(x: x + move.rect.width, y: y + move.rect.height)
            needsDisplay = true; return
        }
        if !isSelecting {
            startPoint = Self.dragStartPoint(
                existingStart: startPoint,
                previousCursor: currentPoint,
                dragPoint: dragPoint
            )
            isSelecting = true
        }
        let clamped = CGPoint(x: min(bounds.maxX, max(bounds.minX, dragPoint.x)), y: min(bounds.maxY, max(bounds.minY, dragPoint.y)))
        if let startPoint, event.modifierFlags.contains(.shift) {
            let dx = clamped.x - startPoint.x, dy = clamped.y - startPoint.y
            let side = min(abs(dx), abs(dy))
            currentPoint = CGPoint(x: startPoint.x + (dx < 0 ? -side : side), y: startPoint.y + (dy < 0 ? -side : side))
        } else { currentPoint = clamped }
        needsDisplay = true
    }

    /// A configured three-finger drag may begin with a synthesized drag event rather than a
    /// mouse-down event. Reuse the last cursor position so the selection still starts where the
    /// gesture began instead of ignoring the drag.
    static func dragStartPoint(
        existingStart: NSPoint?,
        previousCursor: NSPoint?,
        dragPoint: NSPoint
    ) -> NSPoint {
        existingStart ?? previousCursor ?? dragPoint
    }

    override func mouseUp(with event: NSEvent) {
        if movingSelection != nil { movingSelection = nil; needsDisplay = true; return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else {
            onSelectionComplete?(nil)
            return
        }
        if !event.modifierFlags.contains(.shift) {
            currentPoint = CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)), y: min(bounds.maxY, max(bounds.minY, point.y)))
        }
        isSelecting = false
        resizeOrigin = nil

        if requireConfirmation { needsDisplay = true; return }

        if let rect = selectionRect, rect.width > 3, rect.height > 3 {
            onSelectionComplete?(rect)
        } else {
            onSelectionComplete?(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else if event.keyCode == 49 { // Space
            onCaptureFrontmostWindow?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            if let rect = selectionRect, rect.width > 3, rect.height > 3 { onSelectionComplete?(rect) }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private static func safeTextAttributes(
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]

        // On some macOS builds monospacedSystemFont can bridge an unexpected nil into Swift.
        // Inserting that value into an attributed-string dictionary raises an Objective-C
        // exception, which terminates the process. A fontless attributed string safely falls back
        // to CoreText's default, so only add a font after optional bridging has verified it.
        if let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight) as NSFont? {
            attributes[.font] = font
        } else if let fallback = NSFont.systemFont(ofSize: size, weight: weight) as NSFont? {
            attributes[.font] = fallback
        }
        return attributes
    }

    nonisolated static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }
}
