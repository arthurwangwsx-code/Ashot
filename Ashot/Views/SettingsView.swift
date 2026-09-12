import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, capture, shortcuts, storage, tools, permissions, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L10n.string("General")
        case .capture: return L10n.string("Capture & Preview")
        case .shortcuts: return L10n.string("Shortcuts")
        case .storage: return L10n.string("Saving & History")
        case .tools: return L10n.string("Tools")
        case .permissions: return L10n.string("Permissions & Privacy")
        case .about: return L10n.string("Updates & About")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "camera.viewfinder"
        case .shortcuts: return "keyboard"
        case .storage: return "externaldrive"
        case .tools: return "wrench.and.screwdriver"
        case .permissions: return "lock.shield"
        case .about: return "arrow.triangle.2.circlepath"
        }
    }
}

struct SettingsView: View {
    @State private var page: SettingsPage? = .general
    @AppStorage("appLanguage") private var language = "system"
    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 270)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text((page ?? .general).title).font(.title2.bold()).padding(.horizontal, 24).padding(.top, 20)
                switch page ?? .general {
                case .general: GeneralProductSettings()
                case .capture: CaptureProductSettings()
                case .shortcuts: ShortcutSettingsView()
                case .storage: StorageProductSettings()
                case .tools: ToolsProductSettings()
                case .permissions: PermissionsProductSettings()
                case .about: AboutProductSettings()
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 780, minHeight: 580)
        .environment(\.locale, AppLanguage.locale(for: language))
        .onDisappear { ShortcutRecordingCoordinator.shared.cancel() }
    }
}

