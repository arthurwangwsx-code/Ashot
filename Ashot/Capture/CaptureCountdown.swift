import AppKit
import SwiftUI

@Observable
final class CaptureCountdown {
    private(set) var remaining = 0
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    private var monitor: Any?
    private var completion: (() -> Void)?
    private var cancellation: (() -> Void)?
    func start(seconds: Int, screen: NSScreen?, completion: @escaping () -> Void, cancelled: @escaping () -> Void) {
        cancel()
        remaining = max(1, min(30, seconds)); self.completion = completion; cancellation = cancelled
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 310, height: 105),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.string("Timed Screenshot"); panel.level = .floating; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: LocalizedRoot {
            HStack(spacing: 20) {
                Text("\(self.remaining)").font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                VStack(alignment: .leading) {
                    Text("Prepare your screen")
                    Button("Cancel") { self.cancel() }.keyboardShortcut(.cancelAction)
                }
            }.padding(18)
        })
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: frame.midX - 155, y: frame.maxY - 165)) }
        self.panel = panel; panel.orderFrontRegardless()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }; return event
        }
        task = Task { [weak self] in
            guard let self else { return }
            while self.remaining > 0 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled else { return }; self.remaining -= 1
            }
            let callback = self.completion; self.completion = nil; self.cancellation = nil
            self.dismiss(); callback?()
        }
    }
    func cancel() {
        task?.cancel(); task = nil; completion = nil
        let callback = cancellation; cancellation = nil
        dismiss(); callback?()
    }
    private func dismiss() {
        panel?.orderOut(nil); panel = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
