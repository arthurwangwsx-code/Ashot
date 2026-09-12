import AppKit
import SwiftUI
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// Single source of truth for the app's activation policy. The app is a menu-bar accessory
/// by default, but the "Show in Dock" setting promotes it to a regular app with a Dock icon.
enum AppActivation {
    static func apply() {
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}

extension Notification.Name {
    static let ashotDockPreferenceChanged = Notification.Name("ashotDockPreferenceChanged")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When hosting unit tests, skip app setup so tests run headlessly — no global hotkey
        // registration, no menu bar item, no Screen Recording permission prompt.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        // Reopening a second copy should reveal the running application, not register another
        // set of hotkeys. The notification only reveals UI; it can never trigger a capture.
        if let bundle = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            DistributedNotificationCenter.default().postNotificationName(.ashotShowWelcome, object: bundle, userInfo: nil, deliverImmediately: true)
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        ProductPreferences.bootstrap()
        PermissionCoordinator.shared.showSetup = { WelcomeWindowController.shared.show() }
        PermissionCoordinator.shared.performIntent = { CaptureService.shared.perform($0) }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showWelcome), name: .ashotShowWelcome, object: Bundle.main.bundleIdentifier)

        setupMenuBarIcon()
        HotKeyManager.shared.registerAll()
        AppActivation.apply()
        if !ProcessInfo.processInfo.arguments.contains("--skip-permission-prompt") {
            ScreenCapturePermission.requestOnLaunchIfNeeded()
        }

        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            DispatchQueue.main.async { [weak self] in
                self?.openSettings()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--sample-editor") {
            CaptureService.shared.openEditor(with: WelcomeWindowController.sampleImage())
        }
        if ProcessInfo.processInfo.arguments.contains("--show-welcome") { WelcomeWindowController.shared.show() }

        // Internal smoke-test entry point for exercising the real overlay without depending on a
        // user-specific global shortcut. It is intentionally not exposed in the product UI.
        if ProcessInfo.processInfo.arguments.contains("--capture-area") {
            let delay = ProcessInfo.processInfo.arguments.contains("--open-settings") ? 3.0 : 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                CaptureService.shared.startAreaCapture()
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildMenu), name: .ashotShortcutsChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageDidChange), name: .ashotLanguageChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildMenu), name: .ashotRecentChanged, object: nil)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            PermissionCoordinator.shared.refresh()
        }
        NotificationCenter.default.addObserver(
            forName: .ashotDockPreferenceChanged, object: nil, queue: .main) { _ in
            AppActivation.apply()
        }
    }

    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Ashot")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        StatusBarAnimator.shared.statusItem = statusItem

        rebuildMenu()
    }

    @objc private func rebuildMenu() {
        guard statusItem != nil else { return }

        let menu = NSMenu()

        let bindings = HotKeyManager.shared.bindings

        addMenuItem(to: menu, title: L10n.string("Capture Area"), action: #selector(captureArea), shortcut: bindings[.captureArea]?.displayString ?? "")
        addMenuItem(to: menu, title: L10n.string("Sensitive Capture"), action: #selector(captureSensitive), shortcut: "")
        addMenuItem(to: menu, title: L10n.string("Capture Fullscreen"), action: #selector(captureFullscreen), shortcut: bindings[.captureFullscreen]?.displayString ?? "")
        addMenuItem(to: menu, title: L10n.string("Capture Window"), action: #selector(captureWindow), shortcut: bindings[.captureWindow]?.displayString ?? "")
        addMenuItem(to: menu, title: L10n.string("Capture with Delay (3s)"), action: #selector(captureDelayed), shortcut: bindings[.captureDelayed]?.displayString ?? "")
        addMenuItem(to: menu, title: L10n.string("Scrolling Capture"), action: #selector(captureScrolling), shortcut: bindings[.captureScrolling]?.displayString ?? "")
        menu.addItem(NSMenuItem.separator())
        addMenuItem(to: menu, title: L10n.string("Repeat Last Capture"), action: #selector(repeatLastCapture), shortcut: bindings[.repeatLast]?.displayString ?? "")
        menu.addItem(NSMenuItem.separator())
        addMenuItem(to: menu, title: L10n.string("Color Picker"), action: #selector(openColorPicker), shortcut: bindings[.colorPicker]?.displayString ?? "")
        menu.addItem(NSMenuItem.separator())
        addMenuItem(to: menu, title: L10n.string("History"), action: #selector(openHistory), shortcut: "")
        let recent = NSMenuItem(title: L10n.string("Recent Screenshots"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        for capture in RecentCaptureStore.shared.items {
            let title = "\(L10n.string(capture.source)) — \(capture.date.formatted(date: .omitted, time: .standard))"
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = capture.id.uuidString
            recentMenu.addItem(item)
        }
        if recentMenu.items.isEmpty { let item = NSMenuItem(title: L10n.string("No recent screenshots"), action: nil, keyEquivalent: ""); item.isEnabled = false; recentMenu.addItem(item) }
        recent.submenu = recentMenu; menu.addItem(recent)
        addMenuItem(to: menu, title: L10n.string("Open Image..."), action: #selector(openImage), shortcut: "")
        addMenuItem(to: menu, title: L10n.string("Edit Clipboard Image"), action: #selector(editClipboardImage), shortcut: "")
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(
            title: L10n.string("Settings..."),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)
        addMenuItem(to: menu, title: L10n.string("Getting Started & Permissions"), action: #selector(showWelcome), shortcut: "")
        menu.addItem(NSMenuItem.separator())
        addMenuItem(to: menu, title: L10n.string("Quit Ashot"), action: #selector(quitApp), shortcut: "⌘Q")

        statusItem.menu = menu
    }

    private func addMenuItem(to menu: NSMenu, title: String, action: Selector, shortcut: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13)
        ]
        let shortcutAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let fullString = NSMutableAttributedString(string: title, attributes: attrs)
        if !shortcut.isEmpty {
            fullString.append(NSAttributedString(string: "  \(shortcut)", attributes: shortcutAttrs))
        }
        item.attributedTitle = fullString

        menu.addItem(item)
    }

    @objc private func captureArea() {
        CaptureService.shared.startAreaCapture()
    }
    @objc private func captureSensitive() { CaptureService.shared.startAreaCapture(sensitive: true) }
    @objc private func showWelcome() { WelcomeWindowController.shared.show() }
    @objc private func openRecent(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let capture = RecentCaptureStore.shared.items.first(where: { $0.id.uuidString == id }) else { return }
        CaptureService.shared.openEditor(with: capture.image)
    }
    @objc private func editClipboardImage() {
        guard let image = NSImage(pasteboard: .general) else { UserNotice.show("The clipboard does not contain an image."); return }
        CaptureService.shared.openEditor(with: image)
    }
    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.openImageURL(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    private func openImageURL(_ url: URL) {
        do {
            CaptureService.shared.openEditor(with: try ImageImportService.load(url))
        } catch { UserNotice.show("The image could not be opened", detail: error.localizedDescription, duration: 10) }
    }
    func application(_ application: NSApplication, open urls: [URL]) { for url in urls.prefix(8) where url.isFileURL { openImageURL(url) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WelcomeWindowController.shared.show() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard EditorWindowController.hasUnsavedDocuments else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L10n.string("Some images have unsaved changes")
        alert.informativeText = L10n.string("Return to the editors to copy or save your changes. Quitting without saving discards them.")
        alert.addButton(withTitle: L10n.string("Keep Editing"))
        alert.addButton(withTitle: L10n.string("Quit Without Saving"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    @objc private func captureFullscreen() {
        CaptureService.shared.captureFullscreen()
    }

    @objc private func captureWindow() {
        CaptureService.shared.captureWindow()
    }

    @objc private func captureDelayed() {
        CaptureService.shared.captureWithDelay(seconds: 3)
    }

    @objc private func captureScrolling() {
        ScrollingCaptureService.shared.startScrollingCapture()
    }

    @objc private func repeatLastCapture() {
        CaptureService.shared.repeatLastCapture()
    }

    @objc private func openColorPicker() {
        if let formatStr = UserDefaults.standard.string(forKey: "colorFormat"),
           let format = ColorFormat(rawValue: formatStr) {
            ColorPickerService.shared.preferredFormat = format
        }
        ColorPickerService.shared.start()
    }

    @objc private func openHistory() {
        if let window = historyWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hostingView = NSHostingView(rootView: LocalizedRoot { HistoryView() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = L10n.string("Screenshot History")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: LocalizedRoot { SettingsView() })
        hostingView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = L10n.string("Ashot Settings")
        window.isReleasedWhenClosed = false
        window.center()

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func languageDidChange() {
        rebuildMenu()
        historyWindow?.title = L10n.string("Screenshot History")
        settingsWindow?.title = L10n.string("Ashot Settings")
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
