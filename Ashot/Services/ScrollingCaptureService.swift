import AppKit
import ScreenCaptureKit
import CoreImage

enum ScrollingCaptureLimits {
    nonisolated static let maximumFrames = 30
    nonisolated static let maximumStoredPixels = 64_000_000
    nonisolated static func canAppend(frameCount: Int, storedPixels: Int, nextPixels: Int) -> Bool {
        frameCount < maximumFrames && nextPixels > 0 &&
            nextPixels <= maximumStoredPixels && storedPixels <= maximumStoredPixels - nextPixels
    }
}

final class ScrollingCaptureService {
    static let shared = ScrollingCaptureService()
    private var capturedFrames: [NSImage] = []
    private var isCapturing = false
    private var captureTimer: Timer?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var statusWindow: NSWindow?
    private var sessionID = UUID()
    private var isFrameInFlight = false
    private var storedPixels = 0

    private init() {}

    func startScrollingCapture() {
        guard !isCapturing else { return }
        guard ScreenCapturePermission.ensureAccess() else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("Scrolling Capture")
        alert.informativeText = L10n.string("After clicking Start, scroll through the content you want to capture. Press Escape or click Stop to finish and stitch the images together.")
        alert.addButton(withTitle: L10n.string("Start"))
        alert.addButton(withTitle: L10n.string("Cancel"))

        if alert.runModal() == .alertFirstButtonReturn {
            beginCapture()
        }
    }

