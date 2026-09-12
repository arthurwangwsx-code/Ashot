import AppKit
import CoreGraphics

enum ScreenCapturePermission {
    static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Ask once during first launch so the app is ready when the first shortcut is pressed.
    /// A denied request is handled later, in context, with a recovery action.
    static func requestOnLaunchIfNeeded() {
        guard !isAuthorized else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    /// Ensures a capture action has permission. When macOS has already denied the request,
    /// present a useful recovery path instead of silently dropping the action.
    @discardableResult
    static func ensureAccess() -> Bool {
        if isAuthorized { return true }

        if CGRequestScreenCaptureAccess() || isAuthorized {
            return true
        }

        presentRecoveryAlert()
        return false
    }

    static func presentRecoveryAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Screen Recording Permission Required")
        alert.informativeText = L10n.string("Ashot needs Screen Recording permission to capture the screen. Enable Ashot in Privacy & Security, then return and try the screenshot again.")
        alert.addButton(withTitle: L10n.string("Open System Settings"))
        alert.addButton(withTitle: L10n.string("Not Now"))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
