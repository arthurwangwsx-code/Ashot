import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureCompletionOptions: Equatable {
    let showPreview: Bool
    let autoCopy: Bool
    let autoSave: Bool

    init(showPreview: Bool?, autoCopy: Bool?, autoSave: Bool) {
        self.showPreview = showPreview ?? true
        self.autoCopy = autoCopy ?? true
        self.autoSave = autoSave
    }
}

enum CaptureMode {
    case area, fullscreen, window, delayed, scrolling

    var historySource: String {
        switch self {
        case .area: return "Area"
        case .fullscreen: return "Fullscreen"
        case .window: return "Window"
        case .delayed: return "Delayed"
        case .scrolling: return "Scrolling"
        }
    }
}

private enum CaptureFailure: LocalizedError {
    case displayUnavailable
    case windowUnavailable
    case invalidCaptureRegion

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "The selected display is no longer available. Try the screenshot again."
        case .windowUnavailable:
            return "No capturable window was found. Bring the window you want to capture to the front and try again."
        case .invalidCaptureRegion:
            return "The selected capture area is invalid or too large. Try selecting the area again."
        }
    }
}

enum CaptureGeometry {
    nonisolated static let maximumPixelDimension = 32_768
    nonisolated static let maximumPixelCount = 64_000_000

    /// Sanitizes event-derived rectangles before passing them to ScreenCaptureKit. This prevents
    /// NaN, infinity, off-display coordinates, and accidental enormous allocations from reaching
    /// framework code.
    nonisolated static func validatedSourceRect(
        _ rect: CGRect,
        displaySize: CGSize
    ) -> CGRect? {
        guard AreaSelectionView.isFinite(rect),
              displaySize.width.isFinite,
              displaySize.height.isFinite,
              displaySize.width > 0,
              displaySize.height > 0 else { return nil }

        let normalized = rect.standardized
        let displayBounds = CGRect(origin: .zero, size: displaySize)
        let clipped = normalized.intersection(displayBounds)
        guard !clipped.isNull,
              clipped.width > 3,
              clipped.height > 3 else { return nil }
        return clipped
    }

    nonisolated static func outputPixelSize(
        logicalSize: CGSize,
        scale: Int
    ) -> (width: Int, height: Int)? {
        guard logicalSize.width.isFinite,
              logicalSize.height.isFinite,
              logicalSize.width > 0,
              logicalSize.height > 0,
              scale > 0 else { return nil }

        let width = logicalSize.width * CGFloat(scale)
        let height = logicalSize.height * CGFloat(scale)
        guard width <= CGFloat(maximumPixelDimension),
              height <= CGFloat(maximumPixelDimension),
              width.rounded() * height.rounded() <= CGFloat(maximumPixelCount),
              width >= 1,
              height >= 1 else { return nil }
        return (Int(width.rounded()), Int(height.rounded()))
    }
}

enum ImageSaveError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "The screenshot could not be encoded in the selected image format."
    }
}

final class CaptureService {
    static let shared = CaptureService()

    private var lastCaptureMode: CaptureMode?
    private var areaSelectionController: AreaSelectionController?

    private init() {}

    var autoSave: Bool { UserDefaults.standard.bool(forKey: "autoSave") }
    var autoCopy: Bool { UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true }
    var showPreview: Bool { UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true }
    var captureSound: Bool { UserDefaults.standard.object(forKey: "captureSound") as? Bool ?? true }
    var retinaDownscale: Bool { UserDefaults.standard.bool(forKey: "retinaDownscale") }
    var saveLocation: String { UserDefaults.standard.string(forKey: "saveLocation") ?? "~/Desktop" }
    var imageFormat: String { UserDefaults.standard.string(forKey: "imageFormat") ?? "png" }
    var hideDesktopIcons: Bool { UserDefaults.standard.bool(forKey: "hideDesktopIcons") }
    var windowShadow: Bool { UserDefaults.standard.object(forKey: "windowShadow") as? Bool ?? true }

    /// Pixel-per-point scale to capture at for a given screen. Honors the "downscale Retina to 1x"
    /// setting; otherwise matches the display's native backing scale instead of assuming 2x.
    private func captureScale(for screen: NSScreen?) -> Int {
        if retinaDownscale { return 1 }
        let factor = screen?.backingScaleFactor ?? 2
        return max(1, Int(factor.rounded()))
    }

