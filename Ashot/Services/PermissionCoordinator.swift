import AppKit
import CoreGraphics
import ApplicationServices

enum CaptureIntent: String, Equatable, Sendable { case area, sensitiveArea, fullscreen, window, delayed, scrolling, colorPicker }

@MainActor
protocol ScreenPermissionBackend {
    func check() -> Bool
    func request() -> Bool
    func openSettings() -> Bool
}

struct SystemScreenPermissionBackend: ScreenPermissionBackend {
    func check() -> Bool { CGPreflightScreenCaptureAccess() }
    func request() -> Bool { CGRequestScreenCaptureAccess() }
    func openSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return false }
        return NSWorkspace.shared.open(url)
    }
}

@Observable
final class PermissionCoordinator {
    enum State: Equatable { case needsExplanation, requesting, waitingForSettings, ready }
    static let shared = PermissionCoordinator()
    private let backend: any ScreenPermissionBackend
    private let defaults: UserDefaults
    private let clock: () -> Date
    private var expiresAt: Date?
    private(set) var state: State = .needsExplanation
    private(set) var pending: CaptureIntent?
    var settingsOpenFailed = false
    var performIntent: ((CaptureIntent) -> Void)?
    var showSetup: (() -> Void)?

    init(backend: (any ScreenPermissionBackend)? = nil, defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = Date.init) {
        self.backend = backend ?? SystemScreenPermissionBackend(); self.defaults = defaults; self.clock = clock
        refresh()
    }
    var isAuthorized: Bool { state == .ready }
    func refresh() {
        guard state != .requesting else { return }
        state = backend.check() ? .ready : (defaults.bool(forKey: "screenPermissionRequested") ? .waitingForSettings : .needsExplanation)
        if let expiresAt, clock() > expiresAt { pending = nil; self.expiresAt = nil }
        // Deliberately never execute pending capture as a side effect of activation/rechecking.
    }
    @discardableResult
    func require(_ intent: CaptureIntent) -> Bool {
        refresh()
        if isAuthorized { return true }
        pending = intent; expiresAt = clock().addingTimeInterval(120)
        showSetup?()
        return false
    }
    func requestFromUserGesture() {
        guard state != .requesting, !isAuthorized else { return }
        state = .requesting
        defaults.set(true, forKey: "screenPermissionRequested")
        _ = backend.request()
        state = backend.check() ? .ready : .waitingForSettings
    }
    func openSettingsFromUserGesture() { settingsOpenFailed = !backend.openSettings() }
    func continueFromUserGesture() {
        refresh()
        guard isAuthorized else { return }
        let intent = pending ?? .area
        pending = nil; expiresAt = nil
        performIntent?(intent)
    }
    func cancelPending() { pending = nil; expiresAt = nil }
}

enum AccessibilityPermission {
    static var isAuthorized: Bool { AXIsProcessTrusted() }
    static func requestFromUserGesture() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}
