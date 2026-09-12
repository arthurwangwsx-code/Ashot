import AppKit
import SwiftUI
import Testing
@testable import Ashot

@MainActor
enum ProductTestImage {
    static func make(width: Int = 40, height: Int = 30, logicalSize: CGSize? = nil,
                     color: CGColor = CGColor(gray: 1, alpha: 1)) throws -> NSImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSImage(cgImage: try #require(context.makeImage()), size: logicalSize ?? CGSize(width: width, height: height))
    }
    static func annotation(_ type: AnnotationTool = .rectangle, start: CGPoint = CGPoint(x: 5, y: 5),
                           end: CGPoint = CGPoint(x: 15, y: 15)) -> Annotation {
        Annotation(type: type, startPoint: start, endPoint: end, points: [], color: .red, lineWidth: 3, text: "hello", counterNumber: 1)
    }
}

@Suite(.serialized)
@MainActor
struct EditorCommandTests {
    @Test func deleteUndoRestoresOriginalOrderAndIdentity() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        let a = ProductTestImage.annotation(), b = ProductTestImage.annotation(.line)
        model.addAnnotation(a); model.addAnnotation(b)
        model.selectedAnnotationID = a.id; model.deleteSelected()
        #expect(model.annotations.map(\.id) == [b.id])
        model.undo(); #expect(model.annotations.map(\.id) == [a.id, b.id])
        model.redo(); #expect(model.annotations.map(\.id) == [b.id])
    }

    @Test func oneDragIsOneUndoAndCancelRestoresPosition() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        let a = ProductTestImage.annotation(); model.addAnnotation(a)
        model.beginTransaction("Move")
        model.moveAnnotation(id: a.id, delta: CGSize(width: 2, height: 3))
        model.moveAnnotation(id: a.id, delta: CGSize(width: 4, height: 5))
        model.endTransaction()
        #expect(model.annotations[0].startPoint == CGPoint(x: 11, y: 13))
        model.undo(); #expect(model.annotations == [a])
        model.redo(); #expect(model.annotations[0].startPoint == CGPoint(x: 11, y: 13))
        model.beginTransaction("Move"); model.moveAnnotation(id: a.id, delta: CGSize(width: 90, height: 90))
        model.cancelTransaction(); #expect(model.annotations[0].startPoint == CGPoint(x: 11, y: 13))
    }

    @Test func noOpGestureAndCancelledGestureKeepRedoBranch() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        let a = ProductTestImage.annotation(); model.addAnnotation(a)
        model.moveAnnotation(id: a.id, delta: CGSize(width: 3, height: 0)); model.undo()
        model.beginTransaction("Move"); model.endTransaction()
        #expect(model.canRedo)
        model.beginTransaction("Move"); model.moveAnnotation(id: a.id, delta: CGSize(width: 9, height: 0)); model.cancelTransaction()
        #expect(model.canRedo); #expect(model.annotations == [a])
    }

    @Test func newEditAfterUndoDiscardsRedo() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        model.addAnnotation(ProductTestImage.annotation()); model.undo()
        #expect(model.canRedo)
        model.addAnnotation(ProductTestImage.annotation(.line)); #expect(!model.canRedo)
    }

    @Test func cropAndPasteNeverReplaceOriginalOrDeleteAnnotations() throws {
        let source = try ProductTestImage.make()
        let model = EditorViewModel(image: source)
        let a = ProductTestImage.annotation(); model.addAnnotation(a)
        model.crop(to: CGRect(x: 3, y: 4, width: 20, height: 18))
        #expect(model.image === source); #expect(model.annotations == [a])
        model.pasteImage(try ProductTestImage.make(width: 8, height: 8))
        #expect(model.annotations.count == 2); #expect(model.annotations[1].type == .image)
        #expect(model.annotations[1].image != nil); #expect(model.image === source)
        model.undo(); #expect(model.annotations == [a]); #expect(model.cropRect != nil)
        model.undo(); #expect(model.cropRect == nil); #expect(model.annotations == [a])
    }

    @Test func nestedCropsClampToVisibleContentAndInvalidCropDoesNothing() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        model.crop(to: CGRect(x: 5, y: 5, width: 20, height: 20))
        model.crop(to: CGRect(x: -100, y: -100, width: 110, height: 110))
        #expect(model.cropRect == CGRect(x: 5, y: 5, width: 5, height: 5))
        let revision = model.document.revision
        model.crop(to: CGRect(x: CGFloat.nan, y: 0, width: 3, height: 3))
        #expect(model.document.revision == revision)
    }

    @Test func selectedTextAndStyleAreUndoable() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        let a = ProductTestImage.annotation(.text); model.addAnnotation(a); model.selectedAnnotationID = a.id
        model.updateSelectedText("updated"); #expect(model.annotations[0].text == "updated")
        model.undo(); #expect(model.annotations[0].text == "hello")
        model.selectedAnnotationID = a.id; model.strokeColor = .blue
        #expect(model.annotations[0].color == .blue)
        model.undo(); #expect(model.annotations[0].color == .red)
    }

    @Test func resizingFreehandMovesAllPointsAndIsUndoable() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        var a = ProductTestImage.annotation(.freehand)
        a.points = [a.startPoint, CGPoint(x: 10, y: 12), a.endPoint]
        model.addAnnotation(a)
        model.resizeAnnotation(id: a.id, handle: .bottomRight, delta: CGSize(width: 10, height: 10))
        #expect(model.annotations[0].points != a.points)
        model.undo(); #expect(model.annotations == [a])
    }

    @Test func duplicationPreservesImageLayerButCreatesNewIdentity() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        model.pasteImage(try ProductTestImage.make(width: 5, height: 5))
        let image = model.annotations[0].image
        model.duplicateSelected()
        #expect(model.annotations.count == 2)
        #expect(model.annotations[0].id != model.annotations[1].id)
        #expect(model.annotations[1].image === image)
        model.undo(); #expect(model.annotations.count == 1)
    }

    @Test func beautyChangesAreOneTransactionAndCanBeCancelled() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        let revision = model.document.revision
        model.beginTransaction("Beautify"); model.applyBackground(ImageBackground())
        var style = ImageBackground(); style.padding = 12; model.applyBackground(style)
        model.cancelTransaction()
        #expect(model.document.background == nil); #expect(model.document.revision == revision)
        model.beginTransaction("Beautify"); model.applyBackground(style); style.padding = 20; model.applyBackground(style); model.endTransaction()
        model.undo(); #expect(model.document.background == nil)
        model.redo(); #expect(model.document.background?.padding == 20)
    }

    @Test func counterUndoRestoresNumberAndNewDocumentHasIndependentHistory() throws {
        let image = try ProductTestImage.make()
        let first = EditorViewModel(image: image), second = EditorViewModel(image: image)
        first.addAnnotation(ProductTestImage.annotation(.counter)); #expect(first.counterValue == 2)
        first.undo(); #expect(first.counterValue == 1)
        #expect(!second.canUndo); #expect(second.annotations.isEmpty)
    }
}

