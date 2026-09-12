import AppKit
import ScreenCaptureKit

enum ColorFormat: String, CaseIterable {
    case hex = "HEX"
    case rgb = "RGB"
    case hsl = "HSL"
    case oklch = "OKLCH"
}

final class ColorPickerService {
    static let shared = ColorPickerService()
    private var overlayWindows: [NSWindow] = []
    private var keyMonitor: Any?
    private var didPushCursor = false
    var preferredFormat: ColorFormat = .hex

    private init() {}

    func start() {
        guard ScreenCapturePermission.ensureAccess() else { return }
        restoreCursorIfNeeded()
        dismissOverlays()

        for screen in NSScreen.screens {
            let window = ColorPickerWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = ColorPickerOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onPick = { [weak self] point in
                self?.pickColor(at: point)
            }
            view.onCancel = { [weak self] in
                self?.cancel()
            }
            window.contentView = view
            window.orderFrontRegardless()
            overlayWindows.append(window)
        }

        let mouse = NSEvent.mouseLocation
        let keyWindow = overlayWindows.first { $0.frame.contains(mouse) } ?? overlayWindows.first
        keyWindow?.makeKey()

        NSCursor.crosshair.push()
        didPushCursor = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil
            }
            return event
        }
    }

    private func dismissOverlays() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
    }

    private func pickColor(at screenPoint: NSPoint) {
        restoreCursorIfNeeded()
        dismissOverlays()

        guard CGPreflightScreenCaptureAccess() else { return }
        Task {
            do {
                guard let screen = NSScreen.screens.first(where: { NSMouseInRect(screenPoint, $0.frame, false) }) ?? NSScreen.main else { return }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }

                // Convert the global (bottom-left origin) cursor point to a top-left sourceRect
                // relative to the display the cursor is on.
                let localX = screenPoint.x - screen.frame.minX
                let localYTop = screen.frame.maxY - screenPoint.y
                let captureRect = CGRect(x: max(0, localX - 5), y: max(0, localYTop - 5), width: 11, height: 11)

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = captureRect
                config.width = 11
                config.height = 11
                config.capturesAudio = false
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let bitmap = NSBitmapImageRep(cgImage: image)

                await MainActor.run {
                    if let color = bitmap.colorAt(x: 5, y: 5) {
                        let formatted = self.formatColor(color)
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(formatted, forType: .string)
                        self.showColorNotification(text: formatted, color: color)
                    }
                }
            } catch {
                print("Color pick failed: \(error)")
            }
        }
    }

    func formatColor(_ color: NSColor, format: ColorFormat? = nil) -> String {
        let fmt = format ?? preferredFormat
        let r = color.redComponent
        let g = color.greenComponent
        let b = color.blueComponent

        switch fmt {
        case .hex:
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        case .rgb:
            return String(format: "rgb(%d, %d, %d)", Int(r * 255), Int(g * 255), Int(b * 255))
        case .hsl:
            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
            return String(format: "hsl(%d, %d%%, %d%%)", Int(h * 360), Int(s * 100), Int(l * 100))
        case .oklch:
            let (lVal, cVal, hVal) = rgbToOKLCH(r: r, g: g, b: b)
            return String(format: "oklch(%.2f %.3f %.1f)", lVal, cVal, hVal)
        }
    }

    private func rgbToHSL(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2

        if maxC == minC { return (0, 0, l) }

        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)

        var h: CGFloat
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6

        return (h, s, l)
    }

    private func rgbToOKLCH(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let lr = r > 0.04045 ? pow((r + 0.055) / 1.055, 2.4) : r / 12.92
        let lg = g > 0.04045 ? pow((g + 0.055) / 1.055, 2.4) : g / 12.92
        let lb = b > 0.04045 ? pow((b + 0.055) / 1.055, 2.4) : b / 12.92

        let l_ = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
        let m_ = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
        let s_ = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb

        let l3 = cbrt(l_)
        let m3 = cbrt(m_)
        let s3 = cbrt(s_)

        let okL = 0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3
        let okA = 1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3
        let okB = 0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3

        let c = sqrt(okA * okA + okB * okB)
        var h = atan2(okB, okA) * 180 / .pi
        if h < 0 { h += 360 }

        return (okL, c, h)
    }

    private func cancel() {
        restoreCursorIfNeeded()
        dismissOverlays()
    }

    private func restoreCursorIfNeeded() {
        guard didPushCursor else { return }
        NSCursor.pop()
        didPushCursor = false
    }

    private func showColorNotification(text: String, color: NSColor) {
        let notification = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 50),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        notification.level = .floating
        notification.isOpaque = false
        notification.backgroundColor = .clear

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 50))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.layer?.cornerRadius = 10
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.3
        view.layer?.shadowRadius = 8
        view.layer?.shadowOffset = NSSize(width: 0, height: -2)

        let colorSwatch = NSView(frame: NSRect(x: 12, y: 12, width: 26, height: 26))
        colorSwatch.wantsLayer = true
        colorSwatch.layer?.backgroundColor = color.cgColor
        colorSwatch.layer?.cornerRadius = 4
        colorSwatch.layer?.borderWidth = 1
        colorSwatch.layer?.borderColor = NSColor.separatorColor.cgColor
        view.addSubview(colorSwatch)

        let label = NSTextField(labelWithString: "\(text) copied")
        label.frame = NSRect(x: 48, y: 15, width: 160, height: 20)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        view.addSubview(label)

        notification.contentView = view
        notification.center()
        notification.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                notification.animator().alphaValue = 0
            }, completionHandler: {
                notification.orderOut(nil)
            })
        }
    }
}

/// Borderless overlay window that can become key so Esc and clicks are received without a title bar.
final class ColorPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class ColorPickerOverlayView: NSView {
    var onPick: ((NSPoint) -> Void)?
    var onCancel: (() -> Void)?
    private var currentMouse: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let mouse = currentMouse else { return }

        drawMagnifierLoop(at: mouse)
    }

    private func drawMagnifierLoop(at point: NSPoint) {
        let loopSize: CGFloat = 100
        let loopOrigin = NSPoint(x: point.x + 25, y: point.y + 25)
        let loopRect = NSRect(origin: loopOrigin, size: NSSize(width: loopSize, height: loopSize))

        NSColor.black.withAlphaComponent(0.9).setFill()
        let loopPath = NSBezierPath(ovalIn: loopRect)
        loopPath.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(ovalIn: loopRect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()

        let crossColor = NSColor.white.withAlphaComponent(0.6)
        crossColor.setStroke()
        let hLine = NSBezierPath()
        hLine.move(to: NSPoint(x: loopRect.minX + 20, y: loopRect.midY))
        hLine.line(to: NSPoint(x: loopRect.maxX - 20, y: loopRect.midY))
        hLine.lineWidth = 1
        hLine.stroke()

        let vLine = NSBezierPath()
        vLine.move(to: NSPoint(x: loopRect.midX, y: loopRect.minY + 20))
        vLine.line(to: NSPoint(x: loopRect.midX, y: loopRect.maxY - 20))
        vLine.lineWidth = 1
        vLine.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        currentMouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        onPick?(screenPoint)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        }
    }
}
