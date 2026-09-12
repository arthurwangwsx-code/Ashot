import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("saveLocation") private var saveLocation: String = "~/Desktop"
    @AppStorage("imageFormat") private var imageFormat: String = "png"
    @AppStorage("showInDock") private var showInDock: Bool = false
    @AppStorage("captureSound") private var captureSound: Bool = true
    @AppStorage("colorFormat") private var colorFormat: String = "HEX"
    @AppStorage("ocrStripLinebreaks") private var ocrStripLinebreaks: Bool = false
    @AppStorage("autoSave") private var autoSave: Bool = false
    @AppStorage("autoCopy") private var autoCopy: Bool = true
    @AppStorage("showPreview") private var showPreview: Bool = true
    @AppStorage("windowShadow") private var windowShadow: Bool = true
    @AppStorage("retinaDownscale") private var retinaDownscale: Bool = false
    @AppStorage("hideDesktopIcons") private var hideDesktopIcons: Bool = false
    @AppStorage("historyFolder") private var historyFolder: String = ""
    @AppStorage("historyFilenameTemplate") private var historyFilenameTemplate: String = "Screenshot_{date}_{time}"
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.system.rawValue

    var body: some View {
        TabView {
            GeneralSettingsView(
                saveLocation: $saveLocation,
                imageFormat: $imageFormat,
                autoSave: $autoSave,
                autoCopy: $autoCopy,
                showPreview: $showPreview,
                captureSound: $captureSound,
                windowShadow: $windowShadow,
                retinaDownscale: $retinaDownscale,
                hideDesktopIcons: $hideDesktopIcons,
                showInDock: $showInDock,
                appLanguage: $appLanguage
            )
            .tabItem { Label("General", systemImage: "gear") }

            HistorySettingsView(
                historyFolder: $historyFolder,
                filenameTemplate: $historyFilenameTemplate
            )
            .tabItem { Label("History", systemImage: "clock") }

            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            ToolSettingsView(
                colorFormat: $colorFormat,
                ocrStripLinebreaks: $ocrStripLinebreaks
            )
            .tabItem { Label("Tools", systemImage: "wrench") }
        }
        .frame(width: 540, height: 400)
        .padding()
        .environment(\.locale, AppLanguage.locale(for: appLanguage))
    }
}

struct GeneralSettingsView: View {
    @Binding var saveLocation: String
    @Binding var imageFormat: String
    @Binding var autoSave: Bool
    @Binding var autoCopy: Bool
    @Binding var showPreview: Bool
    @Binding var captureSound: Bool
    @Binding var windowShadow: Bool
    @Binding var retinaDownscale: Bool
    @Binding var hideDesktopIcons: Bool
    @Binding var showInDock: Bool
    @Binding var appLanguage: String
    @State private var hasScreenCapturePermission = ScreenCapturePermission.isAuthorized