@MainActor
struct ExportConsistencyTests {
    @Test func nativePixelsSurviveCropAndDoNotDependOnDisplay() throws {
        let model = EditorViewModel(image: try ProductTestImage.make(width: 80, height: 60, logicalSize: CGSize(width: 40, height: 30)))
        model.crop(to: CGRect(x: 5, y: 4, width: 20, height: 10))
        let native = try CanvasRenderer.render(model.renderSnapshot())
        #expect(native.width == 40); #expect(native.height == 20)
        let one = try CanvasRenderer.render(model.renderSnapshot(), scale: 1)
        #expect(one.width == 20); #expect(one.height == 10)
    }

    @Test func previewUsesTheSamePixelsAsExporterAtSameScale() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        model.addAnnotation(ProductTestImage.annotation(.arrow))
        let preview = try #require(CapturedImageSnapshot(image: model.previewImage(scale: 1)))
        let export = try CanvasRenderer.render(model.renderSnapshot(), scale: 1)
        let a = try ExportService.encode(preview.cgImage, options: ExportOptions())
        let b = try ExportService.encode(export, options: ExportOptions())
        #expect(a == b)
    }

    @Test func redactionAlwaysExportsOpaqueBlackAndEffectsDoNotReadBehindIt() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        var cover = ProductTestImage.annotation(.redact, start: .zero, end: CGPoint(x: 40, y: 30))
        cover.color = .clear
        model.addAnnotation(cover)
        model.addAnnotation(ProductTestImage.annotation(.blur, start: CGPoint(x: 8, y: 8), end: CGPoint(x: 25, y: 22)))
        let pixels = NSBitmapImageRep(cgImage: try CanvasRenderer.render(model.renderSnapshot()))
        let pixelRaster = try #require(pixels.cgImage)
        let color = try #require(RasterColorSampler.sample(pixelRaster, x: 15, yFromTop: 15))
        #expect(color.red < 0.01); #expect(color.green < 0.01)
        #expect(color.blue < 0.01); #expect(color.alpha == 1)
    }

    @Test func insertedLayerIsPresentInRasterAndRemovedByUndo() throws {
        let model = EditorViewModel(image: try ProductTestImage.make())
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let red = try #require(CGColor(colorSpace: space, components: [1, 0, 0, 1]))
        let input = try ProductTestImage.make(width: 10, height: 10, color: red)
        let inputRaster = try #require(CapturedImageSnapshot(image: input))
        let inputColor = try #require(RasterColorSampler.sample(inputRaster.cgImage, x: 5, yFromTop: 5))
        #expect(inputColor.red > 0.99 && inputColor.green < 0.01)
        model.pasteImage(input)
        let layer = try #require(model.renderSnapshot().annotations.first?.image)
        let layerColor = try #require(RasterColorSampler.sample(layer, x: 5, yFromTop: 5))
        #expect(layerColor.red > 0.99 && layerColor.green < 0.01)
        let withLayer = NSBitmapImageRep(cgImage: try CanvasRenderer.render(model.renderSnapshot()))
        let composedRaster = try #require(withLayer.cgImage)
        let composedColor = try #require(RasterColorSampler.sample(composedRaster, x: 20, yFromTop: 15))
        #expect(composedColor.green < 0.01)
        model.undo()
        let without = NSBitmapImageRep(cgImage: try CanvasRenderer.render(model.renderSnapshot()))
        let withoutRaster = try #require(without.cgImage)
        let withoutColor = try #require(RasterColorSampler.sample(withoutRaster, x: 20, yFromTop: 15))
        #expect(withoutColor.green > 0.99)
    }

    @Test func formatsHaveCorrectEncodingAndTransparentJPEGIsWhite() throws {
        let image = try #require(CapturedImageSnapshot(image: ProductTestImage.make(color: CGColor(gray: 0, alpha: 0))))
        let png = try ExportService.encode(image.cgImage, options: ExportOptions(format: .png))
        let jpeg = try ExportService.encode(image.cgImage, options: ExportOptions(format: .jpeg, quality: 1))
        let tiff = try ExportService.encode(image.cgImage, options: ExportOptions(format: .tiff))
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4e, 0x47])
        #expect(Array(jpeg.prefix(2)) == [0xff, 0xd8])
        #expect(NSBitmapImageRep(data: tiff) != nil)
        let decoded = try #require(NSBitmapImageRep(data: jpeg))
        let decodedRaster = try #require(decoded.cgImage)
        let color = try #require(RasterColorSampler.sample(decodedRaster, x: 10, yFromTop: 10))
        #expect(color.red > 0.98); #expect(color.green > 0.98); #expect(color.blue > 0.98)
    }

    @Test func oversizedOutputFailsRatherThanReturningAnUneditedOriginal() throws {
        let model = EditorViewModel(image: try ProductTestImage.make(width: 2, height: 2, logicalSize: CGSize(width: 40_000, height: 40_000)))
        #expect(throws: RenderFailure.self) { try CanvasRenderer.render(model.renderSnapshot(), scale: 1) }
    }
}

struct AtomicExportTests {
    @Test func concurrentWritersCannotOverwriteEachOther() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AshotAtomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputs = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for index in 0..<24 {
                group.addTask { try AtomicFileWriter.writeUnique(Data("payload-\(index)".utf8), in: folder, base: "same", extension: "png") }
            }
            var outputs: [URL] = []
            for try await output in group { outputs.append(output) }
            return outputs
        }
        #expect(Set(outputs).count == 24)
        #expect(try Set(outputs.map { try Data(contentsOf: $0) }).count == 24)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 24)
    }

    @Test func pathSeparatorsCannotEscapeOutputDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AshotPath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = try AtomicFileWriter.writeUnique(Data([1]), in: folder, base: "../../outside", extension: "png")
        #expect(output.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(try Data(contentsOf: output) == Data([1]))
    }

    @Test func missingDirectoryIsARecoverableFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try AtomicFileWriter.writeUnique(Data([1]), in: folder, base: "image", extension: "png") }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
