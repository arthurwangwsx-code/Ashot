import AppKit

enum StatusBarFlashType {
    case capture, copy, save
}

final class StatusBarAnimator {
    static let shared = StatusBarAnimator()
    weak var statusItem: NSStatusItem?

    private init() {}

    func flash(type: StatusBarFlashType) {
        guard let button = statusItem?.button else { return }

        let originalImage = button.image
        let feedbackImage: NSImage?

        switch type {
        case .capture:
            feedbackImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Captured")
        case .copy:
            feedbackImage = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "Copied")
        case .save:
            feedbackImage = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Saved")
        }

        feedbackImage?.size = NSSize(width: 18, height: 18)
        button.image = feedbackImage

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                button.animator().alphaValue = 0.5
            }, completionHandler: {
                button.image = originalImage
                button.image?.size = NSSize(width: 18, height: 18)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    button.animator().alphaValue = 1.0
                }
            })
        }
    }
}