    var body: some View {
        Form {
            Section("Permission") {
                HStack {
                    Label(
                        L10n.string(hasScreenCapturePermission ? "Screen Recording access granted" : "Screen Recording access required"),
                        systemImage: hasScreenCapturePermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(hasScreenCapturePermission ? Color.green : Color.orange)

                    Spacer()

                    if hasScreenCapturePermission {
                        Button("Refresh") { refreshPermission() }
                            .controlSize(.small)
                    } else {
                        Button("Grant Access") {
                            hasScreenCapturePermission = ScreenCapturePermission.ensureAccess()
                        }
                        .controlSize(.small)

                        Button("System Settings") {
                            ScreenCapturePermission.openSystemSettings()
                        }
                        .controlSize(.small)
                    }
                }

                Text("Ashot only captures the screen when you choose a capture command or press one of its shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Save Options") {
                HStack {
                    TextField("Save Location:", text: $saveLocation)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            saveLocation = url.path
                        }
                    }
                    .controlSize(.small)
                }
                Picker("Image Format:", selection: $imageFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                    Text("TIFF").tag("tiff")
                }
            }

            Section("After Capture") {
                Toggle("Show thumbnail preview", isOn: $showPreview)
                Toggle("Automatically copy to clipboard", isOn: $autoCopy)
                Toggle("Automatically save to selected folder", isOn: $autoSave)
                Text("Clipboard copying happens before the preview appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capture") {
                Toggle("Play capture sound", isOn: $captureSound)
                Toggle("Include window shadow", isOn: $windowShadow)
                Toggle("Downscale Retina to 1x", isOn: $retinaDownscale)
                Toggle("Hide desktop icons during capture", isOn: $hideDesktopIcons)
            }

            Section("Appearance") {
                Toggle("Show app icon in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) {
                        NotificationCenter.default.post(name: .ashotDockPreferenceChanged, object: nil)
                    }
                Picker("Language:", selection: $appLanguage) {
                    Text("Follow System").tag(AppLanguage.system.rawValue)
                    Text("Simplified Chinese").tag(AppLanguage.simplifiedChinese.rawValue)
                    Text("English").tag(AppLanguage.english.rawValue)
                }
                .onChange(of: appLanguage) {
                    NotificationCenter.default.post(name: .ashotLanguageChanged, object: nil)
                }
                Text("Language changes take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear(perform: refreshPermission)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermission()
        }
    }

    private func refreshPermission() {
        hasScreenCapturePermission = ScreenCapturePermission.isAuthorized
    }
}

struct ShortcutSettingsView: View {
    @State private var refreshID = UUID()

    var body: some View {
        Form {
            Section("Capture Shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.rawValue) { action in
                    ShortcutRecorderRow(action: action)
                }
            }

            Section {
                HStack {
                    Text("Click a shortcut, then press the new key combination. Use × to disable it. Esc cancels.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reset Capture Shortcuts") {
                        HotKeyManager.shared.resetToDefaults()
                        refreshID = UUID()
                    }
                    .controlSize(.small)
                }
            }

            Section("Editor Tool Shortcuts") {
                ForEach(EditorShortcutAction.allCases, id: \.rawValue) { action in
                    EditorShortcutRecorderRow(action: action)
                }
            }

            Section {
                HStack {
                    Text("Editor shortcuts use one letter without modifiers and only work in the active editor. Text input is never intercepted.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reset Editor Shortcuts") {
                        EditorShortcutManager.shared.resetToDefaults()
                        refreshID = UUID()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .id(refreshID)
    }
}

private struct EditorShortcutRecorderRow: View {
    let action: EditorShortcutAction
    @State private var binding: String?
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var isHovered = false
    @State private var validationMessage: String?

    init(action: EditorShortcutAction) {
        self.action = action
        _binding = State(initialValue: EditorShortcutManager.shared.binding(for: action))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack {
                Text(action.displayName)
                    .font(.system(size: 13))
                Spacer()

                Button(action: toggleRecording) {
                    Text(isRecording ? L10n.string("Press a letter…") : binding ?? L10n.string("Not Set"))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(isRecording ? .accentColor : (binding == nil ? .secondary : .primary.opacity(0.7)))
                        .frame(minWidth: 48)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isRecording ? Color.accentColor.opacity(0.12) : (isHovered ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.05)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isRecording ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: isRecording ? 1 : 0.5)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }

                Button(action: clearBinding) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(binding == nil ? Color.secondary.opacity(0.25) : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(binding == nil)
                .help(L10n.string("Remove Shortcut"))
                .accessibilityLabel(Text("Remove Shortcut"))
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 1)
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func clearBinding() {
        stopRecording()
        validationMessage = nil
        binding = nil
        EditorShortcutManager.shared.clearBinding(action)
    }

    private func startRecording() {
        validationMessage = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            guard let key = EditorShortcutManager.normalizedLetter(
                event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            ) else {
                validationMessage = L10n.string("Use one letter from A to Z without modifiers.")
                return nil
            }

            if let message = EditorShortcutManager.shared.validationMessage(for: action, key: key) {
                validationMessage = message
                return nil
            }

            binding = key
            EditorShortcutManager.shared.updateBinding(action, to: key)
            isRecording = false
            removeMonitor()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private struct ShortcutRecorderRow: View {
    let action: ShortcutAction
    @State private var binding: ShortcutBinding?
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var isHovered = false
    @State private var validationMessage: String?

    init(action: ShortcutAction) {
        self.action = action
        _binding = State(initialValue: HotKeyManager.shared.bindings[action])
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack {
                Text(action.displayName)
                    .font(.system(size: 13))
                Spacer()
                Button(action: toggleRecording) {
                    Text(
                        isRecording
                            ? L10n.string("Press keys…")
                            : binding?.displayString ?? L10n.string("Not Set")
                    )
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(isRecording ? .accentColor : (binding == nil ? .secondary : .primary.opacity(0.7)))
                        .frame(minWidth: 64)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isRecording ? Color.accentColor.opacity(0.12) : (isHovered ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.05)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isRecording ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: isRecording ? 1 : 0.5)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }

                Button(action: clearBinding) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(binding == nil ? Color.secondary.opacity(0.25) : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(binding == nil)
                .help(L10n.string("Remove Shortcut"))
                .accessibilityLabel(Text("Remove Shortcut"))
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 1)
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func clearBinding() {
        if isRecording {
            isRecording = false
            removeMonitor()
        }
        validationMessage = nil
        binding = nil
        HotKeyManager.shared.clearBinding(action)
    }

    private func startRecording() {
        validationMessage = nil
        isRecording = true
        // Suspend live hotkeys so recording a combo doesn't trigger a capture mid-record.
        HotKeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopRecording()
                return nil
            }
            if let newBinding = HotKeyManager.binding(from: event) {
                if let message = HotKeyManager.shared.validationMessage(for: action, binding: newBinding) {
                    validationMessage = message
                    isRecording = false
                    removeMonitor()
                    HotKeyManager.shared.registerAll()
                    return nil
                }
                binding = newBinding
                HotKeyManager.shared.updateBinding(action, to: newBinding) // re-registers all hotkeys
                isRecording = false
                removeMonitor()
            }
            return nil // swallow keys while recording
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        removeMonitor()
        HotKeyManager.shared.registerAll() // restore live hotkeys if recording was cancelled
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct ToolSettingsView: View {
    @Binding var colorFormat: String
    @Binding var ocrStripLinebreaks: Bool

    var body: some View {
        Form {
            Section("Color Picker") {
                Picker("Default Format:", selection: $colorFormat) {
                    ForEach(ColorFormat.allCases, id: \.rawValue) { fmt in
                        Text(fmt.rawValue).tag(fmt.rawValue)
                    }
                }
            }

            Section("OCR") {
                Toggle("Strip linebreaks from recognized text", isOn: $ocrStripLinebreaks)
            }
        }
        .padding()
    }
}

struct HistorySettingsView: View {
    @Binding var historyFolder: String
    @Binding var filenameTemplate: String

    var body: some View {
        Form {
            Section("Storage") {
                HStack {
                    TextField("History Folder:", text: $historyFolder, prompt: Text("Default (Application Support)"))
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            historyFolder = url.path
                        }
                    }
                    .controlSize(.small)
                }
                Text("Leave empty to use ~/Library/Application Support/Ashot/History")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Filename Template") {
                TextField("Template:", text: $filenameTemplate)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Placeholders: {date}, {time}, {source}, {uuid}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Text("Preview:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(previewFilename)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }
                }
            }

            Section("Management") {
                HStack {
                    Label("\(HistoryManager.shared.entries.count) entries", systemImage: "photo.stack")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        if let folder = HistoryManager.shared.storageFolder {
                            NSWorkspace.shared.open(folder)
                        }
                    }) {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .controlSize(.small)
                    Button(role: .destructive, action: { HistoryManager.shared.clear() }) {
                        Label("Clear All", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding()
    }

    private var previewFilename: String {
        var name = filenameTemplate
        name = name.replacingOccurrences(of: "{date}", with: "2024-06-18")
        name = name.replacingOccurrences(of: "{time}", with: "14-30-22")
        name = name.replacingOccurrences(of: "{source}", with: "Area")
        name = name.replacingOccurrences(of: "{uuid}", with: "a1b2c3d4")
        return name + ".png"
    }
}
