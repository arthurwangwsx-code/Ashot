import AppKit

enum ScreenCapturePermission {
    static var isAuthorized: Bool { PermissionCoordinator.shared.refresh(); return PermissionCoordinator.shared.isAuthorized }
    static func requestOnLaunchIfNeeded() {
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") { WelcomeWindowController.shared.show() }
    }
    @discardableResult
    static func ensureAccess(intent: CaptureIntent = .area) -> Bool { PermissionCoordinator.shared.require(intent) }
    static func presentRecoveryAlert() { WelcomeWindowController.shared.show() }
    static func openSystemSettings() { PermissionCoordinator.shared.openSettingsFromUserGesture() }
}
