import AppKit

/// Read pixels in an explicit sRGB context. NSBitmapImageRep.colorAt may return a calibrated
/// NSColor even for an sRGB raster; converting that color a second time changes its components.
enum RasterColorSampler {
    nonisolated static func sample(_ image: CGImage, x: Int, yFromTop y: Int) -> RGBA? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                  bytesPerRow: 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let alpha = CGFloat(bytes[3]) / 255
        let divisor = alpha > 0 ? alpha * 255 : 255
        return RGBA(red: CGFloat(bytes[0]) / divisor, green: CGFloat(bytes[1]) / divisor,
                    blue: CGFloat(bytes[2]) / divisor, alpha: alpha)
    }
}
