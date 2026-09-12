import AppKit
import SwiftUI

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [UUID: EditorWindowController] = [:]
    let model: EditorViewModel
    private let identifier = UUID()

    static var hasUnsavedDocuments: Bool { windows.values.contains { $0.model.hasUnsavedChanges || $0.model.isExporting } }
    static var activeCount: Int { windows.count }

    init(image: NSImage, sensitive: Bool = false) {
        model = EditorViewModel(image: image, sensitive: sensitive)
        let editor = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(740, min(image.size.width + 80, 1200)),
                                                  height: max(480, min(image.size.height + 180, 850))),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: LocalizedRoot { EditorView(viewModel: editor) })
        window.title = L10n.string("Ashot - Editor"); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 740, height: 450); window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    override func showWindow(_ sender: Any?) {
        Self.windows[identifier] = self
        super.showWindow(sender); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedChanges || model.isExporting else { return true }
        if model.isExporting { NSSound.beep(); return false }
        let alert = NSAlert()
        alert.messageText = L10n.string("Keep your changes?")
        alert.informativeText = L10n.string("This image has changes that have not been copied or saved.")
        alert.addButton(withTitle: L10n.string("Keep Editing"))
        alert.addButton(withTitle: L10n.string("Discard Changes"))
        alert.addButton(withTitle: L10n.string("Save..."))
        switch alert.runModal() {
        case .alertSecondButtonReturn: return true
        case .alertThirdButtonReturn:
            model.saveToFile { [weak self] success in if success, self?.model.hasUnsavedChanges == false { self?.window?.close() } }
            return false
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) {
        model.cancelRecognition(); Self.windows.removeValue(forKey: identifier); AppActivation.apply()
    }
}
