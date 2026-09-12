import SwiftUI
import AppKit

struct EditorView: View {
    let image: NSImage
    @State private var viewModel: EditorViewModel
    @State private var pasteMonitor: Any?
    @State private var eventScope = EditorEventScope()

    init(image: NSImage) {
        self.image = image
        _viewModel = State(wrappedValue: EditorViewModel(image: image))
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(viewModel: viewModel)
            Divider()
            ZStack {
                CanvasView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.showOCRResult {
                    OCRResultOverlay(viewModel: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.spring(duration: 0.25), value: viewModel.showOCRResult)
            Divider()
            EditorBottomBar(viewModel: viewModel)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(EditorWindowReader(scope: eventScope))
        .onAppear {
            guard pasteMonitor == nil else { return }
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === eventScope.window else { return event }

                // A single-letter tool shortcut must never steal text from the field editor or
                // an active IME composition.
                if eventScope.window?.firstResponder is NSTextView {
                    return event
                }

                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "v" {
                    if let image = NSImage(pasteboard: NSPasteboard.general) {
                        viewModel.pasteImage(image)
                        return nil
                    }
                }

                guard !viewModel.showOCRResult,
                      let action = EditorShortcutManager.shared.action(for: event) else {
                    return event
                }
                viewModel.selectedTool = action.tool
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor {
                NSEvent.removeMonitor(pasteMonitor)
                self.pasteMonitor = nil
            }
        }
    }
}

@MainActor
private final class EditorEventScope {
    weak var window: NSWindow?
}

private struct EditorWindowReader: NSViewRepresentable {
    let scope: EditorEventScope

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindowChange = { [weak scope] window in scope?.window = window }
        return view
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onWindowChange = { [weak scope] window in scope?.window = window }
    }

    final class WindowReportingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

struct OCRResultOverlay: View {
    var viewModel: EditorViewModel
    @AppStorage("ocrStripLinebreaks") private var stripLinebreaks: Bool = false

    var displayText: String {
        if stripLinebreaks {
            return viewModel.ocrText.replacingOccurrences(of: "\n", with: " ")
        }
        return viewModel.ocrText
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "text.viewfinder")
                    .foregroundColor(.accentColor)
                Text("OCR Result")
                    .font(.headline)
                Spacer()
                Button(action: { viewModel.showOCRResult = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                Text(displayText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)

            Divider()

            HStack {
                Toggle("Strip linebreaks", isOn: $stripLinebreaks)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Button(action: {
                    let text = stripLinebreaks ? displayText : viewModel.ocrText
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .padding(24)
        .frame(maxWidth: 500)
    }
}

struct EditorToolbar: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 6) {
            ToolButton(icon: "arrow.up.left", tool: .select, viewModel: viewModel)

            ToolDivider()

            HStack(spacing: 4) {
                ToolButton(icon: "arrow.right", tool: .arrow, viewModel: viewModel)
                ToolButton(icon: "line.diagonal", tool: .line, viewModel: viewModel)
                ToolButton(icon: "rectangle", tool: .rectangle, viewModel: viewModel)
                ToolButton(icon: "circle", tool: .oval, viewModel: viewModel)
                ToolButton(icon: "pencil.line", tool: .freehand, viewModel: viewModel)
                ToolButton(icon: "textformat", tool: .text, viewModel: viewModel)
                ToolButton(icon: "number", tool: .counter, viewModel: viewModel)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            ToolDivider()

            HStack(spacing: 4) {
                ToolButton(icon: "eye.slash", tool: .blur, viewModel: viewModel)
                ToolButton(icon: "square.grid.3x3.fill", tool: .pixelate, viewModel: viewModel)
                ToolButton(icon: "highlighter", tool: .highlight, viewModel: viewModel)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            ToolDivider()

            HStack(spacing: 4) {
                ToolButton(icon: "crop", tool: .crop, viewModel: viewModel)
                ToolButton(icon: "ruler", tool: .ruler, viewModel: viewModel)
                ToolButton(icon: "eyedropper", tool: .colorPicker, viewModel: viewModel)
                ToolButton(icon: "text.viewfinder", tool: .ocr, viewModel: viewModel)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            ColorPicker("", selection: $viewModel.strokeColor)
                .labelsHidden()
                .frame(width: 30)

            Slider(value: $viewModel.strokeWidth, in: 1...10, step: 1)
                .frame(width: 80)
                .controlSize(.small)

            ToolDivider()

            HStack(spacing: 4) {
                Button(action: viewModel.undo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.annotations.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
                .opacity(viewModel.annotations.isEmpty ? 0.4 : 1.0)

                Button(action: viewModel.redo) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .opacity(viewModel.redoStack.isEmpty ? 0.4 : 1.0)
            }

            if viewModel.selectedAnnotationID != nil {
                Button(action: viewModel.deleteSelected) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Delete selected")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedAnnotationID != nil)
    }
}

private struct ToolDivider: View {
    var body: some View {
        Divider().frame(height: 20).padding(.horizontal, 2)
    }
}

struct ToolButton: View {
    let icon: String
    let tool: AnnotationTool
    var viewModel: EditorViewModel
    var shortcutManager = EditorShortcutManager.shared
    @State private var isHovered = false

    private var isSelected: Bool { viewModel.selectedTool == tool }

    var body: some View {
        Button(action: { viewModel.selectedTool = tool }) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(shortcutManager.binding(for: tool).map { "\(tool.displayName) (\($0))" } ?? tool.displayName)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

struct EditorBottomBar: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 12) {
            Text("\(Int(viewModel.image.size.width)) × \(Int(viewModel.image.size.height))")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            Divider().frame(height: 16)

            HStack(spacing: 4) {
                Button(action: { viewModel.zoomScale = max(0.25, viewModel.zoomScale / 1.25) }) {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)

                Text("\(Int(viewModel.zoomScale * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40)
                    .foregroundColor(.secondary)

                Button(action: { viewModel.zoomScale = min(5.0, viewModel.zoomScale * 1.25) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.zoomScale = 1.0; viewModel.panOffset = .zero }) {
                    Text("Fit")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: { viewModel.pinAsFloating() }) {
                    Label("Pin", systemImage: "pin")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { openBeautifier() }) {
                    Label("Beautify", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { viewModel.copyToClipboard() }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("c", modifiers: .command)

                Button(action: { viewModel.saveToFile() }) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func openBeautifier() {
        let rendered = viewModel.renderFinalImage()
        let hostingView = NSHostingView(rootView: LocalizedRoot { BackgroundBeautifierView(image: rendered) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = L10n.string("Beautify Screenshot")
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
