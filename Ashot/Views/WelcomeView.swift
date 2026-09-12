import AppKit
import SwiftUI

enum InstallationLocation {
    nonisolated static func needsRelocation(path: String, writable: Bool) -> Bool {
        !writable || path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") ||
        path.hasPrefix("/private/var/folders/") || path.hasPrefix("/tmp/") || path.contains("/Downloads/")
    }
}

final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()
    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.string("Welcome to Ashot"); window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 560, height: 560)
        window.contentView = NSHostingView(rootView: LocalizedRoot { WelcomeView() })
        super.init(window: window)
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        PermissionCoordinator.shared.refresh()
        window?.center(); showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    static func sampleImage() -> NSImage {
        // Generated locally with AppKit; no screen capture or network request occurs.
        let image = NSImage(size: CGSize(width: 900, height: 540))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill(); CGRect(x: 0, y: 0, width: 900, height: 540).fill()
        let title = L10n.string("Your first Ashot edit") as NSString
        title.draw(at: CGPoint(x: 64, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 38, weight: .bold), .foregroundColor: NSColor.labelColor])
        (L10n.string("Draw an arrow, add a note, crop, then undo. Your original stays intact.") as NSString)
            .draw(in: CGRect(x: 64, y: 260, width: 740, height: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.secondaryLabelColor])
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: CGRect(x: 64, y: 80, width: 740, height: 130), xRadius: 20, yRadius: 20).fill()
        (L10n.string("Example only — no screen content was captured.") as NSString)
            .draw(at: CGPoint(x: 94, y: 135), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.labelColor])
        image.unlockFocus()
        return image
    }
}

struct WelcomeView: View {
    @Bindable private var permission = PermissionCoordinator.shared
    @AppStorage("historyEnabled") private var history = false
    @AppStorage("autoCopy") private var autoCopy = true
    @AppStorage("directEdit") private var directEdit = false
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    private var needsInstallation: Bool {
        InstallationLocation.needsRelocation(path: Bundle.main.bundlePath, writable: FileManager.default.isWritableFile(atPath: Bundle.main.bundlePath))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "camera.viewfinder").font(.system(size: 42)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("Welcome to Ashot").font(.largeTitle.bold())
                        Text("Fast screenshots. Everything stays on this Mac.").foregroundStyle(.secondary)
                    }
                }
                Text("Ashot lives in your menu bar. Click the camera icon or press ⇧⌘2 to start.")
                if needsInstallation {
                    GroupBox("Install before granting access") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Drag Ashot into Applications, then open it from there. A stable location also helps permissions and updates work reliably.")
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        }.padding(6)
                    }
                }
                GroupBox("Screen Recording") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ashot needs screen access only when you start a capture. Editing existing images and recognizing their text do not need screen access.")
                        Label(permission.isAuthorized ? "Ready to capture" : "Screen access is not enabled yet",
                              systemImage: permission.isAuthorized ? "checkmark.circle.fill" : "lock.shield")
                        HStack {
                            if !permission.isAuthorized {
                                Button("Grant Screen Access") { permission.requestFromUserGesture() }
                                    .disabled(permission.state == .requesting || needsInstallation)
                                if permission.state == .waitingForSettings {
                                    Button("Open System Settings") { permission.openSettingsFromUserGesture() }
                                }
                            }
                            Button("Check Again") { permission.refresh() }
                        }
                        if permission.settingsOpenFailed || permission.state == .waitingForSettings {
                            Text("System Settings → Privacy & Security → Screen & System Audio Recording → Ashot. Return here after enabling access; a screenshot will not start automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Choose what happens after a capture") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("Automatically copy to clipboard", isOn: $autoCopy)
                        Toggle("Open the editor immediately", isOn: $directEdit)
                        Toggle("Keep local screenshot history", isOn: $history)
                            .onChange(of: history) { HistoryManager.shared.setEnabled(history) }
                        Text("With history off, recent images stay in memory for this session only. Existing history is not deleted. Sensitive capture never copies or saves the original automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                HStack {
                    Button("Try a sample image") {
                        WelcomeWindowController.shared.close()
                        CaptureService.shared.openEditor(with: WelcomeWindowController.sampleImage())
                    }
                    Spacer()
                    Button(permission.isAuthorized ? "Start My First Capture" : "Set Up Later") {
                        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                        WelcomeWindowController.shared.close()
                        if permission.isAuthorized { permission.continueFromUserGesture() } else { permission.cancelPending() }
                    }.buttonStyle(.borderedProminent)
                }
                Picker("Language:", selection: $language) {
                    Text("Follow System").tag("system"); Text("English").tag("en"); Text("Simplified Chinese").tag("zh-Hans")
                }.onChange(of: language) { NotificationCenter.default.post(name: .ashotLanguageChanged, object: nil) }
            }.padding(28)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permission.refresh() }
    }
}
