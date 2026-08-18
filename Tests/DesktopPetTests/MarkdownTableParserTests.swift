import XCTest
import AppKit
@testable import DesktopPet

final class MarkdownTableParserTests: XCTestCase {
    func testParsesGitHubStyleTableAndRemovesDelimiterRow() throws {
        let segments = MarkdownTableParser.parse("""
        下面是架构：

        | 层级 | 作用 |
        | --- | --- |
        | 底层 | Cordis 微内核 |
        | 中层 | Profile + Bundle + Patch |
        """)

        XCTAssertEqual(segments.count, 2)
        guard case let .table(table) = segments[1] else {
            return XCTFail("expected a parsed table")
        }
        XCTAssertEqual(table.headers, ["层级", "作用"])
        XCTAssertEqual(table.rows, [
            ["底层", "Cordis 微内核"],
            ["中层", "Profile + Bundle + Patch"]
        ])
        XCTAssertFalse(String(describing: table).contains("---"))
    }

    func testParsesAlignmentEscapedPipesAndCodePipes() throws {
        let segments = MarkdownTableParser.parse("""
        | 左 | 中 | 右 |
        | :--- | :---: | ---: |
        | A \\| B | `x | y` | 42 |
        """)

        guard case let .table(table) = try XCTUnwrap(segments.first) else {
            return XCTFail("expected a parsed table")
        }
        XCTAssertEqual(table.alignments, [.left, .center, .right])
        XCTAssertEqual(table.rows, [["A | B", "`x | y`", "42"]])
    }

    func testPadsShortRowsToTheHeaderColumnCount() throws {
        let segments = MarkdownTableParser.parse("""
        A | B | C
        --- | --- | ---
        1 | 2
        """)

        guard case let .table(table) = try XCTUnwrap(segments.first) else {
            return XCTFail("expected a parsed table")
        }
        XCTAssertEqual(table.rows, [["1", "2", ""]])
    }

    func testLeavesOrdinaryPipeTextUntouchedWithoutDelimiterRow() {
        let source = "层级 | 作用\n这只是普通文本"
        XCTAssertEqual(MarkdownTableParser.parse(source), [.text(source)])
    }

    func testRendererBuildsNativeTextKitTableCells() {
        let source = """
        | 层级 | 作用 |
        | --- | :---: |
        | 底层 | Cordis 微内核 |
        """
        let rendered = SpeechBubbleController().renderMarkdown(MarkdownTableParser.parse(source))
        var cells: [NSTextTableBlock] = []
        rendered.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            cells.append(contentsOf: style.textBlocks.compactMap { $0 as? NSTextTableBlock })
        }

        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(Set(cells.map(\.startingRow)), [0, 1])
        XCTAssertEqual(Set(cells.map(\.startingColumn)), [0, 1])
        XCTAssertTrue(cells.filter { $0.startingRow == 0 }.allSatisfy {
            $0.contentWidthValueType == .percentageValueType
        })
        XCTAssertTrue(cells.filter { $0.startingRow > 0 }.allSatisfy {
            $0.contentWidthValueType != .percentageValueType
        })
        XCTAssertFalse(rendered.string.contains("---"))
        XCTAssertTrue(rendered.string.hasSuffix("\n"))

        let storage = rendered.string as NSString
        for index in 0..<storage.length where storage.character(at: index) == 10 {
            let style = rendered.attribute(.paragraphStyle, at: index, effectiveRange: nil)
                as? NSParagraphStyle
            XCTAssertEqual(style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.count, 1)
        }
    }

    func testBubbleSynchronizesWideTextContainerBeforeLayingOutTable() {
        _ = NSApplication.shared
        let controller = SpeechBubbleController()
        let anchor = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        controller.show(text: "普通回答", anchoredTo: anchor)
        let compact = controller.layoutSnapshotForTesting()
        controller.show(text: """
        | 文件 | 大小 | 说明 |
        | --- | --- | --- |
        | `.md` | 12 KB | `Markdown 源文件` |
        | `.pdf` | 80 KB | `排版好的 PDF 成品` |
        """, anchoredTo: anchor)
        let wide = controller.layoutSnapshotForTesting()

        XCTAssertEqual(compact.panelSize.width, 360, accuracy: 0.5)
        XCTAssertEqual(wide.panelSize.width, 500, accuracy: 0.5)
        XCTAssertGreaterThan(wide.scrollContentSize.width, compact.scrollContentSize.width)
        XCTAssertEqual(wide.textViewFrame.width, wide.scrollContentSize.width, accuracy: 0.5)
        XCTAssertEqual(wide.textContainerSize.width, wide.scrollContentSize.width, accuracy: 0.5)
        controller.hide()
    }

    func testNarrowMultilineTableRowsDoNotOverlapAndFillContainer() throws {
        let source = """
        | 文件 | 大小 | 说明 |
        | --- | --- | --- |
        | `.md` | 12 KB | `Markdown 源文件以及后续编辑说明` |
        | `.pdf` | 80 KB | `排版好的 PDF 成品与打印说明` |
        """
        let rendered = SpeechBubbleController().renderMarkdown(MarkdownTableParser.parse(source))
        let storage = NSTextStorage(attributedString: rendered)
        let layoutManager = NSLayoutManager()
        let containerWidth: CGFloat = 318
        let textContainer = NSTextContainer(
            size: CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 3
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var thirdColumnRows: [(row: Int, rect: CGRect)] = []
        rendered.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first,
                  block.startingColumn == 2
            else { return }
            var contentRange = range
            if contentRange.length > 0,
               (rendered.string as NSString).character(at: NSMaxRange(contentRange) - 1) == 10 {
                contentRange.length -= 1
            }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: contentRange,
                actualCharacterRange: nil
            )
            thirdColumnRows.append((
                row: block.startingRow,
                rect: layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            ))
        }

        thirdColumnRows.sort { $0.row < $1.row }
        XCTAssertEqual(thirdColumnRows.count, 3)
        for pair in zip(thirdColumnRows, thirdColumnRows.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.rect.maxY, pair.1.rect.minY)
        }
        XCTAssertGreaterThan(thirdColumnRows[1].rect.height, 25)
        XCTAssertGreaterThanOrEqual(
            layoutManager.usedRect(for: textContainer).width,
            containerWidth * 0.95
        )

        let height = ceil(layoutManager.usedRect(for: textContainer).height + 12)
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: containerWidth, height: height))
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(rendered)
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(containerWidth * 2),
            pixelsHigh: Int(height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = textView.bounds.size
        textView.cacheDisplay(in: textView.bounds, to: bitmap)
        XCTAssertNotNil(bitmap.representation(using: .png, properties: [:]))
    }
}
