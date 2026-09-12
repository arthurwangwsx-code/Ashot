//
//  AshotTests.swift
//  AshotTests
//
//  Unit tests for Ashot's pure logic. These run headlessly (the app host skips its launch
//  setup during tests — see AppDelegate). GUI-driven capture flows aren't covered here.
//

import Testing
import AppKit
import SwiftUI
import Carbon.HIToolbox
@testable import Ashot

struct ReleaseReadinessRegressionTests {
    @Test func historyReservationsPreventConcurrentFilenameCollisions() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = HistoryFileNaming.uniqueFilename(base: "Shot", in: folder, reserved: [])
        let second = HistoryFileNaming.uniqueFilename(
            base: "Shot", in: folder, reserved: [folder.appendingPathComponent(first)]
        )
        #expect(first == "Shot.png")
        #expect(second == "Shot-2.png")
    }

    @Test func historyTemplatesCannotCreatePathsOrOversizedNames() {
        #expect(HistoryFileNaming.safeBase("../folder:name").contains("/") == false)
        #expect(HistoryFileNaming.safeBase("..") == "Screenshot")
        #expect(HistoryFileNaming.safeBase("") == "Screenshot")
        #expect(HistoryFileNaming.safeBase(String(repeating: "截图", count: 100)).utf8.count <= 120)
    }

    @Test func totalPixelBudgetRejectsHugeSquareImages() {
        #expect(CaptureGeometry.outputPixelSize(logicalSize: CGSize(width: 10_000, height: 10_000), scale: 1) == nil)
        #expect(CaptureGeometry.outputPixelSize(logicalSize: CGSize(width: 3840, height: 2160), scale: 1)?.width == 3840)
    }

    @Test func windowCoordinatesUsePrimaryDisplayRatherThanCurrentDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: -1000, y: 100, width: 400, height: 250)
        #expect(CaptureService.appKitWindowFrame(windowFrame: frame, primaryScreenFrame: primary)
            == CGRect(x: -1000, y: 550, width: 400, height: 250))
    }

    @Test func scrollingCaptureStopsAtFrameAndMemoryLimits() {
        #expect(ScrollingCaptureLimits.canAppend(frameCount: 1, storedPixels: 10_000_000, nextPixels: 10_000_000))
        #expect(!ScrollingCaptureLimits.canAppend(frameCount: 30, storedPixels: 0, nextPixels: 1))
        #expect(!ScrollingCaptureLimits.canAppend(frameCount: 1, storedPixels: 60_000_000, nextPixels: 10_000_000))
        #expect(!ScrollingCaptureLimits.canAppend(frameCount: 0, storedPixels: 0, nextPixels: Int.max))
    }
}

// MARK: - Color formatting (ColorPickerService)

struct ColorFormattingTests {
    private let picker = ColorPickerService.shared

    @Test func hexForPrimaryColors() {
        #expect(picker.formatColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), format: .hex) == "#FF0000")
        #expect(picker.formatColor(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), format: .hex) == "#00FF00")
        #expect(picker.formatColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), format: .hex) == "#0000FF")
        #expect(picker.formatColor(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), format: .hex) == "#FFFFFF")
        #expect(picker.formatColor(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), format: .hex) == "#000000")
    }

    @Test func rgbFormatting() {
        #expect(picker.formatColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), format: .rgb) == "rgb(255, 0, 0)")
    }

    @Test func hslFormatting() {
        // Pure red → hue 0, full saturation, 50% lightness.
        #expect(picker.formatColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), format: .hsl) == "hsl(0, 100%, 50%)")
        // Pure green → hue 120.
        #expect(picker.formatColor(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), format: .hsl) == "hsl(120, 100%, 50%)")
    }

    @Test func oklchHasExpectedShape() {
        // Don't pin exact float output; just verify the format string shape.
        let out = picker.formatColor(NSColor(srgbRed: 0.5, green: 0.2, blue: 0.8, alpha: 1), format: .oklch)
        #expect(out.hasPrefix("oklch("))
        #expect(out.hasSuffix(")"))
    }
}

