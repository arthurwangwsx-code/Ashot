import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureCompletionOptions: Equatable {
    let showPreview: Bool, autoCopy: Bool, autoSave: Bool
    init(showPreview: Bool?, autoCopy: Bool?, autoSave: Bool) {
        self.showPreview = showPreview ?? true; self.autoCopy = autoCopy ?? true; self.autoSave = autoSave
    }
}

enum CaptureMode: String, Sendable {
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

enum CaptureFailure: LocalizedError {
    case displayUnavailable, windowUnavailable, invalidCaptureRegion, permissionUnavailable
    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return L10n.string("The selected display changed or disconnected. Select the capture area again.")
        case .windowUnavailable: return L10n.string("The selected window is no longer available. Choose another window.")
        case .invalidCaptureRegion: return L10n.string("The capture area is invalid or too large. Select a smaller area.")
        case .permissionUnavailable: return L10n.string("Screen access is unavailable. Check Permissions in Ashot settings.")
        }
    }
}

enum CaptureGeometry {
    nonisolated static let maximumPixelDimension = 32_768
    nonisolated static let maximumPixelCount = 64_000_000
    nonisolated static func validatedSourceRect(_ rect: CGRect, displaySize: CGSize) -> CGRect? {
        guard AreaSelectionView.isFinite(rect), displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else { return nil }
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        guard !clipped.isNull, clipped.width > 3, clipped.height > 3 else { return nil }
        return clipped
    }
    nonisolated static func outputPixelSize(logicalSize: CGSize, scale: Int) -> (width: Int, height: Int)? {
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0, scale > 0 else { return nil }
        let width = logicalSize.width * CGFloat(scale), height = logicalSize.height * CGFloat(scale)
        guard width <= CGFloat(maximumPixelDimension), height <= CGFloat(maximumPixelDimension),
              width.rounded() * height.rounded() <= CGFloat(maximumPixelCount), width >= 1, height >= 1 else { return nil }
        return (Int(width.rounded()), Int(height.rounded()))
    }
    nonisolated static func excludesWindow(owner: String?, layer: Int, ownBundle: String?, hideDesktopIcons: Bool) -> Bool {
        if let ownBundle, owner == ownBundle { return true }
        // Finder's ordinary windows are layer zero. Only desktop surfaces are filtered; no
        // defaults writes, Finder relaunches, or global desktop mutations are used.
        return hideDesktopIcons && owner == "com.apple.finder" && layer < 0
    }
}

struct CaptureDisplaySnapshot: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let backingScale: CGFloat
    let vendor: UInt32, model: UInt32, serial: UInt32
    init(screen: NSScreen) {
        id = screen.displayID; frame = screen.frame; backingScale = screen.backingScaleFactor
        vendor = CGDisplayVendorNumber(id); model = CGDisplayModelNumber(id); serial = CGDisplaySerialNumber(id)
    }
    init(id: CGDirectDisplayID, frame: CGRect, backingScale: CGFloat, vendor: UInt32 = 0, model: UInt32 = 0, serial: UInt32 = 0) {
        self.id = id; self.frame = frame; self.backingScale = backingScale
        self.vendor = vendor; self.model = model; self.serial = serial
    }
    func matchingScreen() -> NSScreen? { NSScreen.screens.first { Self(screen: $0) == self } }
}

enum ImageSaveError: LocalizedError {
    case encodingFailed
    var errorDescription: String? { L10n.string("The screenshot could not be encoded in the selected image format.") }
}

final class CaptureService {
    static let shared = CaptureService()
    private enum Target {
        case display(CaptureDisplaySnapshot, CGRect?, CaptureMode)
        case window(CGWindowID, pid_t)
    }
    private var lastCapture: (target: Target, sensitive: Bool)?
    private var session = UUID()
    private var task: Task<Void, Never>?
    private var areaSelector: AreaSelectionController?
    private var windowSelector: WindowSelectionController?
    private var countdown: CaptureCountdown?
    private var screenObserver: Any?
    private(set) var isCapturing = false

