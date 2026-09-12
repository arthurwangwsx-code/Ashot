import AppKit
import ImageIO

enum ImageImportService {
    static func load(_ url: URL) throws -> NSImage {
        let raster = try readRaster(url)
        return NSImage(cgImage: raster, size: CGSize(width: raster.width, height: raster.height))
    }
    nonisolated static func readRaster(_ url: URL) throws -> CGImage {
        guard url.isFileURL else { throw ExportFailure.invalidImage }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? .max) <= 128_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              validDimensions(width: width, height: height) else { throw ExportFailure.invalidImage }
        guard let raster = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ExportFailure.invalidImage }
        return raster
    }
    nonisolated static func thumbnail(_ url: URL, maximumPixels: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(1000, max(16, maximumPixels)),
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ExportFailure.invalidImage }
        return image
    }
    nonisolated static func validDimensions(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite && width >= 1 && height >= 1 && width <= 32_768 && height <= 32_768 &&
        width * height <= Double(CaptureGeometry.maximumPixelCount)
    }
}
