import AppKit
import SwiftUI

enum PreviewPlacement {
    static let gap: CGFloat = 12
    static let screenMargin: CGFloat = 12
    static func frame(previewSize: CGSize, anchorRect: CGRect?, visibleFrame: CGRect, cursorLocation: CGPoint) -> CGRect {
        let safe = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let size = CGSize(width: min(previewSize.width, max(1, safe.width)), height: min(previewSize.height, max(1, safe.height)))
        guard let anchor = anchorRect, !anchor.isNull, !anchor.isEmpty, anchor.intersects(visibleFrame),
              area(anchor.intersection(visibleFrame)) / max(1, area(visibleFrame)) < 0.85 else {
            let x = cursorLocation.x + gap + size.width <= safe.maxX ? cursorLocation.x + gap : cursorLocation.x - gap - size.width
            return clamped(CGRect(x: x, y: cursorLocation.y - size.height / 2, width: size.width, height: size.height), to: safe)
        }
        let candidates = [CGRect(x: anchor.maxX + gap, y: anchor.midY - size.height / 2, width: size.width, height: size.height),
                          CGRect(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2, width: size.width, height: size.height),
                          CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height, width: size.width, height: size.height),
                          CGRect(x: anchor.midX - size.width / 2, y: anchor.maxY + gap, width: size.width, height: size.height)]
        if let fitting = candidates.first(where: { safe.contains($0) }) { return fitting }
        return candidates.map { clamped($0, to: safe) }.enumerated().min {
            let left = area($0.element.intersection(anchor)), right = area($1.element.intersection(anchor))
            return left == right ? $0.offset < $1.offset : left < right
        }?.element ?? clamped(candidates[0], to: safe)
    }
    private static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(x: min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width)),
               y: min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height)), width: rect.width, height: rect.height)
    }
    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull || rect.isInfinite ? 0 : rect.width * rect.height }
}

struct PreviewQueue<Payload> {
    private(set) var items: [(payload: Payload, pixels: Int)] = []
    let maximumCount: Int
    let maximumPixels: Int
    var count: Int { items.count }
    mutating func append(_ payload: Payload, pixels: Int) {
        guard pixels > 0, pixels <= maximumPixels, maximumCount > 0 else { return }
        while items.count >= maximumCount || items.reduce(0, { $0 + $1.pixels }) + pixels > maximumPixels {
            guard !items.isEmpty else { break }; items.removeFirst()
        }
        items.append((payload, pixels))
    }
    mutating func popFirst() -> Payload? { items.isEmpty ? nil : items.removeFirst().payload }
    mutating func clear() { items.removeAll() }
    nonisolated static func timeout(_ configured: Double?) -> Double {
        guard let value = configured, value.isFinite, value >= 0, value <= 120 else { return 10 }
        return value
    }
}

struct PreviewItem {
    let id = UUID()
    let image: NSImage
    let anchor: CGRect?
}

@Observable
final class ThumbnailPreviewController {
    static let shared = ThumbnailPreviewController()
    private var window: PreviewWindow?
    private var timer: Timer?
    private var recognition: RecognitionJob?
    private var pending = PreviewQueue<PreviewItem>(maximumCount: 4, maximumPixels: 64_000_000)
    private(set) var current: PreviewItem?
    private(set) var isBusy = false
    private(set) var isRecognizing = false
    private(set) var errorMessage: String?
    private(set) var recognizedText: String?
    private var hovered = false
    private var dragging = false
    var pendingCount: Int { pending.count }

