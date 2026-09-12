import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct ExportOptions: Equatable, Sendable {
    enum Scale: String, CaseIterable, Sendable { case native, one, two }
    var format: ImageFormat = .png
    var quality: Double = 0.9
    var scale: Scale = .native

    static var current: Self {
        let defaults = UserDefaults.standard
        return Self(format: ImageFormat(rawValue: defaults.string(forKey: "imageFormat") ?? "png") ?? .png,
                    quality: defaults.object(forKey: "jpegQuality") as? Double ?? 0.9,
                    scale: Scale(rawValue: defaults.string(forKey: "exportScale") ?? "native") ?? .native)
    }
    nonisolated func pixelScale(native: CGFloat) -> CGFloat {
        switch scale { case .native: return native; case .one: return 1; case .two: return 2 }
    }
}

enum ExportFailure: LocalizedError {
    case encodingFailed, clipboardFailed, noAvailableFilename, invalidImage
    nonisolated var errorDescription: String? {
        switch self {
        case .encodingFailed: return "The image could not be encoded. Try another format."
        case .clipboardFailed: return "The clipboard could not be updated. Try copying again."
        case .noAvailableFilename: return "A unique filename could not be created. Choose another folder."
        case .invalidImage: return "The image is invalid or too large."
        }
    }
}

enum AtomicFileWriter {
    nonisolated static func replace(_ data: Data, at destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ashot-index-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in rename(source, target) }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    nonisolated static func writeExclusive(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ashot-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = chmod(temporary.path, S_IRUSR | S_IWUSR)
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    /// Prepare all bytes first, then atomically claim an unused final name. RENAME_EXCL prevents
    /// the check-then-write race across tasks and even across Ashot processes.
    nonisolated static func writeUnique(_ data: Data, in folder: URL, base: String, extension ext: String) throws -> URL {
        let stem = HistoryFileNaming.safeBase(base)
        let temporary = folder.appendingPathComponent(".ashot-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = chmod(temporary.path, S_IRUSR | S_IWUSR)
        for index in 1...10_000 {
            let filename = index == 1 ? "\(stem).\(ext)" : "\(stem)-\(index).\(ext)"
            let destination = folder.appendingPathComponent(filename)
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    renamex_np(source, target, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return destination }
            let code = errno
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw ExportFailure.noAvailableFilename
    }
}

enum ExportService {
    nonisolated static func encode(_ image: CGImage, options: ExportOptions) throws -> Data {
        guard image.width > 0, image.height > 0, image.width <= 32_768, image.height <= 32_768,
              image.width * image.height <= CanvasRenderer.maximumPixels else { throw ExportFailure.invalidImage }
        let outputImage: CGImage
        if options.format == .jpeg {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportFailure.encodingFailed }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect); context.draw(image, in: rect)
            guard let flattened = context.makeImage() else { throw ExportFailure.encodingFailed }
            outputImage = flattened
        } else { outputImage = image }
        let type: CFString
        switch options.format {
        case .png: type = UTType.png.identifier as CFString
        case .jpeg: type = UTType.jpeg.identifier as CFString
        case .tiff: type = UTType.tiff.identifier as CFString
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw ExportFailure.encodingFailed }
        let properties: [CFString: Any] = options.format == .jpeg ?
            [kCGImageDestinationLossyCompressionQuality: max(0, min(1, options.quality))] : [:]
        CGImageDestinationAddImage(destination, outputImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportFailure.encodingFailed }
        return data as Data
    }

    nonisolated static func saveUnique(_ snapshot: CapturedImageSnapshot, options: ExportOptions, in folder: URL, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let data = try encode(prepare(snapshot, options: options), options: options)
        return try AtomicFileWriter.writeUnique(data, in: folder, base: "Screenshot_\(formatter.string(from: date))", extension: options.format.fileExtension)
    }

    nonisolated static func prepare(_ snapshot: CapturedImageSnapshot, options: ExportOptions) throws -> CGImage {
        guard snapshot.logicalSize.width > 0, snapshot.logicalSize.height > 0 else { throw ExportFailure.invalidImage }
        if options.scale == .native { return snapshot.cgImage }
        let scale = options.pixelScale(native: CGFloat(snapshot.cgImage.width) / snapshot.logicalSize.width)
        let width = ceil(snapshot.logicalSize.width * scale), height = ceil(snapshot.logicalSize.height * scale)
        guard ImageImportService.validDimensions(width: Double(width), height: Double(height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportFailure.invalidImage }
        context.interpolationQuality = .high
        context.draw(snapshot.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ExportFailure.invalidImage }; return image
    }

    static func chooseDestination(completion: @escaping ((URL, ExportOptions)?) -> Void) {
        let panel = NSSavePanel()
        let controls = ExportPanelControls(panel: panel, options: .current)
        panel.title = L10n.string("Export Screenshot")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.accessoryView = controls.view
        controls.updateFormat()
        panel.begin { response in
            // Retain controls for the entire panel lifetime, including all target/action changes.
            guard response == .OK, let url = panel.url else { completion(nil); return }
            completion((url, controls.options))
        }
    }
}

private final class ExportPanelControls: NSObject {
    let panel: NSSavePanel
    let format = NSPopUpButton()
    let scale = NSPopUpButton()
    let quality = NSSlider(value: 0.9, minValue: 0.2, maxValue: 1, target: nil, action: nil)
    let view = NSStackView()

    init(panel: NSSavePanel, options: ExportOptions) {
        self.panel = panel
        super.init()
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
        view.frame = NSRect(x: 0, y: 0, width: 330, height: 105)
        format.addItems(withTitles: ["PNG", "JPEG", "TIFF"])
        format.selectItem(at: ImageFormat.allCases.firstIndex(of: options.format) ?? 0)
        format.target = self; format.action = #selector(updateFormat)
        format.setAccessibilityLabel(L10n.string("Image Format:"))
        scale.addItems(withTitles: [L10n.string("Original Pixels"), "1×", "2×"])
        scale.selectItem(at: ExportOptions.Scale.allCases.firstIndex(of: options.scale) ?? 0)
        scale.setAccessibilityLabel(L10n.string("Export Scale"))
        quality.doubleValue = options.quality; quality.setAccessibilityLabel(L10n.string("JPEG Quality"))
        for (title, control) in [(L10n.string("Image Format:"), format as NSView), (L10n.string("Export Scale"), scale as NSView), (L10n.string("JPEG Quality"), quality as NSView)] {
            let row = NSStackView(views: [NSTextField(labelWithString: title), control])
            row.spacing = 12; view.addArrangedSubview(row)
        }
    }
    var options: ExportOptions {
        ExportOptions(format: ImageFormat.allCases[max(0, format.indexOfSelectedItem)], quality: quality.doubleValue,
                      scale: ExportOptions.Scale.allCases[max(0, scale.indexOfSelectedItem)])
    }
    @objc func updateFormat() {
        let option = options
        switch option.format {
        case .png: panel.allowedContentTypes = [.png]
        case .jpeg: panel.allowedContentTypes = [.jpeg]
        case .tiff: panel.allowedContentTypes = [.tiff]
        }
        quality.isEnabled = option.format == .jpeg
        let stem = panel.nameFieldStringValue.isEmpty ? "Screenshot" : (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(stem).\(option.format.fileExtension)"
    }
}
