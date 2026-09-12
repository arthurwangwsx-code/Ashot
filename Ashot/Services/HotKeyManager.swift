import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let ashotShortcutsChanged = Notification.Name("ashotShortcutsChanged")
}

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayString: String

    // NOTE: ⌘⇧3/4/5/6 are reserved by macOS for the system screenshot feature, so a
    // Carbon hotkey registered there is shadowed by the OS and never fires. Defaults below
    // deliberately avoid those combinations.
    static let defaultAreaCapture = ShortcutBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧2")
    static let defaultFullscreen = ShortcutBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧1")
    static let defaultWindow = ShortcutBinding(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧7")
    static let defaultDelayed = ShortcutBinding(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧8")
    static let defaultScrolling = ShortcutBinding(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧9")
    static let defaultRepeat = ShortcutBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧R")
    static let defaultColorPicker = ShortcutBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧C")
}

enum ShortcutAction: String, CaseIterable, Codable {
    case captureArea = "captureArea"
    case captureFullscreen = "captureFullscreen"
    case captureWindow = "captureWindow"
    case captureDelayed = "captureDelayed"
    case captureScrolling = "captureScrolling"
    case repeatLast = "repeatLast"
    case colorPicker = "colorPicker"

    var displayName: String {
        switch self {
        case .captureArea: return L10n.string("Capture Area")
        case .captureFullscreen: return L10n.string("Capture Fullscreen")
        case .captureWindow: return L10n.string("Capture Window")
        case .captureDelayed: return L10n.string("Capture with Delay")
        case .captureScrolling: return L10n.string("Scrolling Capture")
        case .repeatLast: return L10n.string("Repeat Last Capture")
        case .colorPicker: return L10n.string("Color Picker")
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .captureArea: return .defaultAreaCapture
        case .captureFullscreen: return .defaultFullscreen
        case .captureWindow: return .defaultWindow
        case .captureDelayed: return .defaultDelayed
        case .captureScrolling: return .defaultScrolling
        case .repeatLast: return .defaultRepeat
        case .colorPicker: return .defaultColorPicker
        }
    }
}

final class HotKeyManager {
    static let shared = HotKeyManager()
    private static let bindingsKey = "shortcutBindings"
    private static let disabledActionsKey = "disabledShortcutActions"
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private let hotKeySignature = OSType(0x41534854) // "ASHT"

    private(set) var bindings: [ShortcutAction: ShortcutBinding]
    private(set) var disabledActions: Set<ShortcutAction>

    private init() {
        let disabledRawValues = Set(UserDefaults.standard.stringArray(forKey: Self.disabledActionsKey) ?? [])
        disabledActions = Set(disabledRawValues.compactMap(ShortcutAction.init(rawValue:)))

        var saved: [String: ShortcutBinding] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.bindingsKey),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            saved = decoded
        }
        bindings = Self.resolvedBindings(saved: saved, disabledRawValues: disabledRawValues)
    }

    static func resolvedBindings(
        saved: [String: ShortcutBinding],
        disabledRawValues: Set<String>
    ) -> [ShortcutAction: ShortcutBinding] {
        var result: [ShortcutAction: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases where !disabledRawValues.contains(action.rawValue) {
            result[action] = saved[action.rawValue] ?? action.defaultBinding
        }
        return result
    }

    func saveBindings() {
        var encoded: [String: ShortcutBinding] = [:]
        for (action, binding) in bindings {
            encoded[action.rawValue] = binding
        }
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: Self.bindingsKey)
        }
        UserDefaults.standard.set(
            disabledActions.map(\.rawValue).sorted(),
            forKey: Self.disabledActionsKey
        )
    }

    func registerAll() {
        unregisterAll()
        installHandlerIfNeeded()

        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let binding = bindings[action] else { continue }
            let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: UInt32(index + 1))
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
            if status != noErr {
                NSLog("Ashot: failed to register hotkey \(binding.displayString) for \(action.displayName) (status \(status)) — it may be in use by another app or the system.")
            }
            hotKeyRefs.append(hotKeyRef)
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

            let index = Int(hotKeyID.id) - 1
            DispatchQueue.main.async {
                let actions = ShortcutAction.allCases
                guard index >= 0, index < actions.count else { return }
                HotKeyManager.shared.executeAction(actions[index])
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &handlerRef)
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
    }

    /// Updates a single binding, persists it, re-registers all hotkeys and notifies observers (e.g. the menu bar).
    func updateBinding(_ action: ShortcutAction, to binding: ShortcutBinding) {
        disabledActions.remove(action)
        bindings[action] = binding
        saveBindings()
        registerAll()
        NotificationCenter.default.post(name: .ashotShortcutsChanged, object: nil)
    }

    /// Removes and persistently disables one global shortcut without removing its menu command.
    func clearBinding(_ action: ShortcutAction) {
        bindings[action] = nil
        disabledActions.insert(action)
        saveBindings()
        registerAll()
        NotificationCenter.default.post(name: .ashotShortcutsChanged, object: nil)
    }

    func resetToDefaults() {
        disabledActions.removeAll()
        for action in ShortcutAction.allCases {
            bindings[action] = action.defaultBinding
        }
        saveBindings()
        registerAll()
        NotificationCenter.default.post(name: .ashotShortcutsChanged, object: nil)
    }

    func validationMessage(for action: ShortcutAction, binding: ShortcutBinding) -> String? {
        if Self.isReservedSystemScreenshotShortcut(binding) {
            return L10n.string("That shortcut is reserved by macOS. Choose another combination.")
        }

        if let conflict = bindings.first(where: {
            $0.key != action && $0.value.keyCode == binding.keyCode && $0.value.modifiers == binding.modifiers
        })?.key {
            return L10n.string("Already used by %@.", conflict.displayName)
        }

        return nil
    }

    static func isReservedSystemScreenshotShortcut(_ binding: ShortcutBinding) -> Bool {
        let screenshotModifiers = UInt32(cmdKey | shiftKey)
        guard binding.modifiers == screenshotModifiers else { return false }
        let reservedKeys: Set<UInt32> = [
            UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4),
            UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6)
        ]
        return reservedKeys.contains(binding.keyCode)
    }

    func executeAction(_ action: ShortcutAction) {
        switch action {
        case .captureArea: CaptureService.shared.startAreaCapture()
        case .captureFullscreen: CaptureService.shared.captureFullscreen()
        case .captureWindow: CaptureService.shared.captureWindow()
        case .captureDelayed: CaptureService.shared.captureWithDelay(seconds: 3)
        case .captureScrolling: ScrollingCaptureService.shared.startScrollingCapture()
        case .repeatLast: CaptureService.shared.repeatLastCapture()
        case .colorPicker: ColorPickerService.shared.start()
        }
    }

    static func modifierString(from modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    static func keyString(from keyCode: UInt32) -> String {
        let keyMap: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
            UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Grave): "`",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        return keyMap[keyCode] ?? "?"
    }

    /// Converts AppKit modifier flags to the Carbon modifier mask used by RegisterEventHotKey.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Builds a binding from a recorded key event, or nil if it isn't a usable shortcut
    /// (no modifier, or a lone modifier key press).
    static func binding(from event: NSEvent) -> ShortcutBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = carbonModifiers(from: flags)
        guard modifiers != 0 else { return nil }

        let keyCode = UInt32(event.keyCode)
        let key = keyString(from: keyCode)
        guard key != "?" else { return nil }
        let display = modifierString(from: modifiers) + key
        return ShortcutBinding(keyCode: keyCode, modifiers: modifiers, displayString: display)
    }
}
