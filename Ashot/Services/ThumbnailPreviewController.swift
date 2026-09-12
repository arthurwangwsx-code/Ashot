import AppKit

enum PreviewPlacement {
    static let gap: CGFloat = 12
    static let screenMargin: CGFloat = 12

    /// Places the preview beside captured content whenever the current screen has room. Candidate
    /// order is right, left, below, then above. If no side fits completely, use the candidate with
    /// the least overlap; a near-fullscreen capture falls back to the user's cursor position.
    static func frame(
        previewSize: CGSize,
        anchorRect: CGRect?,
        visibleFrame: CGRect,
        cursorLocation: CGPoint
    ) -> CGRect {
        let safeFrame = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)

        guard let anchorRect,
              !anchorRect.isNull,
              !anchorRect.isEmpty,
              anchorRect.intersects(visibleFrame),
              coverage(of: visibleFrame, by: anchorRect) < 0.85 else {
            return cursorFrame(previewSize: previewSize, cursor: cursorLocation, safeFrame: safeFrame)
        }

        let candidates = [
            CGRect(
                x: anchorRect.maxX + gap,
                y: anchorRect.midY - previewSize.height / 2,
                width: previewSize.width,
                height: previewSize.height
            ),
            CGRect(
                x: anchorRect.minX - gap - previewSize.width,
                y: anchorRect.midY - previewSize.height / 2,
                width: previewSize.width,
                height: previewSize.height
            ),
            CGRect(
                x: anchorRect.midX - previewSize.width / 2,
                y: anchorRect.minY - gap - previewSize.height,
                width: previewSize.width,
                height: previewSize.height
            ),
            CGRect(
                x: anchorRect.midX - previewSize.width / 2,
                y: anchorRect.maxY + gap,
                width: previewSize.width,
                height: previewSize.height
            )
        ]

        if let fitting = candidates.first(where: { safeFrame.contains($0) }) {
            return fitting
        }

        return candidates
            .map { clamped($0, to: safeFrame) }
            .enumerated()
            .min { lhs, rhs in
                let lhsOverlap = overlapArea(lhs.element, anchorRect)
                let rhsOverlap = overlapArea(rhs.element, anchorRect)
                if lhsOverlap == rhsOverlap { return lhs.offset < rhs.offset }
                return lhsOverlap < rhsOverlap
            }?
            .element
            ?? cursorFrame(previewSize: previewSize, cursor: cursorLocation, safeFrame: safeFrame)
    }

    private static func cursorFrame(
        previewSize: CGSize,
        cursor: CGPoint,
        safeFrame: CGRect
    ) -> CGRect {
        let preferredX = cursor.x + gap
        let x = preferredX + previewSize.width <= safeFrame.maxX
            ? preferredX
            : cursor.x - gap - previewSize.width
        let frame = CGRect(
            x: x,
            y: cursor.y - previewSize.height / 2,
            width: previewSize.width,
            height: previewSize.height
        )
        return clamped(frame, to: safeFrame)
    }

    private static func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let maxX = max(bounds.minX, bounds.maxX - frame.width)
        let maxY = max(bounds.minY, bounds.maxY - frame.height)
        return CGRect(
            x: min(max(frame.minX, bounds.minX), maxX),
            y: min(max(frame.minY, bounds.minY), maxY),
            width: frame.width,
            height: frame.height
        )
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func coverage(of visibleFrame: CGRect, by anchorRect: CGRect) -> CGFloat {
        let visibleArea = visibleFrame.width * visibleFrame.height
        guard visibleArea > 0 else { return 1 }
        return overlapArea(visibleFrame, anchorRect) / visibleArea
    }
}

/// Lightweight post-capture chooser. It intentionally stays separate from the editor: the user
/// can take a screenshot, make one quick decision, and get back to their work.
final class ThumbnailPreviewController: NSObject {
    static let shared = ThumbnailPreviewController()

    private var previewWindow: PreviewWindow?
    private var capturedImage: NSImage?
    private var dismissTimer: Timer?
    private var isHovered = false

    private override init() {}