// MARK: - Hotkey helpers (HotKeyManager)

struct HotKeyTests {
    @Test func carbonModifiersRoundTrip() {
        #expect(HotKeyManager.carbonModifiers(from: [.command, .shift]) == UInt32(cmdKey | shiftKey))
        #expect(HotKeyManager.carbonModifiers(from: [.control, .option]) == UInt32(controlKey | optionKey))
        #expect(HotKeyManager.carbonModifiers(from: []) == 0)
    }

    @Test func modifierStringUsesMacOrder() {
        // macOS displays modifiers in the order ⌃⌥⇧⌘.
        #expect(HotKeyManager.modifierString(from: UInt32(cmdKey | shiftKey)) == "⇧⌘")
        #expect(HotKeyManager.modifierString(from: UInt32(controlKey | optionKey | shiftKey | cmdKey)) == "⌃⌥⇧⌘")
    }

    @Test func keyStringMapsCommonKeys() {
        #expect(HotKeyManager.keyString(from: UInt32(kVK_ANSI_A)) == "A")
        #expect(HotKeyManager.keyString(from: UInt32(kVK_ANSI_2)) == "2")
        #expect(HotKeyManager.keyString(from: UInt32(kVK_Space)) == "Space")
    }

    @Test func defaultsAvoidSystemScreenshotKeys() {
        // ⌘⇧3/4/5/6 are reserved by macOS; area/fullscreen must not use them.
        #expect(ShortcutBinding.defaultAreaCapture.keyCode == UInt32(kVK_ANSI_2))
        #expect(ShortcutBinding.defaultFullscreen.keyCode == UInt32(kVK_ANSI_1))
        #expect(ShortcutBinding.defaultAreaCapture.keyCode != UInt32(kVK_ANSI_5))
        #expect(ShortcutBinding.defaultFullscreen.keyCode != UInt32(kVK_ANSI_6))
    }

    @Test func everyActionHasADefaultBinding() {
        for action in ShortcutAction.allCases {
            #expect(action.defaultBinding.modifiers != 0)
        }
    }

    @Test func systemScreenshotShortcutsAreRejected() {
        let reserved = ShortcutBinding(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(cmdKey | shiftKey),
            displayString: "⌘⇧4"
        )
        let available = ShortcutBinding(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(cmdKey | optionKey),
            displayString: "⌘⌥4"
        )
        #expect(HotKeyManager.isReservedSystemScreenshotShortcut(reserved))
        #expect(!HotKeyManager.isReservedSystemScreenshotShortcut(available))
    }

    @Test func disabledShortcutIsNotRestoredFromDefaultsOrSavedData() {
        let saved = [ShortcutAction.captureArea.rawValue: ShortcutBinding.defaultAreaCapture]
        let resolved = HotKeyManager.resolvedBindings(
            saved: saved,
            disabledRawValues: [ShortcutAction.captureArea.rawValue]
        )

        #expect(resolved[.captureArea] == nil)
        #expect(resolved[.captureFullscreen] == .defaultFullscreen)
    }
}

// MARK: - Local editor tool shortcuts

struct EditorShortcutTests {
    @Test func defaultsCoverEveryToolWithoutConflicts() {
        let resolved = EditorShortcutManager.resolvedBindings(saved: [:], disabledRawValues: [])

        #expect(resolved.count == EditorShortcutAction.allCases.count)
        #expect(Set(resolved.values).count == resolved.values.count)
        #expect(resolved[.select] == "V")
        #expect(resolved[.arrow] == "A")
        #expect(resolved[.rectangle] == "R")
        #expect(resolved[.text] == "T")
    }

