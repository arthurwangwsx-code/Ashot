import AppKit
import Testing
@testable import Ashot

@MainActor
struct PreviewQueueTests {
    @Test func queuedCapturesAreBoundedByCountAndPixels() {
        var queue = PreviewQueue<String>(maximumCount: 3, maximumPixels: 100)
        queue.append("a", pixels: 30); queue.append("b", pixels: 30); queue.append("c", pixels: 30)
        queue.append("d", pixels: 30)
        #expect(queue.count == 3); #expect(queue.popFirst() == "b")
        queue.append("large", pixels: 80)
        #expect(queue.count == 1); #expect(queue.popFirst() == "large")
        #expect(queue.popFirst() == nil)
    }
    @Test func invalidOrOversizedQueueItemsDoNotEvictValidCaptures() {
        var queue = PreviewQueue<String>(maximumCount: 3, maximumPixels: 100)
        queue.append("keep", pixels: 20)
        queue.append("too large", pixels: Int.max); queue.append("invalid", pixels: -1)
        #expect(queue.count == 1); #expect(queue.popFirst() == "keep")
    }
    @Test func timeoutSupportsNeverAndRejectsCorruptPreferences() {
        #expect(PreviewQueue<Int>.timeout(0) == 0)
        #expect(PreviewQueue<Int>.timeout(5) == 5)
        #expect(PreviewQueue<Int>.timeout(nil) == 10)
        #expect(PreviewQueue<Int>.timeout(.nan) == 10)
        #expect(PreviewQueue<Int>.timeout(-1) == 10)
    }
    @Test func previewCannotExtendOutsideSmallDisplay() {
        let visible = CGRect(x: -500, y: 100, width: 300, height: 280)
        let frame = PreviewPlacement.frame(previewSize: CGSize(width: 330, height: 400), anchorRect: nil,
                                          visibleFrame: visible, cursorLocation: CGPoint(x: -210, y: 130))
        #expect(visible.contains(frame))
    }
}

@MainActor
struct ImportAndScaleTests {
    @Test func oversizedHeadersAreRejectedBeforePixelDecode() {
        #expect(!ImageImportService.validDimensions(width: 1e12, height: 1e12))
        #expect(!ImageImportService.validDimensions(width: .infinity, height: 20))
        #expect(!ImageImportService.validDimensions(width: .nan, height: 20))
        #expect(!ImageImportService.validDimensions(width: -1, height: 20))
        #expect(ImageImportService.validDimensions(width: 3840, height: 2160))
    }
    @Test func captureAndPreviewExportsUseExplicitScale() throws {
        let image = try ProductTestImage.make(width: 80, height: 60, logicalSize: CGSize(width: 40, height: 30))
        let snapshot = try #require(CapturedImageSnapshot(image: image))
        let one = try ExportService.prepare(snapshot, options: ExportOptions(scale: .one))
        #expect(one.width == 40 && one.height == 30)
        let two = try ExportService.prepare(snapshot, options: ExportOptions(scale: .two))
        #expect(two.width == 80 && two.height == 60)
        #expect(try ExportService.prepare(snapshot, options: ExportOptions()).width == 80)
    }
    @Test func exclusiveFilePromiseWriteCannotOverwriteReceiverFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AshotPromiseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png")
        try AtomicFileWriter.writeExclusive(Data([1, 2, 3]), to: file)
        #expect(throws: (any Error).self) { try AtomicFileWriter.writeExclusive(Data([9]), to: file) }
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["image.png"])
    }
    @Test func explicitSRGBSamplingDoesNotRoundTripThroughCalibratedColors() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let red = try #require(CGColor(colorSpace: space, components: [1, 0, 0, 1]))
        let image = try ProductTestImage.make(width: 8, height: 8, color: red)
        let snapshot = try #require(CapturedImageSnapshot(image: image))
        let sample = try #require(RasterColorSampler.sample(snapshot.cgImage, x: 2, yFromTop: 2))
        #expect(sample.red == 1 && sample.green == 0 && sample.blue == 0)
        #expect(RasterColorSampler.sample(snapshot.cgImage, x: 8, yFromTop: 8) == nil)
    }
}
