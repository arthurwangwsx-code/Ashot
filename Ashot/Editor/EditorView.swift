import SwiftUI
import AppKit

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    @State private var monitor: Any?
    @State private var scope = EditorEventScope()
    @State private var showBeautifier = false

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(viewModel: viewModel)
            if viewModel.document.sensitive {
                Label("Sensitive capture: the original is not copied or saved automatically.", systemImage: "lock.shield")
                    .font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ZStack {
                CanvasView(viewModel: viewModel).frame(maxWidth: .infinity, maxHeight: .infinity)
                if viewModel.showOCRResult { OCRResultOverlay(viewModel: viewModel) }
            }
            Divider()
            HStack(spacing: 12) {
                Text("\(Int(viewModel.canvasSize.width)) × \(Int(viewModel.canvasSize.height)) pt")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Button("Fit") { viewModel.zoomScale = 1; viewModel.panOffset = .zero }
                Text("\(Int(viewModel.zoomScale * 100))%")
                    .font(.system(.caption, design: .monospaced)).accessibilityLabel(Text("Zoom"))
                Spacer(minLength: 4)
                if let icon = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: L10n.string("Drag image to export")) {
                    ImageDragView(image: icon, snapshotProvider: {
                        do { return CapturedImageSnapshot(image: try viewModel.renderFinalImage()) }
                        catch { viewModel.exportError = error.localizedDescription; return nil }
                    }).frame(width: 24, height: 24).help("Drag image to export")
                }
                if viewModel.isExporting { ProgressView().controlSize(.small) }
                if let feedback = viewModel.feedback { Text(feedback).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Menu {
                    Button("Pin", action: viewModel.pinAsFloating)
                    Button("Beautify") { showBeautifier = true }
                    Button("Reset Crop", action: viewModel.resetCrop).disabled(viewModel.cropRect == nil)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 28).accessibilityLabel(Text("Image Actions"))
                Button("Copy", action: viewModel.copyToClipboard).help("Copy image (⌘C)")
                Button("Save") { viewModel.saveToFile() }.buttonStyle(.borderedProminent).help("Save image (⌘S)")
            }
            .controlSize(.small).padding(10).background(.bar).disabled(viewModel.isExporting)
        }
        .background(EditorWindowReader(scope: scope))
        .sheet(isPresented: $showBeautifier) { BackgroundBeautifierView(viewModel: viewModel) }
        .alert("The action could not be completed", isPresented: Binding(get: { viewModel.exportError != nil }, set: { if !$0 { viewModel.exportError = nil } })) {
            Button("OK", role: .cancel) { viewModel.exportError = nil }
        } message: { Text(viewModel.exportError ?? "") }
        .onAppear {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === scope.window, !(scope.window?.firstResponder is NSTextView) else { return event }
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "v":
                        if let image = NSImage(pasteboard: .general) { viewModel.pasteImage(image); return nil }
                    case "c": viewModel.copyToClipboard(); return nil
                    case "s": viewModel.saveToFile(); return nil
                    case "z": event.modifierFlags.contains(.shift) ? viewModel.redo() : viewModel.undo(); return nil
                    case "d": viewModel.duplicateSelected(); return nil
                    case "0": viewModel.zoomScale = 1; viewModel.panOffset = .zero; return nil
                    default: break
                    }
                }
                guard !viewModel.showOCRResult, let action = EditorShortcutManager.shared.action(for: event) else { return event }
                viewModel.selectedTool = action.tool
                return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; viewModel.cancelRecognition() }
    }
}

private final class EditorEventScope { weak var window: NSWindow? }
private struct EditorWindowReader: NSViewRepresentable {
    let scope: EditorEventScope
    func makeNSView(context: Context) -> Reporter {
        let view = Reporter(); view.onChange = { [weak scope] in scope?.window = $0 }; return view
    }
    func updateNSView(_ view: Reporter, context: Context) { scope.window = view.window }
    final class Reporter: NSView {
        var onChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onChange?(window) }
    }
}

