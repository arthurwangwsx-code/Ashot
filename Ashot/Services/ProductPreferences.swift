import AppKit
import SwiftUI

enum ProductPreferences {
    /// Run before showing settings. Existing installations retain persistent history; new
    /// installations start session-only. This never deletes or migrates an existing library.
    static func bootstrap(defaults: UserDefaults = .standard, hasExistingHistory: Bool? = nil) {
        initializeConsent(defaults: defaults, hasExistingHistory: hasExistingHistory)
        guard defaults.integer(forKey: "productPreferencesVersion") < 2 else { return }
        let legacy = defaults.bool(forKey: "existingUserMigration")
        let values: [String: Any] = ["historyMaximumCount": 200, "historyMaximumDays": legacy ? 0 : 30,
            "historyMaximumMB": legacy ? 0 : 1024, "previewTimeout": 10.0, "captureDelay": 3,
            "jpegQuality": 0.9, "exportScale": "native", "scrollingMode": "manual", "scrollingInterval": 0.65,
            "restoreDraftsEnabled": false]
        for (key, value) in values where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(2, forKey: "productPreferencesVersion")
    }
    private static func initializeConsent(defaults: UserDefaults, hasExistingHistory: Bool?) {
        guard defaults.integer(forKey: "productPreferencesVersion") < 1 else { return }
        let oldKeys = ["saveLocation", "showPreview", "autoCopy", "historyFolder", "shortcutBindings", "appLanguage"]
        let legacyPreferences = oldKeys.contains { defaults.object(forKey: $0) != nil }
        let legacyHistory: Bool
        if let hasExistingHistory { legacyHistory = hasExistingHistory }
        else {
            let path = defaults.string(forKey: "historyFolder") ?? ""
            let folder = path.isEmpty ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Ashot/History") :
                URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            legacyHistory = folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("history_metadata.json").path) } ?? false
        }
        if defaults.object(forKey: "historyEnabled") == nil { defaults.set(legacyPreferences || legacyHistory, forKey: "historyEnabled") }
        if defaults.object(forKey: "confirmAreaSelection") == nil { defaults.set(!(legacyPreferences || legacyHistory), forKey: "confirmAreaSelection") }
        if legacyPreferences || legacyHistory { defaults.set(true, forKey: "existingUserMigration") }
        defaults.set(1, forKey: "productPreferencesVersion")
    }
}

struct CapturePolicy: Equatable, Sendable {
    let sensitive: Bool
    let autoCopy: Bool
    let autoSave: Bool
    let persistentHistory: Bool
    let preview: Bool
    let directEdit: Bool
    let destination: String
    let format: ImageFormat
    let exportOptions: ExportOptions

    init(defaults: UserDefaults = .standard, sensitive: Bool = false) {
        self.sensitive = sensitive
        autoCopy = !sensitive && (defaults.object(forKey: "autoCopy") as? Bool ?? true)
        autoSave = !sensitive && defaults.bool(forKey: "autoSave")
        persistentHistory = !sensitive && defaults.bool(forKey: "historyEnabled")
        preview = !sensitive && (defaults.object(forKey: "showPreview") as? Bool ?? true)
        directEdit = sensitive || defaults.bool(forKey: "directEdit")
        destination = defaults.string(forKey: "saveLocation") ?? "~/Desktop"
        format = ImageFormat(rawValue: defaults.string(forKey: "imageFormat") ?? "png") ?? .png
        exportOptions = ExportOptions(format: format, quality: defaults.object(forKey: "jpegQuality") as? Double ?? 0.9,
            scale: ExportOptions.Scale(rawValue: defaults.string(forKey: "exportScale") ?? "native") ?? .native)
    }
}

struct RecentCapture: Identifiable {
    let id = UUID()
    let image: NSImage
    let source: String
    let date = Date()
    let pixels: Int
}

@Observable
final class RecentCaptureStore {
    static let shared = RecentCaptureStore()
    private(set) var items: [RecentCapture] = []
    static let maximumPixels = 64_000_000
    static let maximumItems = 8

    @discardableResult
    func add(image: NSImage, source: String, sensitive: Bool = false) -> RecentCapture? {
        guard !sensitive, let raster = CapturedImageSnapshot(image: image)?.cgImage else { return nil }
        let pixels = raster.width * raster.height
        guard pixels <= Self.maximumPixels else { return nil }
        while items.count >= Self.maximumItems || items.reduce(0, { $0 + $1.pixels }) + pixels > Self.maximumPixels {
            guard !items.isEmpty else { break }; items.removeLast()
        }
        let item = RecentCapture(image: image, source: source, pixels: pixels)
        items.insert(item, at: 0)
        NotificationCenter.default.post(name: .ashotRecentChanged, object: nil)
        return item
    }
    func clear() { items.removeAll(); NotificationCenter.default.post(name: .ashotRecentChanged, object: nil) }
    func openLatest() {
        guard let image = items.first?.image else { UserNotice.show("No recent screenshot. Capture or open an image first."); return }
        CaptureService.shared.openEditor(with: image)
    }
}

extension Notification.Name {
    static let ashotRecentChanged = Notification.Name("ashotRecentChanged")
    static let ashotShowWelcome = Notification.Name("ashotShowWelcome")
}

/// Non-activating feedback. A failed save never closes its editor/preview or steals focus.
final class UserNotice {
    private static var controller: NSWindowController?
    private static var generation = UUID()
    static func show(_ key: String, detail: String? = nil, duration: Double = 5) {
        let id = UUID(); generation = id
        controller?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: detail == nil ? 70 : 110),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false; panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: LocalizedRoot {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(key)).font(.callout.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        })
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: frame.maxX - panel.frame.width - 20, y: frame.minY + 20)) }
        controller = NSWindowController(window: panel); panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, duration)) {
            if generation == id { controller?.close(); controller = nil }
        }
    }
}
