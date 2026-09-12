import AppKit
import SwiftUI

final class EditorWindowController: NSWindowController {
    private let capturedImage: NSImage

    init(image: NSImage) {
        self.capturedImage = image

        let editorView = NSHostingView(rootView: LocalizedRoot { EditorView(image: image) })
        let contentRect = NSRect(x: 0, y: 0, width: min(image.size.width + 80, 1200), height: min(image.size.height + 140, 800))

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Ashot - Editor")
        window.contentView = editorView
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension EditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AppActivation.apply()
    }
}