    @Test func disabledEditorShortcutIsNotRestoredFromDefaults() {
        let resolved = EditorShortcutManager.resolvedBindings(
            saved: [EditorShortcutAction.arrow.rawValue: "K"],
            disabledRawValues: [EditorShortcutAction.arrow.rawValue]
        )

        #expect(resolved[.arrow] == nil)
        #expect(resolved[.rectangle] == "R")
    }

    @Test func editorShortcutAcceptsOnlyOneUnmodifiedLetter() {
        #expect(EditorShortcutManager.normalizedLetter("a", modifiers: []) == "A")
        #expect(EditorShortcutManager.normalizedLetter("A", modifiers: [.shift]) == "A")
        #expect(EditorShortcutManager.normalizedLetter("1", modifiers: []) == nil)
        #expect(EditorShortcutManager.normalizedLetter("ab", modifiers: []) == nil)
        #expect(EditorShortcutManager.normalizedLetter("a", modifiers: [.command]) == nil)
        #expect(EditorShortcutManager.normalizedLetter("a", modifiers: [.option]) == nil)
    }

    @Test func everyEditorShortcutMapsToItsTool() {
        #expect(Set(EditorShortcutAction.allCases.map(\.tool.rawValue)).count == EditorShortcutAction.allCases.count)
        #expect(EditorShortcutAction.line.tool == .line)
        #expect(EditorShortcutAction.pixelate.tool == .pixelate)
    }
}

// MARK: - In-app language selection

struct LocalizationTests {
    @Test func explicitLanguageOverridesSystemPreference() {
        #expect(AppLanguage.resolvedCode(for: "zh-Hans", preferredLanguages: ["en-US"]) == "zh-Hans")
        #expect(AppLanguage.resolvedCode(for: "en", preferredLanguages: ["zh-Hans-CN"]) == "en")
    }

    @Test func systemLanguageMapsChineseVariantsToSimplifiedChinese() {
        #expect(AppLanguage.resolvedCode(for: "system", preferredLanguages: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(AppLanguage.resolvedCode(for: "system", preferredLanguages: ["en-MY"]) == "en")
    }
}

// MARK: - Image export (ImageFormat / NSImage.data)

struct ImageExportTests {
    @Test func formatMapping() {
        #expect(ImageFormat(rawValue: "png") == .png)
        #expect(ImageFormat(rawValue: "jpeg") == .jpeg)
        #expect(ImageFormat(rawValue: "tiff") == .tiff)
        #expect(ImageFormat(rawValue: "gif") == nil)
        #expect(ImageFormat.jpeg.fileExtension == "jpeg")
        #expect(ImageFormat.png.displayName == "PNG")
    }

    /// Regression: the thumbnail "Save" used to write PNG bytes regardless of the chosen format.
    /// Verify each format actually produces its own encoding (magic bytes differ).
    @Test func dataRespectsRequestedFormat() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()

        let png = try #require(image.data(format: .png))
        let jpeg = try #require(image.data(format: .jpeg))
        let snapshot = try #require(CapturedImageSnapshot(image: image))
        let backgroundPNG = try #require(snapshot.data(format: .png))
        let backgroundJPEG = try #require(snapshot.data(format: .jpeg))

        // PNG signature: 89 50 4E 47
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        // JPEG signature: FF D8
        #expect(Array(jpeg.prefix(2)) == [0xFF, 0xD8])
        #expect(Array(backgroundPNG.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        #expect(Array(backgroundJPEG.prefix(2)) == [0xFF, 0xD8])
        // The two encodings must differ — proves format is honored, not hardcoded to PNG.
        #expect(png != jpeg)
    }

    @Test func automaticSaveNamesDoNotOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AshotSaveNameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = CaptureService.uniqueScreenshotURL(in: folder, format: .png, date: date)
        try Data([0]).write(to: first)
        let second = CaptureService.uniqueScreenshotURL(in: folder, format: .png, date: date)

        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("-2.png"))
    }
}