    func show(image: NSImage, anchorRect: CGRect? = nil) {
        dismiss(immediately: true)
        capturedImage = image

        let cursorLocation = NSEvent.mouseLocation
        let screen = targetScreen(for: anchorRect, cursorLocation: cursorLocation)
        guard let screen else { return }

        let width: CGFloat = 284
        let horizontalPadding: CGFloat = 14
        let headerHeight: CGFloat = 34
        let actionHeight: CGFloat = 54
        let imageWidth = width - horizontalPadding * 2
        let aspectRatio = image.size.width > 0 ? image.size.height / image.size.width : 1
        let imageHeight = min(max(imageWidth * aspectRatio, 110), 230)
        let height = headerHeight + imageHeight + actionHeight + 12

        let frame = PreviewPlacement.frame(
            previewSize: CGSize(width: width, height: height),
            anchorRect: anchorRect,
            visibleFrame: screen.visibleFrame,
            cursorLocation: cursorLocation
        )

        let window = PreviewWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.alphaValue = 0
        window.onEscape = { [weak self] in self?.dismiss() }

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        container.layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        let closeButton = makeIconButton(
            symbol: "xmark",
            accessibilityLabel: L10n.string("Close preview"),
            toolTip: L10n.string("Close"),
            action: #selector(closeAction)
        )
        closeButton.frame = NSRect(x: 10, y: height - headerHeight + 4, width: 28, height: 26)
        container.addSubview(closeButton)

        let dragHandle = NSTextField(labelWithString: "••••••")
        dragHandle.alignment = .center
        dragHandle.font = .systemFont(ofSize: 11, weight: .medium)
        dragHandle.textColor = .tertiaryLabelColor
        dragHandle.frame = NSRect(x: width / 2 - 34, y: height - headerHeight + 8, width: 68, height: 18)
        dragHandle.toolTip = L10n.string("Drag to move")
        container.addSubview(dragHandle)

        let imageView = NSImageView(frame: NSRect(
            x: horizontalPadding,
            y: actionHeight,
            width: imageWidth,
            height: imageHeight
        ))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        imageView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        imageView.layer?.borderWidth = 0.5
        container.addSubview(imageView)

        let actionStack = NSStackView(frame: NSRect(x: 22, y: 9, width: width - 44, height: 36))
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.distribution = .equalSpacing

        actionStack.addArrangedSubview(makeIconButton(symbol: "pencil", accessibilityLabel: L10n.string("Edit screenshot"), toolTip: L10n.string("Edit"), action: #selector(editAction)))
        actionStack.addArrangedSubview(makeIconButton(symbol: "doc.on.doc", accessibilityLabel: L10n.string("Copy screenshot"), toolTip: L10n.string("Copy"), action: #selector(copyAction)))
        actionStack.addArrangedSubview(makeIconButton(symbol: "square.and.arrow.down", accessibilityLabel: L10n.string("Save screenshot"), toolTip: L10n.string("Save"), action: #selector(saveAction)))
        actionStack.addArrangedSubview(makeIconButton(symbol: "text.viewfinder", accessibilityLabel: L10n.string("Recognize text"), toolTip: L10n.string("Recognize Text (OCR)"), action: #selector(ocrAction)))
        actionStack.addArrangedSubview(makeIconButton(symbol: "pin", accessibilityLabel: L10n.string("Pin screenshot"), toolTip: L10n.string("Pin on Screen"), action: #selector(pinAction)))
        container.addSubview(actionStack)

        let tracking = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        container.addTrackingArea(tracking)

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        previewWindow = window

        container.layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            container.layer?.transform = CATransform3DIdentity
        }

        scheduleDismiss()
    }

    private func targetScreen(for anchorRect: CGRect?, cursorLocation: CGPoint) -> NSScreen? {
        if let anchorRect {
            let ranked = NSScreen.screens.map { screen in
                let intersection = screen.frame.intersection(anchorRect)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return (screen, area)
            }
            if let match = ranked.max(by: { $0.1 < $1.1 }), match.1 > 0 {
                return match.0
            }
        }

        return NSScreen.screens.first { $0.frame.contains(cursorLocation) } ?? NSScreen.main
    }

    private func makeIconButton(
        symbol: String,
        accessibilityLabel: String,
        toolTip: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self, !self.isHovered else { return }
            self.dismiss()
        }
    }

    @objc func mouseEntered(with event: NSEvent) {
        isHovered = true
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    @objc func mouseExited(with event: NSEvent) {
        isHovered = false
        scheduleDismiss()
    }

    @objc private func closeAction() {
        dismiss()
    }

    @objc private func editAction() {
        guard let image = capturedImage else { return }
        dismiss()
        CaptureService.shared.openEditor(with: image)
    }

    @objc private func copyAction() {
        guard let image = capturedImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        StatusBarAnimator.shared.flash(type: .copy)
        dismiss()
    }

    @objc private func saveAction() {
        guard let image = capturedImage else { return }
        do {
            _ = try CaptureService.shared.saveImageToConfiguredLocation(image)
            StatusBarAnimator.shared.flash(type: .save)
            dismiss()
        } catch {
            presentError(title: L10n.string("Couldn’t Save Screenshot"), error: error)
        }
    }

    @objc private func ocrAction() {
        guard let image = capturedImage else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil

        OCRService.recognizeText(in: image) { [weak self] result in
            switch result {
            case .success(let text):
                let stripLinebreaks = UserDefaults.standard.bool(forKey: "ocrStripLinebreaks")
                let output = stripLinebreaks ? text.replacingOccurrences(of: "\n", with: " ") : text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
                StatusBarAnimator.shared.flash(type: .copy)
                self?.dismiss()
            case .failure(let error):
                self?.presentError(title: L10n.string("Text Recognition Failed"), error: error)
                self?.scheduleDismiss()
            }
        }
    }

    @objc private func pinAction() {
        guard let image = capturedImage else { return }
        PinService.shared.pinImage(image)
        dismiss()
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.string("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func dismiss(immediately: Bool = false) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        isHovered = false
        capturedImage = nil

        guard let window = previewWindow else { return }
        previewWindow = nil

        if immediately {
            window.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.contentView?.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
        }, completionHandler: {
            window.orderOut(nil)
        })
    }
}

private final class PreviewWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}
