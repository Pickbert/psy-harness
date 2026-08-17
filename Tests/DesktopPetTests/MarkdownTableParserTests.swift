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
        XCTAssertFalse(rendered.string.contains("---"))
    }
}