    private func beginCapture() {
        sessionID = UUID()
        isFrameInFlight = false
        storedPixels = 0
        capturedFrames.removeAll()
        isCapturing = true

        showStatusIndicator()
        captureFrame()

        // Global monitor catches Esc even when another app is focused (requires Accessibility
        // permission). The local monitor is the reliable fallback while our status window is key,
        // and the visible Stop button works regardless of permissions.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async { self?.finishCapture() }
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.finishCapture()
                return nil
            }
            return event
        }

        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, self.isCapturing else { return }
            self.captureFrame()
        }
    }

    @objc private func stopButtonTapped() {
        finishCapture()
    }

    private func showStatusIndicator() {
        let width: CGFloat = 260
        let window = ScrollStatusWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 44),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layer?.cornerRadius = 10
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.3
        view.layer?.shadowRadius = 6

        let label = NSTextField(labelWithString: L10n.string("Scrolling… scroll the content"))
        label.frame = NSRect(x: 16, y: 12, width: 160, height: 20)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        view.addSubview(label)

        let stopButton = NSButton(title: L10n.string("Stop"), target: self, action: #selector(stopButtonTapped))
        stopButton.bezelStyle = .rounded
        stopButton.keyEquivalent = "\r"
        stopButton.frame = NSRect(x: width - 74, y: 8, width: 64, height: 28)
        view.addSubview(stopButton)

        window.contentView = view

        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.frame.midX - width / 2, y: screen.frame.maxY - 80))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statusWindow = window
    }

    private func captureFrame() {
        guard isCapturing, !isFrameInFlight else { return }
        guard CGPreflightScreenCaptureAccess() else { finishCapture(); return }
        isFrameInFlight = true
        let expectedSession = sessionID
        Task {
            defer {
                if self.sessionID == expectedSession { self.isFrameInFlight = false }
            }
            do {
                guard let screen = NSScreen.main else { return }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }

                let ownWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                let config = SCStreamConfiguration()
                let scale = UserDefaults.standard.bool(forKey: "retinaDownscale") ? 1 : max(1, Int(screen.backingScaleFactor.rounded()))
                guard let size = CaptureGeometry.outputPixelSize(
                    logicalSize: CGSize(width: display.width, height: display.height), scale: scale
                ), ScrollingCaptureLimits.canAppend(
                    frameCount: self.capturedFrames.count, storedPixels: self.storedPixels,
                    nextPixels: size.width * size.height
                ) else {
                    if self.sessionID == expectedSession { self.finishCapture() }
                    return
                }
                config.width = size.width
                config.height = size.height
                config.capturesAudio = false
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let nsImage = NSImage(cgImage: image, size: NSSize(width: display.width, height: display.height))
                await MainActor.run {
                    guard self.isCapturing, self.sessionID == expectedSession else { return }
                    self.capturedFrames.append(nsImage)
                    self.storedPixels += size.width * size.height
                }
            } catch {
                print("Scrolling frame capture failed: \(error)")
            }
        }
    }

    private func finishCapture() {
        guard isCapturing else { return }
        isCapturing = false
        captureTimer?.invalidate()
        captureTimer = nil

        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }

        statusWindow?.orderOut(nil)
        statusWindow = nil

        guard capturedFrames.count > 1 else {
            if let single = capturedFrames.first {
                CaptureService.shared.openEditor(with: single)
            }
            capturedFrames.removeAll()
            return
        }

        let stitched = stitchImagesWithMatching(capturedFrames)
        CaptureService.shared.openEditor(with: stitched)
        capturedFrames.removeAll()
    }

    private func stitchImagesWithMatching(_ images: [NSImage]) -> NSImage {
        guard let first = images.first else { return NSImage() }
        if images.count == 1 { return first }

        var offsets: [CGFloat] = [0]

        for i in 1..<images.count {
            let overlap = findOverlapRows(top: images[i-1], bottom: images[i])
            let newContent = images[i].size.height - overlap
            // Keep offsets aligned with their source images, including duplicate frames.
            offsets.append(newContent > 5 ? newContent : 0)
        }

        let totalHeight = first.size.height + offsets.dropFirst().reduce(0, +)
        let width = first.size.width
        guard CaptureGeometry.outputPixelSize(
            logicalSize: NSSize(width: width, height: totalHeight), scale: 2
        ) != nil else { return first }

        let result = NSImage(size: NSSize(width: width, height: totalHeight))
        result.lockFocus()

        var yPos = totalHeight - first.size.height
        first.draw(in: NSRect(x: 0, y: yPos, width: width, height: first.size.height))

        for i in 1..<images.count {
            guard offsets[i] > 0 else { continue }
            yPos -= offsets[i]
            let sourceRect = NSRect(x: 0, y: 0, width: images[i].size.width, height: offsets[i])
            images[i].draw(
                in: NSRect(x: 0, y: yPos, width: width, height: offsets[i]),
                from: sourceRect,
                operation: .copy,
                fraction: 1.0
            )
        }

        result.unlockFocus()
        return result
    }

    private func findOverlapRows(top: NSImage, bottom: NSImage) -> CGFloat {
        guard let topData = top.tiffRepresentation,
              let bottomData = bottom.tiffRepresentation,
              let topBitmap = NSBitmapImageRep(data: topData),
              let bottomBitmap = NSBitmapImageRep(data: bottomData) else {
            return top.size.height * 0.15
        }

        let sampleWidth = min(topBitmap.pixelsWide, bottomBitmap.pixelsWide)
        let topHeight = topBitmap.pixelsHigh
        let bottomHeight = bottomBitmap.pixelsHigh
        let maxOverlap = min(topHeight, bottomHeight)
        let step = max(1, maxOverlap / 100)

        var bestOverlap = 0
        var bestScore: CGFloat = .infinity

        let sampleCols = stride(from: sampleWidth / 8, to: sampleWidth * 7 / 8, by: max(1, sampleWidth / 10))

        for overlapRows in Array(stride(from: step, to: maxOverlap, by: step)) + [maxOverlap] {
            var diff: CGFloat = 0
            var count = 0

            let topStartRow = topHeight - overlapRows

            for col in sampleCols {
                for rowOffset in stride(from: 0, to: overlapRows, by: max(1, overlapRows / 20)) {
                    let topRow = topStartRow + rowOffset
                    let bottomRow = rowOffset

                    guard topRow < topHeight, bottomRow < bottomHeight, col < sampleWidth else { continue }

                    let topColor = topBitmap.colorAt(x: col, y: topRow)
                    let bottomColor = bottomBitmap.colorAt(x: col, y: bottomRow)

                    if let tc = topColor, let bc = bottomColor {
                        let dr = tc.redComponent - bc.redComponent
                        let dg = tc.greenComponent - bc.greenComponent
                        let db = tc.blueComponent - bc.blueComponent
                        diff += sqrt(dr*dr + dg*dg + db*db)
                        count += 1
                    }
                }
            }

            if count > 0 {
                let avgDiff = diff / CGFloat(count)
                if avgDiff < bestScore {
                    bestScore = avgDiff
                    bestOverlap = overlapRows
                }
            }
        }

        if bestScore > 0.1 {
            return top.size.height * 0.15
        }

        let scale = top.size.height / CGFloat(topHeight)
        return CGFloat(bestOverlap) * scale
    }
}

/// Borderless window that can become key so its Stop button and Esc work without a title bar.
private final class ScrollStatusWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