struct EditorToolbar: View {
    @Bindable var viewModel: EditorViewModel
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                tool(.select, "arrow.up.left")
                tool(.arrow, "arrow.right")
                tool(.rectangle, "rectangle")
                tool(.text, "textformat")
                tool(.redact, "rectangle.fill")
                tool(.crop, "crop")
                Menu {
                    ForEach([AnnotationTool.line, .oval, .freehand, .counter, .highlight, .blur, .pixelate, .ruler, .ocr], id: \.rawValue) { type in
                        Button(type.displayName) { viewModel.selectedTool = type }
                    }
                    Button("Recognize Text") { viewModel.performOCR() }
                    Button("Recognize QR / Barcode", action: viewModel.performQRDetection)
                    Button("Color Picker") { viewModel.selectedTool = .colorPicker }
                } label: { Label("More Tools", systemImage: "ellipsis") }
                Spacer()
                Button(action: viewModel.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!viewModel.canUndo).help(viewModel.undoTitle + " (⌘Z)").accessibilityLabel(Text("Undo"))
                Button(action: viewModel.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!viewModel.canRedo).help(viewModel.redoTitle + " (⇧⌘Z)").accessibilityLabel(Text("Redo"))
                Button(action: viewModel.deleteSelected) { Image(systemName: "trash") }
                    .disabled(viewModel.selectedAnnotationID == nil).help("Delete selected").accessibilityLabel(Text("Delete selected"))
            }
            .buttonStyle(.borderless)
            HStack(spacing: 12) {
                Text(viewModel.selectedAnnotation == nil ? L10n.string("New Annotation") : L10n.string("Selected Annotation"))
                    .font(.caption).foregroundStyle(.secondary)
                ColorPicker("Color", selection: $viewModel.strokeColor).labelsHidden()
                    .disabled(viewModel.selectedAnnotation?.type == .redact).accessibilityLabel(Text("Annotation Color"))
                Slider(value: $viewModel.strokeWidth, in: 1...20, step: 1, onEditingChanged: { editing in
                    editing ? viewModel.beginTransaction(L10n.string("Change Style")) : viewModel.endTransaction()
                }).frame(width: 100).accessibilityLabel(Text("Stroke Width / Text Size"))
                if viewModel.selectedAnnotation?.type == .text {
                    TextField("Annotation Text", text: Binding(get: { viewModel.selectedAnnotation?.text ?? "" }, set: viewModel.updateSelectedText), onEditingChanged: { editing in
                        editing ? viewModel.beginTransaction(L10n.string("Edit Text")) : viewModel.endTransaction()
                    }).textFieldStyle(.roundedBorder)
                } else if [.redact, .blur, .pixelate].contains(viewModel.selectedTool) {
                    Text(viewModel.selectedTool == .redact ? "Solid redaction exports opaque pixels. Earlier copies may still exist." : "Blur and pixelation are visual effects, not secure erasure.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else { Spacer() }
            }
            .controlSize(.small)
        }
        .padding(10).background(.bar)
    }
    private func tool(_ type: AnnotationTool, _ symbol: String) -> some View {
        Button { viewModel.selectedTool = type } label: {
            Image(systemName: symbol).frame(width: 30, height: 28)
                .background(viewModel.selectedTool == type ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .help(EditorShortcutManager.shared.binding(for: type).map { "\(type.displayName) (\($0))" } ?? type.displayName)
        .accessibilityLabel(type.displayName).accessibilityAddTraits(viewModel.selectedTool == type ? .isSelected : [])
    }
}

struct OCRResultOverlay: View {
    @Bindable var viewModel: EditorViewModel
    @AppStorage("ocrStripLinebreaks") private var strip = false
    @AppStorage("ocrLanguage") private var language = "auto"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.recognitionIsBarcode ? "QR / Barcode Result" : "OCR Result").font(.headline)
                Spacer()
                Button(action: viewModel.closeRecognition) { Image(systemName: "xmark") }.accessibilityLabel(Text("Close"))
            }
            if viewModel.isRecognizing { ProgressView("Recognizing on this Mac…").frame(maxWidth: .infinity) }
            else if let error = viewModel.recognitionError { Text(error).foregroundStyle(.secondary) }
            else {
                ScrollView { Text(displayText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 90, maxHeight: 240)
            }
            if !viewModel.recognitionIsBarcode {
                Picker("Language:", selection: $language) {
                    Text("Automatic").tag("auto"); Text("English").tag("en"); Text("Simplified Chinese").tag("zh-Hans")
                }
                Toggle("Strip linebreaks", isOn: $strip).toggleStyle(.checkbox)
            }
            HStack {
                Button(viewModel.isRecognizing ? "Cancel" : "Recognize Again") {
                    if viewModel.isRecognizing { viewModel.cancelRecognition() }
                    else if viewModel.recognitionIsBarcode { viewModel.performQRDetection() }
                    else { viewModel.performOCR() }
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(displayText, forType: .string)
                    viewModel.feedback = L10n.string("Copied")
                }.disabled(viewModel.isRecognizing || viewModel.ocrText.isEmpty)
            }
            Text("Results stay on this Mac. Links are never opened automatically.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 420).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(20)
    }
    private var displayText: String { strip ? viewModel.ocrText.replacingOccurrences(of: "\n", with: " ") : viewModel.ocrText }
}
