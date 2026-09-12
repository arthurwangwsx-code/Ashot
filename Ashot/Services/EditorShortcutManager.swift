import AppKit
import Observation

enum EditorShortcutAction: String, CaseIterable, Codable {
    case select
    case arrow
    case line
    case rectangle
    case oval
    case freehand
    case text
    case counter
    case blur
    case pixelate
    case highlight
    case crop
    case ruler
    case colorPicker
    case ocr

    var tool: AnnotationTool {
        switch self {
        case .select: return .select
        case .arrow: return .arrow
        case .line: return .line
        case .rectangle: return .rectangle
        case .oval: return .oval
        case .freehand: return .freehand
        case .text: return .text
        case .counter: return .counter
        case .blur: return .blur
        case .pixelate: return .pixelate
        case .highlight: return .highlight
        case .crop: return .crop
        case .ruler: return .ruler
        case .colorPicker: return .colorPicker
        case .ocr: return .ocr
        }
    }

    var displayName: String { tool.displayName }

    nonisolated var defaultKey: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .line: return "L"
        case .rectangle: return "R"
        case .oval: return "O"
        case .freehand: return "P"
        case .text: return "T"
        case .counter: return "N"
        case .blur: return "B"
        case .pixelate: return "M"
        case .highlight: return "H"
        case .crop: return "C"
        case .ruler: return "U"
        case .colorPicker: return "I"
        case .ocr: return "E"
        }
    }
}

/// Editor shortcuts are local, single-letter tool selectors. They intentionally stay separate
/// from Carbon global capture hotkeys: no modifier is required and they only run in the active
/// editor window.
@MainActor
@Observable
final class EditorShortcutManager {
    static let shared = EditorShortcutManager()

    private static let bindingsKey = "editorShortcutBindings"
    private static let disabledActionsKey = "disabledEditorShortcutActions"

    private(set) var bindings: [EditorShortcutAction: String]
    private(set) var disabledActions: Set<EditorShortcutAction>

    private init() {
        let disabledRawValues = Set(
            UserDefaults.standard.stringArray(forKey: Self.disabledActionsKey) ?? []
        )
        disabledActions = Set(disabledRawValues.compactMap(EditorShortcutAction.init(rawValue:)))

        var saved: [String: String] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.bindingsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            saved = decoded
        }
        bindings = Self.resolvedBindings(saved: saved, disabledRawValues: disabledRawValues)
    }

    nonisolated static func resolvedBindings(
        saved: [String: String],
        disabledRawValues: Set<String>
    ) -> [EditorShortcutAction: String] {
        var result: [EditorShortcutAction: String] = [:]
        var usedKeys: Set<String> = []

        for action in EditorShortcutAction.allCases where !disabledRawValues.contains(action.rawValue) {
            let savedKey = saved[action.rawValue].flatMap { normalizedLetter($0, modifiers: []) }
            let candidates = [savedKey, action.defaultKey].compactMap { $0 }
            guard let key = candidates.first(where: { !usedKeys.contains($0) }) else { continue }
            result[action] = key
            usedKeys.insert(key)
        }
        return result
    }

    nonisolated static func normalizedLetter(
        _ characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        guard modifiers.intersection(disallowed).isEmpty,
              let characters,
              characters.count == 1,
              let scalar = characters.uppercased().unicodeScalars.first,
              scalar.value >= 65,
              scalar.value <= 90 else {
            return nil
        }
        return String(Character(scalar))
    }

    func binding(for action: EditorShortcutAction) -> String? {
        bindings[action]
    }

    func binding(for tool: AnnotationTool) -> String? {
        guard let action = EditorShortcutAction.allCases.first(where: { $0.tool == tool }) else {
            return nil
        }
        return bindings[action]
    }

    func action(for event: NSEvent) -> EditorShortcutAction? {
        guard let key = Self.normalizedLetter(
            event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags
        ) else { return nil }
        return bindings.first(where: { $0.value == key })?.key
    }

    func validationMessage(for action: EditorShortcutAction, key: String) -> String? {
        if let conflict = bindings.first(where: { $0.key != action && $0.value == key })?.key {
            return L10n.string("Already used by %@.", conflict.displayName)
        }
        return nil
    }

    func updateBinding(_ action: EditorShortcutAction, to key: String) {
        guard let normalized = Self.normalizedLetter(key, modifiers: []) else { return }
        disabledActions.remove(action)
        bindings[action] = normalized
        save()
    }

    func clearBinding(_ action: EditorShortcutAction) {
        bindings[action] = nil
        disabledActions.insert(action)
        save()
    }

    func resetToDefaults() {
        disabledActions.removeAll()
        bindings = Dictionary(
            uniqueKeysWithValues: EditorShortcutAction.allCases.map { ($0, $0.defaultKey) }
        )
        save()
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: Self.bindingsKey)
        }
        UserDefaults.standard.set(
            disabledActions.map(\.rawValue).sorted(),
            forKey: Self.disabledActionsKey
        )
    }
}