private struct GeneralProductSettings: View {
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("showInDock") private var showInDock = false
    @State private var login = LoginItemController()
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Language:", selection: $language) {
                    Text("Follow System").tag("system"); Text("English").tag("en"); Text("Simplified Chinese").tag("zh-Hans")
                }.onChange(of: language) { NotificationCenter.default.post(name: .ashotLanguageChanged, object: nil) }
                Toggle("Show app icon in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { NotificationCenter.default.post(name: .ashotDockPreferenceChanged, object: nil) }
                Text("Ashot is always available from the menu-bar camera icon.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Start Ashot at login", isOn: Binding(get: { login.isEnabled }, set: login.setEnabled)).disabled(login.busy)
                if login.requiresApproval {
                    Text("macOS requires approval before Ashot can start at login.").font(.caption)
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = login.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Getting Started") {
                Button("Getting Started & Permissions") { WelcomeWindowController.shared.show() }
                Button("Try a sample image") { CaptureService.shared.openEditor(with: WelcomeWindowController.sampleImage()) }
                Text("The sample image is generated locally. No screenshot or permission request is needed.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
}

@Observable
private final class LoginItemController {
    var isEnabled = false
    var requiresApproval = false
    var busy = false
    var error: String?
    func refresh() {
        guard !busy else { return }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }
    func setEnabled(_ value: Bool) {
        guard !busy else { return }; busy = true; error = nil
        Task {
            do {
                if value { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { self.error = error.localizedDescription }
            busy = false; refresh()
        }
    }
}

private struct CaptureProductSettings: View {
    @AppStorage("autoCopy") private var autoCopy = true
    @AppStorage("directEdit") private var directEdit = false
    @AppStorage("showPreview") private var showPreview = true
    @AppStorage("previewTimeout") private var previewTimeout = 10.0
    @AppStorage("confirmAreaSelection") private var confirmArea = true
    @AppStorage("captureDelay") private var delay = 3
    @AppStorage("windowShadow") private var shadow = true
    @AppStorage("hideDesktopIcons") private var hideIcons = false
    @AppStorage("retinaDownscale") private var downscale = false
    @AppStorage("captureSound") private var sound = true
    var body: some View {
        Form {
            Section("After Capture") {
                Toggle("Automatically copy to clipboard", isOn: $autoCopy)
                Toggle("Open the editor immediately", isOn: $directEdit)
                Toggle("Show thumbnail preview", isOn: $showPreview).disabled(directEdit)
                Picker("Dismiss preview after", selection: $previewTimeout) {
                    Text("Never").tag(0.0)
                    ForEach([5.0, 10, 15, 30], id: \.self) { Text(L10n.string("%d seconds", Int($0))).tag($0) }
                }.disabled(directEdit || !showPreview)
                Text("The preview pauses while you hover, save, drag or recognize text. Recent screenshots are available from the menu.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Selection") {
                Toggle("Confirm area selection with Return", isOn: $confirmArea)
                Text("When enabled, drag inside a selection to move it or drag a corner to resize it. Hold Shift for a square. Space switches to window selection.").font(.caption).foregroundStyle(.secondary)
                Picker("Screenshot delay", selection: $delay) {
                    ForEach([3, 5, 10], id: \.self) { Text(L10n.string("%d seconds", $0)).tag($0) }
                }
                Toggle("Include window shadow", isOn: $shadow)
                Toggle("Hide desktop icons during capture", isOn: $hideIcons)
                Text("Desktop icons are filtered out of the image. Finder and your desktop preferences are not changed.").font(.caption).foregroundStyle(.secondary)
                Toggle("Downscale Retina to 1x", isOn: $downscale)
                Toggle("Play capture sound", isOn: $sound)
            }
        }.formStyle(.grouped)
    }
}

private struct StorageProductSettings: View {
    @Bindable private var manager = HistoryManager.shared
    @AppStorage("autoSave") private var autoSave = false
    @AppStorage("saveLocation") private var saveLocation = "~/Desktop"
    @AppStorage("imageFormat") private var format = "png"
    @AppStorage("jpegQuality") private var quality = 0.9
    @AppStorage("exportScale") private var scale = "native"
    @AppStorage("historyEnabled") private var history = false
    @AppStorage("historyFilenameTemplate") private var template = "Screenshot_{date}_{time}"
    @AppStorage("historyMaximumCount") private var maximumCount = 200
    @AppStorage("historyMaximumDays") private var maximumDays = 0
    @AppStorage("historyMaximumMB") private var maximumMB = 0
    @State private var applyLimits = false
    var body: some View {
        Form {
            Section("Save Options") {
                Toggle("Automatically save to selected folder", isOn: $autoSave)
                LabeledContent("Save Location:") {
                    Text(saveLocation).lineLimit(2).textSelection(.enabled)
                    Button("Choose...") { chooseSaveFolder() }
                }
                Picker("Image Format:", selection: $format) {
                    Text("PNG").tag("png"); Text("JPEG").tag("jpeg"); Text("TIFF").tag("tiff")
                }
                Slider(value: $quality, in: 0.2...1, step: 0.05) { Text("JPEG Quality") }.disabled(format != "jpeg")
                Picker("Export Scale", selection: $scale) {
                    Text("Original Pixels").tag("native"); Text("1×").tag("one"); Text("2×").tag("two")
                }
                Text("PNG and TIFF preserve transparency. JPEG is flattened onto white. These defaults are shared by every save action.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Persistent History") {
                Toggle("Keep local screenshot history", isOn: Binding(get: { history }, set: { manager.setEnabled($0) }))
                    .disabled(manager.isMigrating)
                Text("Disabling history does not delete existing images. Sensitive capture never saves the original automatically.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("History Folder:") {
                    Text(manager.storageFolder?.path ?? L10n.string("Unavailable")).lineLimit(3).textSelection(.enabled)
                }
                HStack {
                    Button("Change History Folder...") { manager.chooseMigrationDestination() }.disabled(manager.isBusy)
                    Button("Open Folder") { if let folder = manager.storageFolder { NSWorkspace.shared.open(folder) } }
                }
                Text("Changing the folder copies and verifies managed images before switching. The old folder is kept as a backup; Ashot does not remove it automatically.").font(.caption).foregroundStyle(.secondary)
                if let old = UserDefaults.standard.string(forKey: "historyPreviousFolder") {
                    Button("Show Previous Folder Backup") { NSWorkspace.shared.open(URL(fileURLWithPath: old)) }
                }
                if manager.isMigrating { ProgressView("Copying and verifying history…") }
                TextField("Filename Template", text: $template)
                Text("Placeholders: {date}, {time}, {source}, {uuid}").font(.caption).foregroundStyle(.secondary)
                Text(HistoryFileNaming.expanded(template, source: "Area", date: Date()) + ".png")
                    .font(.system(.caption, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
            }
            Section("History Limits") {
                Stepper(L10n.string("Maximum images: %d", maximumCount), value: $maximumCount, in: 10...1000, step: 10)
                Picker("Keep images for", selection: $maximumDays) {
                    Text("Unlimited time").tag(0)
                    ForEach([1, 7, 30, 90, 365], id: \.self) { Text(L10n.string("%d days", $0)).tag($0) }
                }
                Picker("Maximum disk usage", selection: $maximumMB) {
                    Text("Unlimited").tag(0)
                    ForEach([100, 250, 500, 1024, 5120], id: \.self) { Text(L10n.string("%d MB", $0)).tag($0) }
                }
                Text("Limits remove the oldest managed images on the next saved capture. Apply now to clean the current history immediately.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply Limits Now") { applyLimits = true }.disabled(manager.isBusy || manager.entries.isEmpty)
                    Button("Clear History", role: .destructive) { manager.clear() }.disabled(manager.isBusy || manager.entries.isEmpty)
                }
                LabeledContent("Current storage", value: ByteCountFormatter.string(fromByteCount: manager.usedBytes, countStyle: .file))
                if let error = manager.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                if manager.storageBlocked || manager.pendingCleanup > 0 {
                    Button("Retry Storage Check") { manager.retryStorage() }.disabled(manager.isBusy)
                    Text("Files changed outside Ashot are preserved. Check the folder before applying cleanup again.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
        .confirmationDialog("Apply history limits now?", isPresented: $applyLimits, titleVisibility: .visible) {
            Button("Apply and Remove Older Images", role: .destructive) { manager.applyRetention() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes managed images outside your limits. Other files and previous-folder backups are not deleted.") }
    }
    private func chooseSaveFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.begin { response in if response == .OK, let url = panel.url { saveLocation = url.path } }
    }
}

private struct ToolsProductSettings: View {
    @AppStorage("ocrLanguage") private var ocrLanguage = "auto"
    @AppStorage("ocrStripLinebreaks") private var strip = false
    @AppStorage("colorFormat") private var colorFormat = "HEX"
    @AppStorage("scrollingMode") private var scrollingMode = "manual"
    @AppStorage("scrollingInterval") private var scrollingInterval = 0.65
    var body: some View {
        Form {
            Section("Text & Barcode Recognition") {
                Picker("Language:", selection: $ocrLanguage) {
                    Text("Automatic").tag("auto"); Text("English").tag("en"); Text("Simplified Chinese").tag("zh-Hans")
                }
                Toggle("Strip linebreaks from recognized text", isOn: $strip)
                Text("Recognition uses the visible image, including its redactions. Choose Copy to place recognized text on the clipboard. QR links are never opened automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Color Picker") {
                Picker("Default Format:", selection: $colorFormat) {
                    ForEach(ColorFormat.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
            Section("Scrolling Capture") {
                Picker("Preferred scrolling mode", selection: $scrollingMode) {
                    Text("Manual — no control of other apps").tag("manual")
                    Text("Automatic — Accessibility required").tag("automatic")
                }
                Slider(value: $scrollingInterval, in: 0.4...1.5, step: 0.05) { Text("Page settling interval") }
                Text(L10n.string("%.2f seconds between samples", scrollingInterval)).font(.caption).foregroundStyle(.secondary)
                Text("Select only the scrolling content. Slower pages may need more time to settle. Automatic scrolling asks for Accessibility only when you start it.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Pinned Images") {
                Button("Close All Pinned Images") { PinService.shared.closeAll() }
                Text("Pinned images are local windows, not uploaded images.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct PermissionsProductSettings: View {
    @Bindable private var permission = PermissionCoordinator.shared
    @State private var accessibility = AccessibilityPermission.isAuthorized
    var body: some View {
        Form {
            Section("Screen Recording") {
                Label(permission.isAuthorized ? "Ready to capture" : "Screen access is not enabled yet", systemImage: permission.isAuthorized ? "checkmark.circle" : "lock.shield")
                HStack {
                    if !permission.isAuthorized { Button("Grant Screen Access") { permission.requestFromUserGesture() }.disabled(permission.state == .requesting) }
                    Button("Open System Settings") { permission.openSettingsFromUserGesture() }
                    Button("Check Again") { refresh() }
                }
                Text("Screen Recording is used only after you start a capture. Returning from System Settings never starts a screenshot automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Accessibility") {
                Label(accessibility ? "Accessibility access is enabled" : "Accessibility is optional", systemImage: "hand.raised")
                Text("Only automatic scrolling needs to control another application. Area, fullscreen and window screenshots do not require Accessibility.").font(.caption).foregroundStyle(.secondary)
                Button("Open Accessibility Settings") { AccessibilityPermission.openSettings() }
            }
            Section("Privacy") {
                Text("Screenshots, OCR and history are processed on this Mac. Ashot does not upload images to GitHub. GitHub is used to distribute the application and updates.")
                Text("Use Sensitive Capture before taking a private screenshot. Its original is never copied, automatically saved, or added to recent images or history.")
                Text("Solid redaction creates opaque pixels in exported images. Blur and pixelation are visual effects, not secure erasure. Earlier copies may still exist in clipboard managers or backups.")
                Button("Clear Recent Session Images") { RecentCaptureStore.shared.clear() }
                Text("This clears only Ashot's session list, not editor windows, saved files or other applications' clipboards.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    private func refresh() { permission.refresh(); accessibility = AccessibilityPermission.isAuthorized }
}

struct AboutProductSettings: View {
    @State private var showDiagnostics = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown" }
    var body: some View {
        Form {
            Section("Ashot") {
                LabeledContent("Version", value: "\(version) (\(build))")
                Text("A local-first screenshot and annotation tool for macOS.")
                Button("View GitHub Releases") { ProductLinks.open(.releases) }
                Text("GitHub downloads do not require an account. Only install packages whose origin and signatures you trust.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Help & Feedback") {
                Button("User Guide") { ProductLinks.open(.guide) }
                Button("Report an Issue") { ProductLinks.open(.issues) }
                Button("Preview Diagnostics...") { showDiagnostics = true }
                Text("Diagnostics are shown for your review before saving. They contain no screenshots, text recognition results, file paths, window titles or credentials. Nothing is uploaded automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Source & Notices") {
                Button("Source Repository") { ProductLinks.open(.repository) }
                Text("Public source visibility is not a license grant. See the repository for distribution terms and third-party notices.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .sheet(isPresented: $showDiagnostics) { DiagnosticPreview() }
    }
}

enum ProductLinks {
    enum Destination { case repository, releases, issues, guide }
    static func open(_ destination: Destination) {
        let path: String
        switch destination {
        case .repository: path = ""
        case .releases: path = "/releases"
        case .issues: path = "/issues/new"
        case .guide: path = "/blob/main/README.md"
        }
        if let url = URL(string: "https://github.com/arthurwangwsx-code/Ashot" + path) { NSWorkspace.shared.open(url) }
    }
}

struct DiagnosticReport: Codable, Equatable, Sendable {
    let applicationVersion: String
    let build: String
    let operatingSystem: String
    let architecture: String
    let screenAccess: Bool
    let accessibilityAccess: Bool
    let connectedDisplayCount: Int
    let persistentHistoryEnabled: Bool
    let pendingHistoryOperations: Int
    let unfinishedEditorCount: Int
    let failedHotkeyCount: Int
    static func current() -> Self {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture,
            screenAccess: ScreenCapturePermission.isAuthorized, accessibilityAccess: AccessibilityPermission.isAuthorized,
            connectedDisplayCount: NSScreen.screens.count, persistentHistoryEnabled: HistoryManager.shared.enabled,
            pendingHistoryOperations: HistoryManager.shared.pendingOperations, unfinishedEditorCount: EditorWindowController.activeCount,
            failedHotkeyCount: HotKeyManager.shared.registrationFailures.count)
    }
    nonisolated func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self)
    }
}

private struct DiagnosticPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: Data?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Diagnostics").font(.title2.bold())
            Text("Review this information before choosing where to save it. Nothing is sent automatically.").font(.callout)
            ScrollView { Text(report.flatMap { String(data: $0, encoding: .utf8) } ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 300)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Save JSON...") {
                    guard let report else { return }
                    let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Ashot-diagnostics.json"
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        do { try report.write(to: url, options: .atomic); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(report == nil)
            }
        }.padding(24).frame(width: 570)
        .onAppear { do { report = try DiagnosticReport.current().encoded() } catch { self.error = error.localizedDescription } }
    }
}