struct CaptureModeTests {
    @Test func everyModeHasStableHistorySource() {
        #expect(CaptureMode.area.historySource == "Area")
        #expect(CaptureMode.fullscreen.historySource == "Fullscreen")
        #expect(CaptureMode.window.historySource == "Window")
        #expect(CaptureMode.delayed.historySource == "Delayed")
        #expect(CaptureMode.scrolling.historySource == "Scrolling")
    }

    @Test func completionOptionsDefaultToPreviewAndClipboard() {
        let options = CaptureCompletionOptions(showPreview: nil, autoCopy: nil, autoSave: false)
        #expect(options.showPreview)
        #expect(options.autoCopy)
        #expect(!options.autoSave)
    }

    @Test func completionOptionsCanDisablePreviewAndClipboardIndependently() {
        let options = CaptureCompletionOptions(showPreview: false, autoCopy: false, autoSave: true)
        #expect(!options.showPreview)
        #expect(!options.autoCopy)
        #expect(options.autoSave)
    }

    @Test func synthesizedDragUsesPreviousCursorAsSelectionOrigin() {
        let previous = NSPoint(x: 40, y: 50)
        let current = NSPoint(x: 140, y: 170)
        #expect(
            AreaSelectionView.dragStartPoint(
                existingStart: nil,
                previousCursor: previous,
                dragPoint: current
            ) == previous
        )
    }

    @Test func areaSelectionKeyboardActionsMatchMacScreenshotConventions() {
        #expect(AreaSelectionController.selectionResult(forKeyCode: 49) == .frontmostWindow)
        #expect(AreaSelectionController.selectionResult(forKeyCode: 53) == .cancelled)
        #expect(AreaSelectionController.selectionResult(forKeyCode: 0) == nil)
    }

    @Test func captureGeometryRejectsInvalidAndOversizedInputs() {
        let displaySize = CGSize(width: 1440, height: 900)

        #expect(
            CaptureGeometry.validatedSourceRect(
                CGRect(x: -50, y: 100, width: 200, height: 200),
                displaySize: displaySize
            ) == CGRect(x: 0, y: 100, width: 150, height: 200)
        )
        #expect(
            CaptureGeometry.validatedSourceRect(
                CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                displaySize: displaySize
            ) == nil
        )
        #expect(
            CaptureGeometry.outputPixelSize(
                logicalSize: CGSize(width: 1440, height: 900),
                scale: 2
            )?.width == 2880
        )
        let oversized = CaptureGeometry.outputPixelSize(
            logicalSize: CGSize(width: 20_000, height: 900),
            scale: 2
        )
        #expect(oversized?.width == nil)
    }

    @Test func displaySourceRectConvertsToGlobalAppKitCoordinates() {
        let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let source = CGRect(x: 100, y: 150, width: 400, height: 250)

        #expect(
            CaptureService.appKitCaptureFrame(sourceRect: source, screenFrame: screen)
                == CGRect(x: -1340, y: 700, width: 400, height: 250)
        )
    }
}