    private func setDesktopIconsVisible(_ visible: Bool) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", visible ? "true" : "false"]
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return false }

        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Finder"]
        try? killall.run()
        killall.waitUntilExit()
        return true
    }

    /// Returns true only when this capture changed Finder state and must restore it.
    private func hideDesktopIconsIfNeeded() -> Bool {
        guard hideDesktopIcons else { return false }
        let finderDefaults = UserDefaults.standard.persistentDomain(forName: "com.apple.finder")
        let wereVisible = finderDefaults?["CreateDesktop"] as? Bool ?? true
        guard wereVisible, setDesktopIconsVisible(false) else { return false }

        if hideDesktopIcons {
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }

    private func restoreDesktopIconsIfNeeded(_ shouldRestore: Bool) {
        guard shouldRestore else { return }
        _ = setDesktopIconsVisible(true)
    }

    private func ensurePermission() -> Bool {
        ScreenCapturePermission.ensureAccess()
    }

    func repeatLastCapture() {
        guard let mode = lastCaptureMode else {
            startAreaCapture()
            return
        }
        switch mode {
        case .area: startAreaCapture()
        case .fullscreen: captureFullscreen()
        case .window: captureWindow()
        case .delayed: captureWithDelay(seconds: 3)
        case .scrolling: ScrollingCaptureService.shared.startScrollingCapture()
        }
    }

    func startAreaCapture() {
        lastCaptureMode = .area
        guard ensurePermission() else { return }

        // Only one selection overlay may own the cursor and keyboard monitor at a time. Repeated
        // menu/hotkey activation cancels the old session before constructing a new one.
        areaSelectionController?.cancel()
        let controller = AreaSelectionController()
        areaSelectionController = controller
        controller.beginSelection { [weak self, weak controller] result in
            guard let self else { return }
            if self.areaSelectionController === controller {
                self.areaSelectionController = nil
            }
            switch result {
            case let .area(rect, displayID):
                self.captureRect(rect, screenID: displayID)
            case .frontmostWindow:
                self.performWindowCapture(updateLastMode: true)
            case .cancelled:
                break
            }
        }
    }

    func captureFullscreen() {
        performFullscreenCapture(mode: .fullscreen, updateLastMode: true)
    }

    private func performFullscreenCapture(mode: CaptureMode, updateLastMode: Bool) {
        if updateLastMode {
            lastCaptureMode = mode
        }
        guard ensurePermission() else { return }
        Task {
            let shouldRestoreDesktopIcons = await MainActor.run { self.hideDesktopIconsIfNeeded() }
            do {
                guard let screen = NSScreen.main else { throw CaptureFailure.displayUnavailable }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                    throw CaptureFailure.displayUnavailable
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let scaleFactor = self.captureScale(for: screen)
                guard let outputSize = CaptureGeometry.outputPixelSize(
                    logicalSize: CGSize(width: display.width, height: display.height),
                    scale: scaleFactor
                ) else { throw CaptureFailure.invalidCaptureRegion }
                config.width = outputSize.width
                config.height = outputSize.height
                config.capturesAudio = false
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let nsImage = NSImage(cgImage: image, size: NSSize(width: display.width, height: display.height))
                await MainActor.run {
                    self.restoreDesktopIconsIfNeeded(shouldRestoreDesktopIcons)
                    self.playCaptureSound()
                    self.handleCapturedImage(nsImage, source: mode, previewAnchor: screen.frame)
                }
            } catch {
                await MainActor.run {
                    self.restoreDesktopIconsIfNeeded(shouldRestoreDesktopIcons)
                    self.presentCaptureError(error)
                }
            }
        }
    }

    func captureWindow() {
        performWindowCapture(updateLastMode: true)
    }

    private func performWindowCapture(updateLastMode: Bool) {
        if updateLastMode {
            lastCaptureMode = .window
        }
        guard ensurePermission() else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let windows = content.windows.filter { $0.isOnScreen && $0.frame.width > 50 && $0.frame.height > 50 }

                guard let frontWindow = windows.first(where: { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }) else {
                    throw CaptureFailure.windowUnavailable
                }

                let previewAnchor = Self.appKitWindowFrame(
                    windowFrame: frontWindow.frame,
                    primaryScreenFrame: NSScreen.screens.first?.frame ?? .zero
                )
                let windowScreen = NSScreen.screens.first { $0.frame.intersects(previewAnchor) }
                let filter = SCContentFilter(desktopIndependentWindow: frontWindow)
                let config = SCStreamConfiguration()
                let scaleFactor = self.captureScale(for: windowScreen)
                guard let outputSize = CaptureGeometry.outputPixelSize(
                    logicalSize: frontWindow.frame.size,
                    scale: scaleFactor
                ) else { throw CaptureFailure.invalidCaptureRegion }
                config.width = outputSize.width
                config.height = outputSize.height
                config.capturesAudio = false
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                var nsImage = NSImage(cgImage: image, size: frontWindow.frame.size)
                if self.windowShadow {
                    nsImage = self.imageWithShadow(nsImage, scale: CGFloat(scaleFactor))
                }
                let finalImage = nsImage
                await MainActor.run {
                    self.playCaptureSound()
                    self.handleCapturedImage(finalImage, source: .window, previewAnchor: previewAnchor)
                }
            } catch {
                await MainActor.run { self.presentCaptureError(error) }
            }
        }
    }

    func captureWithDelay(seconds: Int) {
        lastCaptureMode = .delayed
        guard ensurePermission() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            self.performFullscreenCapture(mode: .delayed, updateLastMode: false)
        }
    }

    func captureRect(_ rect: CGRect, screenID: CGDirectDisplayID) {
        guard ensurePermission() else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screenID }) else {
                    throw CaptureFailure.displayUnavailable
                }

                guard let safeRect = CaptureGeometry.validatedSourceRect(
                    rect,
                    displaySize: CGSize(width: display.width, height: display.height)
                ) else { throw CaptureFailure.invalidCaptureRegion }

                let captureScreen = NSScreen.screens.first { $0.displayID == screenID }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = safeRect
                let scaleFactor = self.captureScale(for: captureScreen)
                guard let outputSize = CaptureGeometry.outputPixelSize(
                    logicalSize: safeRect.size,
                    scale: scaleFactor
                ) else { throw CaptureFailure.invalidCaptureRegion }
                config.width = outputSize.width
                config.height = outputSize.height
                config.capturesAudio = false
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let nsImage = NSImage(cgImage: image, size: safeRect.size)
                let previewAnchor = captureScreen.map {
                    Self.appKitCaptureFrame(sourceRect: safeRect, screenFrame: $0.frame)
                }
                await MainActor.run {
                    self.playCaptureSound()
                    self.handleCapturedImage(nsImage, source: .area, previewAnchor: previewAnchor)
                }
            } catch {
                await MainActor.run { self.presentCaptureError(error) }
            }
        }
    }

    func handleCapturedImage(
        _ image: NSImage,
        source mode: CaptureMode,
        previewAnchor: CGRect? = nil
    ) {
        let options = CaptureCompletionOptions(
            showPreview: UserDefaults.standard.object(forKey: "showPreview") as? Bool,
            autoCopy: UserDefaults.standard.object(forKey: "autoCopy") as? Bool,
            autoSave: autoSave
        )

        StatusBarAnimator.shared.flash(type: .capture)

        // Clipboard and preview are the user-visible completion path, so finish them before any
        // image encoding or disk writes. This keeps large Retina captures feeling immediate.
        if options.autoCopy {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }

        if options.showPreview {
            ThumbnailPreviewController.shared.show(image: image, anchorRect: previewAnchor)
        }

        guard let snapshot = CapturedImageSnapshot(image: image) else { return }
        HistoryManager.shared.add(snapshot: snapshot, source: mode.historySource)

        if options.autoSave {
            saveSnapshotInBackground(snapshot)
        }
    }

    private func saveSnapshotInBackground(_ snapshot: CapturedImageSnapshot) {
        let expandedPath = NSString(string: saveLocation).expandingTildeInPath
        let directory = URL(fileURLWithPath: expandedPath)
        let format = ImageFormat(rawValue: imageFormat) ?? .png

        Task.detached(priority: .utility) {
            do {
                guard let data = snapshot.data(format: format) else {
                    throw ImageSaveError.encodingFailed
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = CaptureService.uniqueScreenshotURL(in: directory, format: format)
                try data.write(to: url, options: .atomic)
            } catch {
                await MainActor.run {
                    CaptureService.shared.presentCaptureError(
                        error,
                        title: L10n.string("Screenshot Saved to History Only")
                    )
                }
            }
        }
    }

    func openEditor(with image: NSImage) {
        DispatchQueue.main.async {
            let editorWindow = EditorWindowController(image: image)
            editorWindow.showWindow(nil)
        }
    }

    @discardableResult
    func saveImageToConfiguredLocation(_ image: NSImage) throws -> URL {
        let expandedPath = NSString(string: saveLocation).expandingTildeInPath
        let dir = URL(fileURLWithPath: expandedPath)
        let format = ImageFormat(rawValue: imageFormat) ?? .png

        guard let data = image.data(format: format) else { throw ImageSaveError.encodingFailed }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = Self.uniqueScreenshotURL(in: dir, format: format)
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated static func uniqueScreenshotURL(
        in directory: URL,
        format: ImageFormat,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let base = "Screenshot_\(formatter.string(from: date))"

        var candidate = directory.appendingPathComponent("\(base).\(format.fileExtension)")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(format.fileExtension)")
            suffix += 1
        }
        return candidate
    }

    /// ScreenCaptureKit's display source rectangle uses a top-left origin relative to one
    /// display. Preview windows use AppKit's global bottom-left coordinate space.
    nonisolated static func appKitCaptureFrame(sourceRect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + sourceRect.minX,
            y: screenFrame.maxY - sourceRect.maxY,
            width: sourceRect.width,
            height: sourceRect.height
        )
    }

    /// Global Quartz coordinates originate at the top-left of the menu-bar display, not
    /// the current/main window's display. AppKit's global coordinates originate bottom-left.
    nonisolated static func appKitWindowFrame(windowFrame: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        CGRect(x: windowFrame.minX, y: primaryScreenFrame.maxY - windowFrame.maxY,
               width: windowFrame.width, height: windowFrame.height)
    }

    private func presentCaptureError(_ error: Error, title: String = "Screenshot Failed") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Composites a drop shadow behind a captured window, preserving the source resolution.
    private func imageWithShadow(_ image: NSImage, scale: CGFloat) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return image }

        let pxW = rep.pixelsWide
        let pxH = rep.pixelsHigh
        let margin = Int((50 * scale).rounded())
        let w = pxW + margin * 2
        let h = pxH + margin * 2

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.setShadow(
            offset: CGSize(width: 0, height: -18 * scale),
            blur: 35 * scale,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        ctx.draw(cg, in: CGRect(x: margin, y: margin, width: pxW, height: pxH))

        guard let out = ctx.makeImage() else { return image }
        return NSImage(cgImage: out, size: NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
    }

    private func playCaptureSound() {
        guard captureSound else { return }
        NSSound(named: "Tink")?.play()
    }
}

/// Supported export formats for saved screenshots.
enum ImageFormat: String, CaseIterable {
    case png, jpeg, tiff

    nonisolated var fileExtension: String { rawValue }
    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        }
    }
}

/// Immutable representation suitable for image encoding away from the main thread.
struct CapturedImageSnapshot: @unchecked Sendable {
    let cgImage: CGImage
    let logicalSize: CGSize

    init?(image: NSImage) {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        self.cgImage = cgImage
        self.logicalSize = image.size
    }

    nonisolated func data(format: ImageFormat, compression: CGFloat = 0.9) -> Data? {
        let type: CFString
        switch format {
        case .png: type = UTType.png.identifier as CFString
        case .jpeg: type = UTType.jpeg.identifier as CFString
        case .tiff: type = UTType.tiff.identifier as CFString
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return nil
        }
        let properties: CFDictionary? = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: compression] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

extension NSImage {
    /// Encodes the image to the given format. JPEG uses the supplied compression quality (0…1).
    func data(format: ImageFormat, compression: CGFloat = 0.9) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
        case .tiff: return rep.representation(using: .tiff, properties: [:])
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
