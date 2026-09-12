import AppKit
import ScreenCaptureKit

enum WindowSelectionResult { case window(SCWindow), area, cancelled }

enum ScreenCoordinates {
    static var primaryTop: CGFloat {
        NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() })?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
    }
    nonisolated static func appKitRect(fromQuartz rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
    nonisolated static func quartzPoint(fromAppKit point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }
}

final class WindowSelectionController {
    private var overlays: [WindowSelectionOverlay] = []
    private var windows: [SCWindow] = []
    private var selectedID: CGWindowID?
    private var monitor: Any?
    private var didPushCursor = false
    private var completion: ((WindowSelectionResult) -> Void)?

    func begin(windows candidates: [SCWindow], completion: @escaping (WindowSelectionResult) -> Void) {
        self.completion = completion
        let order = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        windows = candidates.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 30 &&
            $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }.sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }
        guard !windows.isEmpty else { finish(.cancelled); UserNotice.show("No visible window was found. Open the target window and try again."); return }

        for screen in NSScreen.screens {
            let overlay = WindowSelectionOverlay(screen: screen)
            overlay.selectionView.onMove = { [weak self] point in self?.hover(at: point) }
            overlay.selectionView.onClick = { [weak self] in self?.confirm() }
            overlays.append(overlay); overlay.orderFrontRegardless()
        }
        (overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays.first)?.makeKey()
        NSCursor.pointingHand.push(); didPushCursor = true
        hover(at: NSEvent.mouseLocation)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.overlays.contains(where: { $0 === event.window }) else { return event }
            switch event.keyCode {
            case 53: self.finish(.cancelled)
            case 49: self.finish(.area)
            case 36, 76: self.confirm()
            case 48:
                let current = self.windows.firstIndex { $0.windowID == self.selectedID } ?? -1
                let delta = event.modifierFlags.contains(.shift) ? -1 : 1
                let index = (current + delta + self.windows.count) % self.windows.count
                self.selectedID = self.windows[index].windowID; self.refreshHighlight()
            default: return event
            }
            return nil
        }
    }
    func cancel() { finish(.cancelled) }
    private func hover(at point: CGPoint) {
        let quartz = ScreenCoordinates.quartzPoint(fromAppKit: point, primaryTop: ScreenCoordinates.primaryTop)
        selectedID = windows.first(where: { $0.frame.contains(quartz) })?.windowID
        refreshHighlight()
    }
    private func refreshHighlight() {
        let selected = windows.first { $0.windowID == selectedID }
        for overlay in overlays {
            overlay.selectionView.highlight = selected.map {
                ScreenCoordinates.appKitRect(fromQuartz: $0.frame, primaryTop: ScreenCoordinates.primaryTop)
                    .offsetBy(dx: -overlay.frame.minX, dy: -overlay.frame.minY)
            }
            overlay.selectionView.title = selected?.title ?? selected?.owningApplication?.applicationName ?? ""
            overlay.selectionView.needsDisplay = true
        }
    }
    private func confirm() {
        guard let selected = windows.first(where: { $0.windowID == selectedID }) else { return }
        finish(.window(selected))
    }
    private func finish(_ result: WindowSelectionResult) {
        guard let callback = completion else { return }
        completion = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if didPushCursor { NSCursor.pop(); didPushCursor = false }
        overlays.forEach { $0.orderOut(nil); $0.selectionView.onMove = nil; $0.selectionView.onClick = nil }
        overlays.removeAll(); windows.removeAll()
        callback(result)
    }
}

private final class WindowSelectionOverlay: NSWindow {
    let selectionView: WindowHighlightView
    init(screen: NSScreen) {
        selectionView = WindowHighlightView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        contentView = selectionView; level = .screenSaver; isOpaque = false; backgroundColor = .clear
        acceptsMouseMovedEvents = true; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
}

private final class WindowHighlightView: NSView {
    var highlight: CGRect?
    var title = ""
    var onMove: ((CGPoint) -> Void)?
    var onClick: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { onMove?(NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { onMove?(NSEvent.mouseLocation); onClick?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
        if let rect = highlight {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear; NSBezierPath(rect: rect).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8); border.lineWidth = 4; border.stroke()
        }
        let text = "\(title)\n\(L10n.string("Click or Return: capture • Tab: next window • Space: area • Esc: cancel"))"
        let label = CGRect(x: 30, y: 35, width: max(100, min(820, bounds.width - 60)), height: 70)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: label, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(in: label.insetBy(dx: 14, dy: 10), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white])
    }
}
