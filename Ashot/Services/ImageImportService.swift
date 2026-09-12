import AppKit
import ImageIO

enum ImageImportService {
    static func load(_ url: URL) throws -> NSImage {
        guard url.isFileURL else { throw ExportFailure.invalidImage }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? .max) <= 128_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              validDimensions(width: width, height: height) else { throw ExportFailure.invalidImage }
        guard let raster = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ExportFailure.invalidImage }
        return NSImage(cgImage: raster, size: CGSize(width: raster.width, height: raster.height))
    }
    nonisolated static func validDimensions(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite && width >= 1 && height >= 1 && width <= 32_768 && height <= 32_768 &&
        width * height <= Double(CaptureGeometry.maximumPixelCount)
    }
}
