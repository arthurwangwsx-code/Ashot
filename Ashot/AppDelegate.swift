import AppKit
import SwiftUI
import Carbon.HIToolbox

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
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(
            title: L10n.string("Settings..."),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)
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
