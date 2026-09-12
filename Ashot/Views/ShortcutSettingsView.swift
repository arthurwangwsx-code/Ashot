import SwiftUI
import AppKit

enum RecordableShortcut: Equatable {
    case capture(ShortcutAction), editor(EditorShortcutAction)
    var title: String {
        switch self { case .capture(let action): return action.displayName; case .editor(let action): return action.displayName }
    }
    var binding: String? {
        switch self {
        case .capture(let action): return HotKeyManager.shared.bindings[action]?.displayString
        case .editor(let action): return EditorShortcutManager.shared.binding(for: action)
        }
    }
    var registrationFailed: Bool {
        if case .capture(let action) = self { return HotKeyManager.shared.registrationFailures[action] != nil }
        return false
    }
    func clear() {
        switch self { case .capture(let action): HotKeyManager.shared.clearBinding(action); case .editor(let action): EditorShortcutManager.shared.clearBinding(action) }
    }
}

@Observable
final class ShortcutRecordingCoordinator {
    static let shared = ShortcutRecordingCoordinator()
    private(set) var current: RecordableShortcut?
    private(set) var error: String?
    private var monitor: Any?
    private var focusObserver: Any?
    private weak var recordingWindow: NSWindow?

    func start(_ shortcut: RecordableShortcut) {
        cancel()
        guard let window = NSApp.keyWindow else { return }
        recordingWindow = window; current = shortcut; error = nil
        HotKeyManager.shared.unregisterAll()
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.cancel() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.recordingWindow, let target = self.current else { return event }
            if event.keyCode == 53 { self.cancel(); return nil }
            switch target {
            case .capture(let action):
                guard let binding = HotKeyManager.binding(from: event) else { self.error = L10n.string("Use Command, Control, or Option with a key."); return nil }
                if let error = HotKeyManager.shared.validationMessage(for: action, binding: binding) { self.error = error; return nil }
                self.cancel(); HotKeyManager.shared.updateBinding(action, to: binding)
            case .editor(let action):
                guard let key = EditorShortcutManager.normalizedLetter(event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else {
                    self.error = L10n.string("Use one letter from A to Z without modifiers."); return nil
                }
                if let error = EditorShortcutManager.shared.validationMessage(for: action, key: key) { self.error = error; return nil }
                self.cancel(); EditorShortcutManager.shared.updateBinding(action, to: key)
            }
            return nil
        }
    }
    func cancel() {
        let wasRecording = current != nil
        current = nil; error = nil; recordingWindow = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        if wasRecording { HotKeyManager.shared.registerAll() }
    }
}

struct ShortcutSettingsView: View {
    @Bindable private var recording = ShortcutRecordingCoordinator.shared
    var body: some View {
        Form {
            Section("Capture Shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.rawValue) { ShortcutRecordingRow(shortcut: .capture($0)) }
                Text("Click a shortcut, then press the new key combination. Use × to disable it. Esc cancels.").font(.caption).foregroundStyle(.secondary)
                Text("Shortcuts rejected by another app or macOS are marked below. Choose another combination; the menu command remains available.").font(.caption).foregroundStyle(.secondary)
                Button("Reset Capture Shortcuts") { recording.cancel(); HotKeyManager.shared.resetToDefaults() }
            }
            Section("Editor Tool Shortcuts") {
                ForEach(EditorShortcutAction.allCases, id: \.rawValue) { ShortcutRecordingRow(shortcut: .editor($0)) }
                Text("Editor shortcuts use one letter without modifiers and only work in the active editor. Text input is never intercepted.").font(.caption).foregroundStyle(.secondary)
                Button("Reset Editor Shortcuts") { recording.cancel(); EditorShortcutManager.shared.resetToDefaults() }
            }
        }.formStyle(.grouped).onDisappear { recording.cancel() }
    }
}

private struct ShortcutRecordingRow: View {
    let shortcut: RecordableShortcut
    @Bindable private var recording = ShortcutRecordingCoordinator.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(shortcut.title)
                Spacer()
                Button(recording.current == shortcut ? L10n.string("Press keys…") : shortcut.binding ?? L10n.string("Not Set")) {
                    recording.current == shortcut ? recording.cancel() : recording.start(shortcut)
                }
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel(shortcut.title + ": " + (shortcut.binding ?? L10n.string("Not Set")))
                Button {
                    recording.cancel(); shortcut.clear()
                } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).disabled(shortcut.binding == nil).accessibilityLabel(Text("Remove Shortcut"))
            }
            if recording.current == shortcut, let error = recording.error { Text(error).font(.caption).foregroundStyle(.red) }
            if shortcut.registrationFailed { Label("This shortcut could not be registered. Choose another combination.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