struct PreviewPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let previewSize = CGSize(width: 284, height: 200)

    @Test func placesPreviewOnRightWhenSpaceIsAvailable() {
        let anchor = CGRect(x: 100, y: 300, width: 300, height: 200)
        let frame = PreviewPlacement.frame(
            previewSize: previewSize,
            anchorRect: anchor,
            visibleFrame: screen,
            cursorLocation: CGPoint(x: 400, y: 300)
        )

        #expect(frame.minX == anchor.maxX + PreviewPlacement.gap)
        #expect(!frame.intersects(anchor))
    }

    @Test func switchesToLeftWhenRightSideIsUnavailable() {
        let anchor = CGRect(x: 1050, y: 300, width: 300, height: 200)
        let frame = PreviewPlacement.frame(
            previewSize: previewSize,
            anchorRect: anchor,
            visibleFrame: screen,
            cursorLocation: CGPoint(x: 1350, y: 300)
        )

        #expect(frame.maxX == anchor.minX - PreviewPlacement.gap)
        #expect(!frame.intersects(anchor))
    }

    @Test func switchesBelowWhenNeitherHorizontalSideFits() {
        let anchor = CGRect(x: 100, y: 400, width: 1240, height: 200)
        let frame = PreviewPlacement.frame(
            previewSize: previewSize,
            anchorRect: anchor,
            visibleFrame: screen,
            cursorLocation: CGPoint(x: 1340, y: 400)
        )

        #expect(frame.maxY == anchor.minY - PreviewPlacement.gap)
        #expect(!frame.intersects(anchor))
    }

    @Test func fullscreenFallbackStaysNearCursorAndInsideVisibleFrame() {
        let cursor = CGPoint(x: 700, y: 450)
        let frame = PreviewPlacement.frame(
            previewSize: previewSize,
            anchorRect: screen,
            visibleFrame: screen,
            cursorLocation: cursor
        )
        let safe = screen.insetBy(dx: PreviewPlacement.screenMargin, dy: PreviewPlacement.screenMargin)

        #expect(safe.contains(frame))
        #expect(frame.minX == cursor.x + PreviewPlacement.gap)
    }
}

// MARK: - Annotation geometry (EditorViewModel)

struct AnnotationTests {
    private func make(_ type: AnnotationTool, _ start: CGPoint, _ end: CGPoint) -> Annotation {
        Annotation(type: type, startPoint: start, endPoint: end, points: [], color: .red, lineWidth: 3, text: "", counterNumber: 0)
    }

    @Test func rectangleBoundingRectNormalizes() {
        // End is above-left of start; boundingRect should still be the normalized rect.
        let a = make(.rectangle, CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 10))
        #expect(a.boundingRect == CGRect(x: 10, y: 10, width: 20, height: 30))
    }

    @Test func translateMovesAllPoints() {
        var a = make(.rectangle, CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40))
        a.translate(by: CGSize(width: 5, height: -5))
        #expect(a.startPoint == CGPoint(x: 15, y: 5))
        #expect(a.endPoint == CGPoint(x: 35, y: 35))
    }

    @Test func arrowHitTest() {
        let a = make(.arrow, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        #expect(a.hitTest(point: CGPoint(x: 50, y: 1), tolerance: 6))   // on the line
        #expect(!a.hitTest(point: CGPoint(x: 50, y: 80), tolerance: 6)) // far away
    }

    @Test func lineUsesLineHitTestingAndPixelateUsesRectBounds() {
        let line = make(.line, CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10))
        let pixelate = make(.pixelate, CGPoint(x: 30, y: 40), CGPoint(x: 90, y: 120))

        #expect(line.hitTest(point: CGPoint(x: 50, y: 12), tolerance: 3))
        #expect(!line.hitTest(point: CGPoint(x: 50, y: 40), tolerance: 3))
        #expect(pixelate.boundingRect == CGRect(x: 30, y: 40, width: 60, height: 80))
        #expect(pixelate.hitTest(point: CGPoint(x: 50, y: 60), tolerance: 2))
    }

    @Test func shiftConstrainsLinesAndShapes() {
        let snappedLine = AnnotationGeometry.constrainedEndpoint(
            start: .zero,
            end: CGPoint(x: 80, y: 30),
            tool: .line,
            isShiftPressed: true
        )
        let square = AnnotationGeometry.constrainedEndpoint(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 50, y: 30),
            tool: .rectangle,
            isShiftPressed: true
        )
        let unchanged = AnnotationGeometry.constrainedEndpoint(
            start: .zero,
            end: CGPoint(x: 80, y: 30),
            tool: .line,
            isShiftPressed: false
        )

        #expect(abs(snappedLine.y) < 0.001)
        #expect(square == CGPoint(x: 50, y: 50))
        #expect(unchanged == CGPoint(x: 80, y: 30))
    }
}
