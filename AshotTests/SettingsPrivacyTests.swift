import AppKit
import Carbon.HIToolbox
import Testing
@testable import Ashot

@MainActor
struct SettingsPrivacyTests {
    @Test func diagnosticReportHasAnExplicitNonSensitiveFieldAllowlist() throws {
        let report = DiagnosticReport(applicationVersion: "1.0.0", build: "10", operatingSystem: "26.2.0",
            architecture: "arm64", screenAccess: false, accessibilityAccess: false, connectedDisplayCount: 2,
            persistentHistoryEnabled: false, pendingHistoryOperations: 0, unfinishedEditorCount: 1, failedHotkeyCount: 0)
        let data = try report.encoded()
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["applicationVersion", "build", "operatingSystem", "architecture", "screenAccess",
            "accessibilityAccess", "connectedDisplayCount", "persistentHistoryEnabled", "pendingHistoryOperations", "unfinishedEditorCount", "failedHotkeyCount"])
        #expect(try JSONDecoder().decode(DiagnosticReport.self, from: data) == report)
    }
    @Test func secondPreferenceMigrationPreservesExistingRetentionAndConsent() throws {
        let name = "AshotSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1, forKey: "productPreferencesVersion")
        defaults.set(true, forKey: "existingUserMigration")
        defaults.set(false, forKey: "historyEnabled")
        defaults.set(120, forKey: "historyMaximumCount")
        ProductPreferences.bootstrap(defaults: defaults)
        #expect(defaults.integer(forKey: "historyMaximumCount") == 120)
        #expect(defaults.integer(forKey: "historyMaximumMB") == 0)
        #expect(defaults.integer(forKey: "historyMaximumDays") == 0)
        #expect(!defaults.bool(forKey: "historyEnabled"))
        #expect(!defaults.bool(forKey: "restoreDraftsEnabled"))
    }
    @Test func newDefaultHotkeyDoesNotDisplaceAUsersExistingCustomShortcut() {
        let custom = ShortcutBinding.defaultSensitive
        let result = HotKeyManager.resolvedBindings(saved: [ShortcutAction.captureArea.rawValue: custom], disabledRawValues: [])
        #expect(result[.captureArea] == custom)
        #expect(result[.sensitiveCapture] == nil)
        #expect(Set(result.values.map { "\($0.modifiers):\($0.keyCode)" }).count == result.count)
    }
    @Test func unusableSavedBindingsAndShiftOnlyShortcutsAreNotRegistered() {
        let invalid = ShortcutBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey), displayString: "⇧A")
        #expect(!HotKeyManager.isUsableBinding(invalid))
        let result = HotKeyManager.resolvedBindings(saved: [ShortcutAction.captureArea.rawValue: invalid], disabledRawValues: [])
        #expect(result[.captureArea] == .defaultAreaCapture)
        let clipboardScreenshot = ShortcutBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | controlKey), displayString: "⌃⇧⌘4")
        #expect(HotKeyManager.isReservedSystemScreenshotShortcut(clipboardScreenshot))
    }
}