    func show(image: NSImage, anchorRect: CGRect? = nil) {
        let item = PreviewItem(image: image, anchor: anchorRect)
        if current != nil && (isBusy || hovered || dragging || errorMessage != nil || recognizedText != nil) {
            if let raster = CapturedImageSnapshot(image: image)?.cgImage { pending.append(item, pixels: raster.width * raster.height) }
            return
        }
        present(item)
    }
    private func present(_ item: PreviewItem) {
        recognition?.cancel(); recognition = nil
        current = item; errorMessage = nil; recognizedText = nil; isBusy = false; isRecognizing = false
        let cursor = NSEvent.mouseLocation
        let screen = item.anchor.flatMap { anchor in
            NSScreen.screens.filter { $0.frame.intersects(anchor) }.max { a, b in
                a.frame.intersection(anchor).width * a.frame.intersection(anchor).height < b.frame.intersection(anchor).width * b.frame.intersection(anchor).height
            }
        } ?? NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        guard let screen else { return }
        let frame = PreviewPlacement.frame(previewSize: CGSize(width: 330, height: 400), anchorRect: item.anchor,
                                           visibleFrame: screen.visibleFrame, cursorLocation: cursor)
        if window == nil {
            let panel = PreviewWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.onEscape = { [weak self] in self?.advance() }
            panel.contentView = NSHostingView(rootView: LocalizedRoot { PreviewCard(model: self) })
            window = panel
        }
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless() // Never take focus from the app into which the user will paste.
        scheduleDismiss()
    }
    func hover(_ value: Bool) { hovered = value; scheduleDismiss() }
    func dragChanged(_ value: Bool) { dragging = value; scheduleDismiss() }
    private func scheduleDismiss() {
        timer?.invalidate(); timer = nil
        guard !hovered, !dragging, !isBusy, errorMessage == nil, recognizedText == nil else { return }
        let seconds = PreviewQueue<PreviewItem>.timeout(UserDefaults.standard.object(forKey: "previewTimeout") as? Double)
        guard seconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.advance() }
    }
    func advance() {
        guard !isBusy, !dragging else { return }
        if let next = pending.popFirst() { present(next) }
        else { dismiss() }
    }
    func dismiss(immediately: Bool = false) {
        guard !isBusy || immediately else { return }
        recognition?.cancel(); recognition = nil; timer?.invalidate(); timer = nil
        current = nil; recognizedText = nil; errorMessage = nil; pending.clear()
        isBusy = false; isRecognizing = false; hovered = false; dragging = false
        window?.orderOut(nil); window = nil
    }
    func edit() {
        guard let item = current, !isBusy else { return }
        CaptureService.shared.openEditor(with: item.image); advance()
    }
    func copy() {
        guard let item = current, !isBusy else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([item.image]) else { errorMessage = L10n.string("The clipboard could not be updated. Try copying again."); return }
        StatusBarAnimator.shared.flash(type: .copy); UserNotice.show("Copied"); advance()
    }
    func save() {
        guard let item = current, !isBusy, let snapshot = CapturedImageSnapshot(image: item.image) else { return }
        isBusy = true; errorMessage = nil; scheduleDismiss()
        ExportService.chooseDestination { [weak self] selection in
            guard let self, self.current?.id == item.id else { return }
            guard let (url, options) = selection else { self.isBusy = false; self.scheduleDismiss(); return }
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let pixels = try ExportService.prepare(snapshot, options: options)
                        let data = try ExportService.encode(pixels, options: options)
                        try data.write(to: url, options: .atomic)
                    }.value
                    guard self.current?.id == item.id else { return }
                    self.isBusy = false; StatusBarAnimator.shared.flash(type: .save); UserNotice.show("Saved"); self.advance()
                } catch {
                    guard self.current?.id == item.id else { return }
                    self.isBusy = false; self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    func recognize() {
        guard let item = current, !isBusy else { return }
        isBusy = true; isRecognizing = true; errorMessage = nil; recognizedText = nil; scheduleDismiss()
        recognition = OCRService.recognizeText(in: item.image) { [weak self] result in
            guard let self, self.current?.id == item.id, self.isRecognizing else { return }
            self.isBusy = false; self.isRecognizing = false; self.recognition = nil
            switch result {
            case .success(let text): self.recognizedText = text
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }
    func cancelRecognition() {
        recognition?.cancel(); recognition = nil; isRecognizing = false; isBusy = false; scheduleDismiss()
    }
    func copyText() {
        guard let text = recognizedText else { return }
        let output = UserDefaults.standard.bool(forKey: "ocrStripLinebreaks") ? text.replacingOccurrences(of: "\n", with: " ") : text
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
        UserNotice.show("Copied"); recognizedText = nil; advance()
    }
    func pin() { guard let image = current?.image, !isBusy else { return }; PinService.shared.pinImage(image); advance() }
}

private struct PreviewCard: View {
    @Bindable var model: ThumbnailPreviewController
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Screenshot").font(.callout.weight(.medium))
                Spacer()
                if model.pendingCount > 0 {
                    Button("Next (\(model.pendingCount))", action: model.advance).disabled(model.isBusy)
                }
                Button(action: { model.advance() }) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).disabled(model.isBusy).accessibilityLabel(Text("Close preview"))
            }
            if let image = model.current?.image {
                ImageDragView(image: image, onDragChanged: model.dragChanged)
                    .frame(maxWidth: .infinity).frame(height: model.recognizedText == nil ? 210 : 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if model.isBusy {
                HStack { ProgressView().controlSize(.small); Text(model.isRecognizing ? "Recognizing on this Mac…" : "Saving…").font(.caption)
                    if model.isRecognizing { Button("Cancel", action: model.cancelRecognition) }
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let text = model.recognizedText {
                ScrollView { Text(text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 85)
                Button("Copy Text", action: model.copyText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Copy", action: model.copy).buttonStyle(.borderedProminent)
                Button("Edit", action: model.edit)
                Button("Save...", action: model.save)
                Menu {
                    Button("Recognize Text", action: model.recognize)
                    Button("Pin on Screen", action: model.pin)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel(Text("More Actions"))
            }.disabled(model.isBusy).controlSize(.small)
            Text("Drag the image to export a PNG. Recent screenshots remain available from the menu.")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onHover(perform: model.hover)
    }
}

private final class PreviewWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } }
}