    private init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isCapturing else { return }
            self.cancelActive(); UserNotice.show("The display configuration changed. Select the capture area again.")
        }
    }
    var autoSave: Bool { UserDefaults.standard.bool(forKey: "autoSave") }
    var autoCopy: Bool { UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true }
    var showPreview: Bool { UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true }
    var captureSound: Bool { UserDefaults.standard.object(forKey: "captureSound") as? Bool ?? true }
    var retinaDownscale: Bool { UserDefaults.standard.bool(forKey: "retinaDownscale") }
    var saveLocation: String { UserDefaults.standard.string(forKey: "saveLocation") ?? "~/Desktop" }
    var imageFormat: String { UserDefaults.standard.string(forKey: "imageFormat") ?? "png" }
    var hideDesktopIcons: Bool { UserDefaults.standard.bool(forKey: "hideDesktopIcons") }
    var windowShadow: Bool { UserDefaults.standard.object(forKey: "windowShadow") as? Bool ?? true }

    func perform(_ intent: CaptureIntent) {
        switch intent {
        case .area: startAreaCapture()
        case .sensitiveArea: startAreaCapture(sensitive: true)
        case .fullscreen: captureFullscreen()
        case .window: captureWindow()
        case .delayed: captureWithDelay(seconds: UserDefaults.standard.object(forKey: "captureDelay") as? Int ?? 3)
        case .scrolling: ScrollingCaptureService.shared.startScrollingCapture()
        case .colorPicker: ColorPickerService.shared.start()
        }
    }

    func cancelActive() {
        session = UUID(); isCapturing = false
        task?.cancel(); task = nil
        areaSelector?.cancel(); areaSelector = nil
        windowSelector?.cancel(); windowSelector = nil
        countdown?.cancel(); countdown = nil
    }
    private func beginSession(_ intent: CaptureIntent) -> UUID? {
        cancelActive()
        guard ScreenCapturePermission.ensureAccess(intent: intent) else { return nil }
        isCapturing = true
        return session
    }
    private var mouseScreen: NSScreen? { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main }

    func startAreaCapture(sensitive: Bool = false) {
        guard let id = beginSession(sensitive ? .sensitiveArea : .area) else { return }
        selectArea(id: id, policy: CapturePolicy(sensitive: sensitive))
    }
    private func selectArea(id: UUID, policy: CapturePolicy) {
        guard session == id else { return }
        let selector = AreaSelectionController(); areaSelector = selector
        selector.beginSelection { [weak self] result in
            guard let self, self.session == id else { return }
            self.areaSelector = nil
            switch result {
            case .area(let rect, let displayID):
                guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { self.finishFailure(CaptureFailure.displayUnavailable, id: id); return }
                self.captureDisplay(CaptureDisplaySnapshot(screen: screen), region: rect, mode: .area, id: id, policy: policy)
            case .frontmostWindow: self.selectWindow(id: id, policy: policy)
            case .cancelled: self.isCapturing = false
            }
        }
    }
    func captureFullscreen() {
        let target = mouseScreen.map(CaptureDisplaySnapshot.init(screen:))
        guard let id = beginSession(.fullscreen) else { return }
        guard let target else { finishFailure(CaptureFailure.displayUnavailable, id: id); return }
        captureDisplay(target, region: nil, mode: .fullscreen, id: id, policy: CapturePolicy())
    }
    func captureWindow() {
        guard let id = beginSession(.window) else { return }
        selectWindow(id: id, policy: CapturePolicy())
    }
    private func selectWindow(id: UUID, policy: CapturePolicy) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard self.session == id, !Task.isCancelled else { return }
                let selector = WindowSelectionController(); self.windowSelector = selector
                selector.begin(windows: content.windows) { [weak self] result in
                    guard let self, self.session == id else { return }
                    self.windowSelector = nil
                    switch result {
                    case .window(let window): self.captureSelectedWindow(window.windowID, processID: window.owningApplication?.processID ?? 0, id: id, policy: policy)
                    case .area: self.selectArea(id: id, policy: policy)
                    case .cancelled: self.isCapturing = false
                    }
                }
            } catch { self.finishFailure(error, id: id) }
        }
    }
    func captureWithDelay(seconds: Int) {
        let target = mouseScreen.map(CaptureDisplaySnapshot.init(screen:))
        guard let id = beginSession(.delayed) else { return }
        guard let target else { finishFailure(CaptureFailure.displayUnavailable, id: id); return }
        let policy = CapturePolicy()
        let countdown = CaptureCountdown(); self.countdown = countdown
        countdown.start(seconds: seconds, screen: target.matchingScreen(), completion: { [weak self] in
            guard let self, self.session == id else { return }
            self.countdown = nil
            self.captureDisplay(target, region: nil, mode: .delayed, id: id, policy: policy)
        }, cancelled: { [weak self] in if self?.session == id { self?.isCapturing = false } })
    }
    func captureRect(_ rect: CGRect, screenID: CGDirectDisplayID) {
        guard let id = beginSession(.area) else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == screenID }) else { finishFailure(CaptureFailure.displayUnavailable, id: id); return }
        captureDisplay(CaptureDisplaySnapshot(screen: screen), region: rect, mode: .area, id: id, policy: CapturePolicy())
    }
    func repeatLastCapture() {
        guard let last = lastCapture else { startAreaCapture(); return }
        guard let id = beginSession(last.sensitive ? .sensitiveArea : .area) else { return }
        let policy = CapturePolicy(sensitive: last.sensitive)
        switch last.target {
        case .display(let display, let rect, let mode):
            guard display.matchingScreen() != nil else {
                UserNotice.show("The display configuration changed. Select the capture area again.")
                selectArea(id: id, policy: policy); return
            }
            captureDisplay(display, region: rect, mode: mode, id: id, policy: policy)
        case .window(let windowID, let processID): captureSelectedWindow(windowID, processID: processID, id: id, policy: policy)
        }
    }

    /// Reused by scrolling capture: immutable target, explicit filtering and no global side effects.
    static func captureFrame(display snapshot: CaptureDisplaySnapshot, region: CGRect?, downscale: Bool, hideDesktopIcons: Bool) async throws -> (CGImage, CGSize) {
        guard let screen = snapshot.matchingScreen() else { throw CaptureFailure.displayUnavailable }
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permissionUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard snapshot.matchingScreen() != nil, let display = content.displays.first(where: { $0.displayID == snapshot.id }) else { throw CaptureFailure.displayUnavailable }
        let logicalSize: CGSize
        let safeRegion: CGRect?
        if let region {
            guard let safe = CaptureGeometry.validatedSourceRect(region, displaySize: screen.frame.size) else { throw CaptureFailure.invalidCaptureRegion }
            safeRegion = safe; logicalSize = safe.size
        } else { safeRegion = nil; logicalSize = screen.frame.size }
        let scale = downscale ? 1 : max(1, Int(snapshot.backingScale.rounded()))
        guard let pixels = CaptureGeometry.outputPixelSize(logicalSize: logicalSize, scale: scale) else { throw CaptureFailure.invalidCaptureRegion }
        let excluded = content.windows.filter {
            CaptureGeometry.excludesWindow(owner: $0.owningApplication?.bundleIdentifier, layer: $0.windowLayer,
                ownBundle: Bundle.main.bundleIdentifier, hideDesktopIcons: hideDesktopIcons)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width; configuration.height = pixels.height
        configuration.capturesAudio = false; configuration.showsCursor = false
        if let safeRegion { configuration.sourceRect = safeRegion }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard snapshot.matchingScreen() != nil else { throw CaptureFailure.displayUnavailable }
        return (image, logicalSize)
    }

    private func captureDisplay(_ display: CaptureDisplaySnapshot, region: CGRect?, mode: CaptureMode, id: UUID, policy: CapturePolicy) {
        let downscale = retinaDownscale, hideIcons = hideDesktopIcons
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Give a dismissed selection overlay one compositing turn before capture.
                try await Task.sleep(for: .milliseconds(40))
                let (raster, size) = try await Self.captureFrame(display: display, region: region, downscale: downscale, hideDesktopIcons: hideIcons)
                guard self.session == id, !Task.isCancelled else { return }
                self.lastCapture = (.display(display, region, mode), policy.sensitive)
                let anchor = region.map { Self.appKitCaptureFrame(sourceRect: $0, screenFrame: display.frame) } ?? display.frame
                self.isCapturing = false
                self.handleCapturedImage(NSImage(cgImage: raster, size: size), source: mode, previewAnchor: anchor, policy: policy)
            } catch is CancellationError { }
            catch { self.finishFailure(error, id: id) }
        }
    }
    private func captureSelectedWindow(_ windowID: CGWindowID, processID: pid_t, id: UUID, policy: CapturePolicy) {
        let downscale = retinaDownscale, shadow = windowShadow
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(40))
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == processID && $0.isOnScreen }) else { throw CaptureFailure.windowUnavailable }
                let frame = ScreenCoordinates.appKitRect(fromQuartz: window.frame, primaryTop: ScreenCoordinates.primaryTop)
                let screen = NSScreen.screens.max { $0.frame.intersection(frame).safeArea < $1.frame.intersection(frame).safeArea }
                let scale = downscale ? 1 : max(1, Int(screen?.backingScaleFactor.rounded() ?? 1))
                guard let pixels = CaptureGeometry.outputPixelSize(logicalSize: window.frame.size, scale: scale) else { throw CaptureFailure.invalidCaptureRegion }
                let configuration = SCStreamConfiguration()
                configuration.width = pixels.width; configuration.height = pixels.height
                configuration.showsCursor = false; configuration.capturesAudio = false
                configuration.ignoreShadowsSingleWindow = true
                let raster = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                guard self.session == id, !Task.isCancelled else { return }
                let image = shadow ? try Self.withShadow(raster, logicalSize: window.frame.size, scale: CGFloat(scale)) : NSImage(cgImage: raster, size: window.frame.size)
                self.lastCapture = (.window(windowID, processID), policy.sensitive)
                self.isCapturing = false
                self.handleCapturedImage(image, source: .window, previewAnchor: frame, policy: policy)
            } catch is CancellationError { }
            catch { self.finishFailure(error, id: id) }
        }
    }

    func handleCapturedImage(_ image: NSImage, source mode: CaptureMode, previewAnchor: CGRect? = nil, policy: CapturePolicy? = nil) {
        let policy = policy ?? CapturePolicy()
        StatusBarAnimator.shared.flash(type: .capture)
        if captureSound { NSSound(named: "Tink")?.play() }
        if policy.autoCopy {
            NSPasteboard.general.clearContents()
            if !NSPasteboard.general.writeObjects([image]) { UserNotice.show("The clipboard could not be updated. The screenshot is still available.") }
        }
        RecentCaptureStore.shared.add(image: image, source: mode.historySource, sensitive: policy.sensitive)
        if policy.directEdit { openEditor(with: image, sensitive: policy.sensitive) }
        else if policy.preview { ThumbnailPreviewController.shared.show(image: image, anchorRect: previewAnchor) }
        guard !policy.sensitive, let snapshot = CapturedImageSnapshot(image: image) else { return }
        if policy.persistentHistory { HistoryManager.shared.add(snapshot: snapshot, source: mode.historySource) }
        if policy.autoSave {
            let directory = URL(fileURLWithPath: NSString(string: policy.destination).expandingTildeInPath, isDirectory: true)
            let frozenOptions = policy.exportOptions
            Task.detached(priority: .utility) {
                do { _ = try ExportService.saveUnique(snapshot, options: frozenOptions, in: directory) }
                catch { await MainActor.run { UserNotice.show("Automatic save failed. Your screenshot is still available in this session.", detail: error.localizedDescription, duration: 10) } }
            }
        }
    }
    func openEditor(with image: NSImage, sensitive: Bool = false) {
        EditorWindowController(image: image, sensitive: sensitive).showWindow(nil)
    }
    @discardableResult
    func saveImageToConfiguredLocation(_ image: NSImage) throws -> URL {
        guard let snapshot = CapturedImageSnapshot(image: image) else { throw ImageSaveError.encodingFailed }
        let directory = URL(fileURLWithPath: NSString(string: saveLocation).expandingTildeInPath, isDirectory: true)
        return try ExportService.saveUnique(snapshot, options: .current, in: directory)
    }
    /// Compatibility helper for suggested names; actual writes use an atomic no-overwrite claim.
    nonisolated static func uniqueScreenshotURL(in directory: URL, format: ImageFormat, date: Date = Date(), fileManager: FileManager = .default) -> URL {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let base = "Screenshot_\(formatter.string(from: date))"
        var result = directory.appendingPathComponent("\(base).\(format.fileExtension)"), suffix = 2
        while fileManager.fileExists(atPath: result.path) { result = directory.appendingPathComponent("\(base)-\(suffix).\(format.fileExtension)"); suffix += 1 }
        return result
    }
    nonisolated static func appKitCaptureFrame(sourceRect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + sourceRect.minX, y: screenFrame.maxY - sourceRect.maxY, width: sourceRect.width, height: sourceRect.height)
    }
    nonisolated static func appKitWindowFrame(windowFrame: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        ScreenCoordinates.appKitRect(fromQuartz: windowFrame, primaryTop: primaryScreenFrame.maxY)
    }
    private func finishFailure(_ error: Error, id: UUID) {
        guard session == id else { return }; isCapturing = false
        UserNotice.show("Screenshot could not be completed", detail: error.localizedDescription, duration: 10)
        PermissionCoordinator.shared.refresh()
    }
    private static func withShadow(_ image: CGImage, logicalSize: CGSize, scale: CGFloat) throws -> NSImage {
        let margin = Int(32 * scale), width = image.width + 2 * margin, height = image.height + 2 * margin
        guard width * height <= CaptureGeometry.maximumPixelCount, width <= CaptureGeometry.maximumPixelDimension,
              height <= CaptureGeometry.maximumPixelDimension,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderFailure.tooLarge }
        context.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 16 * scale, color: CGColor(gray: 0, alpha: 0.3))
        context.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw RenderFailure.allocationFailed }
        return NSImage(cgImage: result, size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }
}

private extension CGRect { var safeArea: CGFloat { isNull || isInfinite ? 0 : width * height } }

enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, tiff
    nonisolated var fileExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

struct CapturedImageSnapshot: @unchecked Sendable {
    let cgImage: CGImage
    let logicalSize: CGSize
    init?(image: NSImage) {
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }), let raster = bitmap.cgImage {
            cgImage = raster; logicalSize = image.size; return
        }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let raster = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cgImage = raster; logicalSize = image.size
    }
    nonisolated init(cgImage: CGImage, logicalSize: CGSize) { self.cgImage = cgImage; self.logicalSize = logicalSize }
    nonisolated func data(format: ImageFormat, compression: CGFloat = 0.9) -> Data? {
        try? ExportService.encode(cgImage, options: ExportOptions(format: format, quality: Double(compression)))
    }
}

extension NSImage {
    func data(format: ImageFormat, compression: CGFloat = 0.9) -> Data? {
        CapturedImageSnapshot(image: self)?.data(format: format, compression: compression)
    }
}
extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
}
