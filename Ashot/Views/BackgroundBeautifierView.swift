import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BackgroundBeautifierView: View {
    let image: NSImage
    @State private var selectedBackground: BackgroundStyle = .gradient1
    @State private var padding: CGFloat = 40
    @State private var cornerRadius: CGFloat = 12
    @State private var shadow: Bool = true
    @State private var scale: CGFloat = 0.85

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            Divider()
            controlsArea
        }
        .frame(minWidth: 650, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundColor(.accentColor)
                .font(.system(size: 14, weight: .semibold))
            Text("Beautify")
                .font(.headline)
            Spacer()
            Button(action: copyResult) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: saveResult) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var previewArea: some View {
        GeometryReader { geo in
            let rendered = renderPreview(in: geo.size)
            Image(nsImage: rendered)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.25), value: selectedBackground)
        .animation(.easeInOut(duration: 0.25), value: padding)
        .animation(.easeInOut(duration: 0.25), value: cornerRadius)
        .animation(.easeInOut(duration: 0.25), value: shadow)
    }

    private var controlsArea: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Background")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(BackgroundStyle.allCases, id: \.self) { style in
                        BackgroundStyleButton(style: style, isSelected: selectedBackground == style) {
                            withAnimation(.spring(duration: 0.25)) { selectedBackground = style }
                        }
                    }
                }
            }

            Divider().frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text("Padding")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Slider(value: $padding, in: 10...100)
                        .frame(width: 90)
                        .controlSize(.small)
                    Text("\(Int(padding))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Radius")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Slider(value: $cornerRadius, in: 0...30)
                        .frame(width: 90)
                        .controlSize(.small)
                    Text("\(Int(cornerRadius))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                }
            }

            Divider().frame(height: 36)

            Toggle(isOn: $shadow) {
                Label("Shadow", systemImage: shadow ? "shadow" : "square")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func renderPreview(in size: CGSize) -> NSImage {
        let imgSize = image.size
        let canvasWidth = imgSize.width + padding * 2
        let canvasHeight = imgSize.height + padding * 2

        let canvas = NSImage(size: NSSize(width: canvasWidth, height: canvasHeight))
        canvas.lockFocus()

        selectedBackground.drawBackground(in: NSRect(origin: .zero, size: NSSize(width: canvasWidth, height: canvasHeight)))

        let imgRect = NSRect(x: padding, y: padding, width: imgSize.width, height: imgSize.height)

        if shadow {
            let shadowContext = NSGraphicsContext.current?.cgContext
            shadowContext?.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        }

        let clipPath = NSBezierPath(roundedRect: imgRect, xRadius: cornerRadius, yRadius: cornerRadius)
        clipPath.addClip()
        image.draw(in: imgRect)

        canvas.unlockFocus()
        return canvas
    }

    private func copyResult() {
        let result = renderPreview(in: .zero)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([result])
    }

    private func saveResult() {
        let result = renderPreview(in: .zero)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "beautified_screenshot.png"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let tiffData = result.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiffData),
                   let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                }
            }
        }
    }
}

private struct BackgroundStyleButton: View {
    let style: BackgroundStyle
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(style.preview)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                        .padding(isSelected ? -3 : 0)
                )
                .scaleEffect(isHovered ? 1.15 : 1.0)
                .shadow(color: .black.opacity(isHovered ? 0.15 : 0), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(duration: 0.2), value: isHovered)
        .animation(.spring(duration: 0.2), value: isSelected)
    }
}

enum BackgroundStyle: CaseIterable {
    case gradient1, gradient2, gradient3, gradient4, solid1, solid2, transparent

    var preview: LinearGradient {
        switch self {
        case .gradient1: return LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gradient2: return LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gradient3: return LinearGradient(colors: [.green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gradient4: return LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .solid1: return LinearGradient(colors: [.white], startPoint: .top, endPoint: .bottom)
        case .solid2: return LinearGradient(colors: [.black], startPoint: .top, endPoint: .bottom)
        case .transparent: return LinearGradient(colors: [.gray.opacity(0.3)], startPoint: .top, endPoint: .bottom)
        }
    }

    func drawBackground(in rect: NSRect) {
        switch self {
        case .gradient1:
            let gradient = NSGradient(colors: [NSColor.purple, NSColor.blue])!
            gradient.draw(in: rect, angle: -45)
        case .gradient2:
            let gradient = NSGradient(colors: [NSColor.orange, NSColor.systemPink])!
            gradient.draw(in: rect, angle: -45)
        case .gradient3:
            let gradient = NSGradient(colors: [NSColor.systemGreen, NSColor.systemBlue])!
            gradient.draw(in: rect, angle: -45)
        case .gradient4:
            let gradient = NSGradient(colors: [NSColor.systemIndigo, NSColor.purple])!
            gradient.draw(in: rect, angle: -45)
        case .solid1:
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
        case .solid2:
            NSColor.black.setFill()
            NSBezierPath(rect: rect).fill()
        case .transparent:
            let tileSize: CGFloat = 10
            for row in 0..<Int(rect.height / tileSize) + 1 {
                for col in 0..<Int(rect.width / tileSize) + 1 {
                    let color = (row + col) % 2 == 0 ? NSColor.white : NSColor(white: 0.9, alpha: 1)
                    color.setFill()
                    NSBezierPath(rect: NSRect(x: CGFloat(col) * tileSize, y: CGFloat(row) * tileSize, width: tileSize, height: tileSize)).fill()
                }
            }
        }
    }
}
