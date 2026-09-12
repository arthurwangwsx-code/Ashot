import AppKit
import Testing
@testable import Ashot

@MainActor
private final class FakeScreenPermission: ScreenPermissionBackend {
    var granted = false
    var requests = 0
    var settingsOpened = 0
    var settingsResult = true
    func check() -> Bool { granted }
    func request() -> Bool { requests += 1; return granted }
    func openSettings() -> Bool { settingsOpened += 1; return settingsResult }
}

@MainActor
struct PermissionFlowTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "AshotPermissionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
    @Test func captureDoesNotImmediatelyRequestSystemPermission() throws {
        try withDefaults { defaults in
            let backend = FakeScreenPermission()
            let coordinator = PermissionCoordinator(backend: backend, defaults: defaults)
            var setupCount = 0
            coordinator.showSetup = { setupCount += 1 }
            #expect(!coordinator.require(.sensitiveArea)); #expect(setupCount == 1)
            #expect(backend.requests == 0); #expect(coordinator.pending == .sensitiveArea)
        }
    }
    @Test func returningFromSettingsNeverCapturesAndExplicitContinuePreservesIntent() throws {
        try withDefaults { defaults in
            let backend = FakeScreenPermission()
            let coordinator = PermissionCoordinator(backend: backend, defaults: defaults)
            var executed: [CaptureIntent] = []
            coordinator.performIntent = { executed.append($0) }
            #expect(!coordinator.require(.sensitiveArea))
            coordinator.requestFromUserGesture()
            #expect(backend.requests == 1); #expect(coordinator.state == .waitingForSettings)
            backend.granted = true
            coordinator.refresh(); coordinator.refresh()
            #expect(executed.isEmpty); #expect(coordinator.isAuthorized)
            coordinator.continueFromUserGesture()
            #expect(executed == [.sensitiveArea]); #expect(coordinator.pending == nil)
        }
    }
    @Test func permissionAlreadyGrantedDoesNotPresentSetup() throws {
        try withDefaults { defaults in
            let backend = FakeScreenPermission(); backend.granted = true
            let coordinator = PermissionCoordinator(backend: backend, defaults: defaults)
            var setups = 0; coordinator.showSetup = { setups += 1 }
            #expect(coordinator.require(.window)); #expect(setups == 0); #expect(backend.requests == 0)
        }
    }
    @Test func pendingIntentExpiresAndSettingsFailureIsReported() throws {
        try withDefaults { defaults in
            let backend = FakeScreenPermission(); backend.settingsResult = false
            var now = Date(timeIntervalSince1970: 100)
            let coordinator = PermissionCoordinator(backend: backend, defaults: defaults, clock: { now })
            _ = coordinator.require(.delayed)
            now = now.addingTimeInterval(121); coordinator.refresh()
            #expect(coordinator.pending == nil)
            coordinator.openSettingsFromUserGesture(); #expect(coordinator.settingsOpenFailed)
        }
    }
    @Test func newUsersHaveSessionOnlyHistoryButExistingPreferencesArePreserved() throws {
        try withDefaults { defaults in
            ProductPreferences.bootstrap(defaults: defaults, hasExistingHistory: false)
            #expect(!defaults.bool(forKey: "historyEnabled"))
            #expect(defaults.bool(forKey: "confirmAreaSelection"))
            defaults.set(true, forKey: "historyEnabled")
            ProductPreferences.bootstrap(defaults: defaults, hasExistingHistory: false)
            #expect(defaults.bool(forKey: "historyEnabled"))
        }
        try withDefaults { defaults in
            defaults.set(false, forKey: "autoCopy")
            ProductPreferences.bootstrap(defaults: defaults, hasExistingHistory: true)
            #expect(defaults.bool(forKey: "historyEnabled")); #expect(!defaults.bool(forKey: "autoCopy"))
            #expect(!defaults.bool(forKey: "confirmAreaSelection"))
        }
    }
    @Test func sensitivePolicyCannotLeakViaAutoCopySaveHistoryOrPreferenceChanges() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "autoCopy"); defaults.set(true, forKey: "autoSave"); defaults.set(true, forKey: "historyEnabled")
            let policy = CapturePolicy(defaults: defaults, sensitive: true)
            #expect(!policy.autoCopy && !policy.autoSave && !policy.persistentHistory && !policy.preview)
            #expect(policy.directEdit && policy.sensitive)
            defaults.set(false, forKey: "autoCopy")
            #expect(!policy.autoCopy)
            let normal = CapturePolicy(defaults: defaults)
            #expect(normal.autoSave && normal.persistentHistory && !normal.sensitive)
        }
    }
}

@MainActor
struct CaptureProductGeometryTests {
    @Test func windowRectAndPointAgreeOnSecondaryDisplayAbovePrimary() {
        let quartz = CGRect(x: -1400, y: -900, width: 500, height: 400)
        let appKit = ScreenCoordinates.appKitRect(fromQuartz: quartz, primaryTop: 1080)
        #expect(appKit == CGRect(x: -1400, y: 1580, width: 500, height: 400))
        let point = ScreenCoordinates.quartzPoint(fromAppKit: CGPoint(x: appKit.midX, y: appKit.midY), primaryTop: 1080)
        #expect(quartz.contains(point))
    }
    @Test func repeatTargetFingerprintDetectsScaleResolutionAndPhysicalDisplayChanges() {
        let base = CaptureDisplaySnapshot(id: 2, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), backingScale: 2, serial: 10)
        #expect(base != CaptureDisplaySnapshot(id: 2, frame: base.frame, backingScale: 1, serial: 10))
        #expect(base != CaptureDisplaySnapshot(id: 2, frame: base.frame, backingScale: 2, serial: 11))
        #expect(base != CaptureDisplaySnapshot(id: 3, frame: base.frame, backingScale: 2, serial: 10))
    }
    @Test func desktopFilteringNeverRemovesRegularFinderWindows() {
        #expect(CaptureGeometry.excludesWindow(owner: "com.apple.finder", layer: -100, ownBundle: "Ashot", hideDesktopIcons: true))
        #expect(!CaptureGeometry.excludesWindow(owner: "com.apple.finder", layer: 0, ownBundle: "Ashot", hideDesktopIcons: true))
        #expect(!CaptureGeometry.excludesWindow(owner: "com.apple.finder", layer: -100, ownBundle: "Ashot", hideDesktopIcons: false))
        #expect(CaptureGeometry.excludesWindow(owner: "Ashot", layer: 0, ownBundle: "Ashot", hideDesktopIcons: false))
    }
    @Test func installationGuidanceRecognizesDMGTranslocationAndDownloads() {
        #expect(InstallationLocation.needsRelocation(path: "/Volumes/Ashot/Ashot.app", writable: true))
        #expect(InstallationLocation.needsRelocation(path: "/Users/example/Downloads/Ashot.app", writable: true))
        #expect(InstallationLocation.needsRelocation(path: "/private/var/folders/id/AppTranslocation/abc/Ashot.app", writable: false))
        #expect(!InstallationLocation.needsRelocation(path: "/Applications/Ashot.app", writable: true))
    }
    @Test func sensitiveCapturesAreNotAddedToRecentMemoryList() throws {
        let store = RecentCaptureStore()
        let image = try ProductTestImage.make()
        #expect(store.add(image: image, source: "Area", sensitive: true) == nil)
        #expect(store.items.isEmpty)
        for _ in 0..<15 { store.add(image: image, source: "Area") }
        #expect(store.items.count == RecentCaptureStore.maximumItems)
        store.clear(); #expect(store.items.isEmpty)
    }
}
