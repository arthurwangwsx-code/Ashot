import AppKit

final class PinService {
    static let shared = PinService()
    private var pinnedWindows: [PinnedImageWindow] = []

    private init() {}

    func pinImage(_ image: NSImage) {
        let screenSize = NSScreen.main?.frame.size ?? NSSize(width: 1920, height: 1080)
        let maxWidth = min(image.size.width, screenSize.width * 0.5)
        let scale = image.size.width > 0 ? maxWidth / image.size.width : 1
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let window = PinnedImageWindow(image: image, contentSize: size)
        window.onClose = { [weak self, weak window] in
            guard let window else { return }
            self?.pinnedWindows.removeAll { $0 === window }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pinnedWindows.append(window)
    }

    func closeAll() {
        pinnedWindows.forEach { $0.close() }
        pinnedWindows.removeAll()
    }
}

/// A borderless floating window holding a pinned screenshot. Unlike a plain borderless window
/// it can become key and be dismissed (Esc / ⌘W / the hover close button), so pins are never
/// permanently stuck on screen.
final class PinnedImageWindow: NSWindow {
    var onClose: (() -> Void)?

    init(image: NSImage, contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = PinnedImageView(image: image)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc, or ⌘W
        if event.keyCode == 53 || (event.charactersIgnoringModifiers == "w" && event.modifierFlags.contains(.command)) {
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func close() {
        onClose?()
        onClose = nil
        super.close()
    }
}

private final class PinnedImageView: NSView {
    private let imageView = NSImageView()
    private let closeButton = NSButton()

    init(image: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.isHidden = true
        closeButton.toolTip = "Close pin (Esc)"
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let s: CGFloat = 22
        closeButton.frame = NSRect(x: bounds.maxX - s - 6, y: bounds.maxY - s - 6, width: s, height: s)
    }

    @objc private func closePin() { window?.close() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }
}
