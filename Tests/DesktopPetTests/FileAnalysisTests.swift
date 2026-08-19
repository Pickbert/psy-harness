import AppKit
import CryptoKit
import XCTest
@testable import DesktopPet

final class FileAnalysisTests: XCTestCase {
    func testLimitsUseMiBAndNormalizeInvalidValues() {
        XCTAssertEqual(FileAnalysisLimits.defaultMaxFileSizeMB, 10)
        XCTAssertEqual(FileAnalysisLimits.bytes(forMaxFileSizeMB: 10), 10 * 1_048_576)
        XCTAssertTrue(FileAnalysisLimits.isValid(maxFileSizeMB: 1))
        XCTAssertTrue(FileAnalysisLimits.isValid(maxFileSizeMB: 100))
        XCTAssertFalse(FileAnalysisLimits.isValid(maxFileSizeMB: 0))
        XCTAssertFalse(FileAnalysisLimits.isValid(maxFileSizeMB: 101))
        XCTAssertEqual(FileAnalysisLimits.normalized(maxFileSizeMB: -1), 10)
    }

    func testFileLimitPersistsAndDamagedValuesFallBack() throws {
        let suiteName = "FileAnalysisSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = DeepSeekSettingsStore(defaults: defaults)

        XCTAssertEqual(settings.fileAnalysisMaxFileSizeMB, 10)
        settings.fileAnalysisMaxFileSizeMB = 42
        XCTAssertEqual(DeepSeekSettingsStore(defaults: defaults).fileAnalysisMaxFileSizeMB, 42)

        defaults.set("damaged", forKey: "desktopPetFileAnalysisMaxFileSizeMB")
        XCTAssertEqual(settings.fileAnalysisMaxFileSizeMB, 10)
        XCTAssertEqual(defaults.integer(forKey: "desktopPetFileAnalysisMaxFileSizeMB"), 10)
        defaults.set(101, forKey: "desktopPetFileAnalysisMaxFileSizeMB")
        XCTAssertEqual(settings.fileAnalysisMaxFileSizeMB, 10)
    }

    func testTextSessionCreatesManifestChunksAndPreservesOriginal() throws {
        try withStore { store, inputRoot, workspace, _, _ in
            let original = inputRoot.appendingPathComponent("研究笔记.md")
            let text = String(repeating: "机器人供应链：电机、减速器、传感器。\n", count: 700)
            try text.write(to: original, atomically: true, encoding: .utf8)
            let originalHash = try sha256(original)

            let session = try store.createSession(from: [original], in: workspace, maxFileSizeMB: 10)

            XCTAssertEqual(session.displayNames, ["研究笔记.md"])
            XCTAssertGreaterThan(session.files[0].chunkCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.sessionURL.appendingPathComponent("manifest.md").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.sessionURL.appendingPathComponent(session.files[0].normalizedRelativePath).path))
            let firstChunk = session.sessionURL
                .appendingPathComponent(session.files[0].chunkDirectoryRelativePath)
                .appendingPathComponent("chunk-0001.md")
            XCTAssertTrue(try String(contentsOf: firstChunk, encoding: .utf8).contains("标准化文本行：1-"))
            XCTAssertEqual(try sha256(original), originalHash)
            let manifest = try String(contentsOf: session.sessionURL.appendingPathComponent("manifest.md"), encoding: .utf8)
            XCTAssertFalse(manifest.contains(inputRoot.path))
            XCTAssertEqual(store.activeSession(in: workspace)?.id, session.id)
            XCTAssertEqual(
                session.sessionURL.deletingLastPathComponent().standardizedFileURL,
                workspace.appendingPathComponent(FileAnalysisSessionStore.directoryName).standardizedFileURL
            )
            XCTAssertEqual(session.relativePath, "DesktopPet-FileAnalysis/\(session.id)")
        }
    }

    func testRejectsMoreThanFiveFilesAndOversizedSingleFile() throws {
        try withStore { store, inputRoot, workspace, _, _ in
            let sixFiles = try (0..<6).map { index -> URL in
                let url = inputRoot.appendingPathComponent("\(index).txt")
                try "ok".write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            XCTAssertThrowsError(try store.createSession(from: sixFiles, in: workspace, maxFileSizeMB: 10)) {
                XCTAssertEqual($0 as? FileAnalysisError, .tooManyFiles(6))
            }

            let large = inputRoot.appendingPathComponent("large.txt")
            FileManager.default.createFile(atPath: large.path, contents: nil)
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: UInt64(1_048_577))
            try handle.close()
            XCTAssertThrowsError(try store.createSession(from: [large], in: workspace, maxFileSizeMB: 1)) {
                XCTAssertEqual($0 as? FileAnalysisError, .fileTooLarge(name: "large.txt", limitMB: 1))
            }
        }
    }

    func testRejectsBatchAboveOneHundredMiBBeforeExtraction() throws {
        try withStore { store, inputRoot, workspace, _, _ in
            let files = try (0..<2).map { index -> URL in
                let url = inputRoot.appendingPathComponent("large-\(index).txt")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(51 * 1_048_576))
                try handle.close()
                return url
            }
            XCTAssertThrowsError(try store.createSession(from: files, in: workspace, maxFileSizeMB: 100)) {
                XCTAssertEqual($0 as? FileAnalysisError, .batchTooLarge)
            }
        }
    }

    func testDuplicateNamesAreIsolatedAndExpiredSessionsAreCleaned() throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        try withStore(now: { clock }) { store, inputRoot, workspace, _, _ in
            let firstDirectory = inputRoot.appendingPathComponent("one", isDirectory: true)
            let secondDirectory = inputRoot.appendingPathComponent("two", isDirectory: true)
            try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
            let first = firstDirectory.appendingPathComponent("report.txt")
            let second = secondDirectory.appendingPathComponent("report.txt")
            try "first".write(to: first, atomically: true, encoding: .utf8)
            try "second".write(to: second, atomically: true, encoding: .utf8)

            let session = try store.createSession(from: [first, second], in: workspace, maxFileSizeMB: 10)
            XCTAssertEqual(session.files.map(\.sourceRelativePath), ["sources/report.txt", "sources/report-2.txt"])

            clock = clock.addingTimeInterval(FileAnalysisLimits.retentionInterval + 1)
            try store.cleanupExpiredSessions(in: workspace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.sessionURL.path))
            XCTAssertNil(store.activeSession(in: workspace))
        }
    }

    func testPDFAndDOCXAreNormalizedLocally() throws {
        try withStore { store, inputRoot, workspace, _, _ in
            let pdfURL = inputRoot.appendingPathComponent("sample.pdf")
            let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
            textView.string = "PDF 第一页内容"
            try textView.dataWithPDF(inside: textView.bounds).write(to: pdfURL)

            let docxURL = inputRoot.appendingPathComponent("sample.docx")
            let docxSource = inputRoot.appendingPathComponent("docx-source.txt")
            try "DOCX 段落内容".write(to: docxSource, atomically: true, encoding: .utf8)
            let converter = Process()
            converter.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            converter.arguments = ["-convert", "docx", "-output", docxURL.path, docxSource.path]
            try converter.run()
            converter.waitUntilExit()
            XCTAssertEqual(converter.terminationStatus, 0)

            let session = try store.createSession(from: [pdfURL, docxURL], in: workspace, maxFileSizeMB: 10)
            let normalized = try session.files.map {
                try String(contentsOf: session.sessionURL.appendingPathComponent($0.normalizedRelativePath), encoding: .utf8)
            }
            XCTAssertTrue(normalized[0].contains("PDF 第 1 页"))
            XCTAssertTrue(normalized[1].contains("DOCX 段落内容"))
        }
    }

    func testSpreadsheetSessionExtractsXLSXAndXLSMWithoutRunningMacros() throws {
        try withStore { store, inputRoot, workspace, _, _ in
            let xlsxURL = inputRoot.appendingPathComponent("经营数据.xlsx")
            let xlsmURL = inputRoot.appendingPathComponent("经营数据.xlsm")
            try makeSpreadsheet(at: xlsxURL)
            try makeSpreadsheet(at: xlsmURL)

            let session = try store.createSession(
                from: [xlsxURL, xlsmURL],
                in: workspace,
                maxFileSizeMB: 10
            )

            XCTAssertEqual(session.files.map(\.kind), ["spreadsheet", "spreadsheet"])
            XCTAssertEqual(session.files.map(\.sheetCount), [2, 2])
            for file in session.files {
                let normalized = try String(
                    contentsOf: session.sessionURL.appendingPathComponent(file.normalizedRelativePath),
                    encoding: .utf8
                )
                XCTAssertTrue(normalized.contains("## 工作表：概览"))
                XCTAssertTrue(normalized.contains("## 工作表：明细"))
                XCTAssertTrue(normalized.contains("A1\ts\t收入"))
                XCTAssertTrue(normalized.contains("B1\tinlineStr\t内联文本"))
                XCTAssertTrue(normalized.contains("C1\tb\tTRUE"))
                XCTAssertTrue(normalized.contains("E1\tn\t84\tD1*2"))
                XCTAssertTrue(normalized.contains("F1\tdate\t2026-08-19T00:00:00Z"))
                XCTAssertTrue(normalized.contains("G1\tdate\t2026-08-19 00:00:00"))
                XCTAssertTrue(normalized.contains("Z100\ts\t稀疏单元格"))
                XCTAssertTrue(normalized.contains("宏不会执行"))
            }

            let manifest = try String(
                contentsOf: session.sessionURL.appendingPathComponent("manifest.md"),
                encoding: .utf8
            )
            XCTAssertTrue(manifest.contains("2 个工作表"))
            XCTAssertTrue(manifest.contains("不会重新计算公式"))
        }
    }

    func testSpreadsheetErrorsAreSpecificAndLegacyXLSIsRejected() throws {
        try withStore { store, inputRoot, workspace, _, _ in
            let corrupt = inputRoot.appendingPathComponent("corrupt.xlsx")
            try "not a zip archive".write(to: corrupt, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try store.createSession(from: [corrupt], in: workspace, maxFileSizeMB: 10)) {
                XCTAssertEqual($0 as? FileAnalysisError, .invalidSpreadsheet("corrupt.xlsx"))
            }

            let protected = inputRoot.appendingPathComponent("protected.xlsm")
            try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]).write(to: protected)
            XCTAssertThrowsError(try store.createSession(from: [protected], in: workspace, maxFileSizeMB: 10)) {
                XCTAssertEqual($0 as? FileAnalysisError, .protectedSpreadsheet("protected.xlsm"))
            }

            let empty = inputRoot.appendingPathComponent("empty.xlsx")
            try makeSpreadsheet(at: empty, includeCells: false)
            XCTAssertThrowsError(try store.createSession(from: [empty], in: workspace, maxFileSizeMB: 10)) {
                XCTAssertEqual($0 as? FileAnalysisError, .emptySpreadsheet("empty.xlsx"))
            }

            let legacy = inputRoot.appendingPathComponent("legacy.xls")
            try "legacy".write(to: legacy, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try store.createSession(from: [legacy], in: workspace, maxFileSizeMB: 10)) {
                XCTAssertEqual($0 as? FileAnalysisError, .unsupportedType("legacy.xls"))
            }
        }
    }

    func testCacheClearingCoversCurrentWorkspaceAndLegacyApplicationSupport() throws {
        try withStore { store, inputRoot, workspace, legacyRoot, _ in
            let input = inputRoot.appendingPathComponent("note.txt")
            try "content".write(to: input, atomically: true, encoding: .utf8)
            let session = try store.createSession(from: [input], in: workspace, maxFileSizeMB: 10)

            let legacyID = UUID().uuidString.lowercased()
            let legacySession = legacyRoot.appendingPathComponent(legacyID, isDirectory: true)
            try FileManager.default.createDirectory(at: legacySession, withIntermediateDirectories: true)
            let legacyMetadata = FileAnalysisSessionMetadata(
                id: legacyID,
                agentSessionID: "legacy-agent-session",
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(FileAnalysisLimits.retentionInterval),
                files: []
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(legacyMetadata).write(
                to: legacySession.appendingPathComponent(".desktop-pet-file-session.json")
            )
            let unrelated = workspace.appendingPathComponent(FileAnalysisSessionStore.directoryName)
                .appendingPathComponent("user-notes", isDirectory: true)
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

            try store.clearCache(in: workspace)

            XCTAssertFalse(FileManager.default.fileExists(atPath: session.sessionURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacySession.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertNil(store.activeSession(in: workspace))
        }
    }

    func testActiveSessionDoesNotFollowAWorkspaceChange() throws {
        try withStore { store, inputRoot, workspace, _, _ in
            let input = inputRoot.appendingPathComponent("note.txt")
            try "content".write(to: input, atomically: true, encoding: .utf8)
            let session = try store.createSession(from: [input], in: workspace, maxFileSizeMB: 10)
            XCTAssertEqual(store.activeSession(in: workspace)?.id, session.id)

            let otherWorkspace = workspace.deletingLastPathComponent()
                .appendingPathComponent("other-workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
            XCTAssertNil(store.activeSession(in: otherWorkspace))
            XCTAssertNil(store.activeSession(in: workspace))
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.sessionURL.path))
        }
    }

    private func withStore(
        now: @escaping () -> Date = Date.init,
        _ body: (FileAnalysisSessionStore, URL, URL, URL, UserDefaults) throws -> Void
    ) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopPetFileAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        let inputRoot = base.appendingPathComponent("input", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let legacyRoot = base.appendingPathComponent("legacy-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let suiteName = "FileAnalysisStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FileAnalysisSessionStore(legacyRootURL: legacyRoot, defaults: defaults, now: now)
        try body(store, inputRoot, workspace, legacyRoot, defaults)
    }

    private func sha256(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    private func makeSpreadsheet(at destination: URL, includeCells: Bool = true) throws {
        let packageRoot = destination.deletingLastPathComponent()
            .appendingPathComponent("xlsx-package-\(UUID().uuidString)", isDirectory: true)
        let relationships = packageRoot.appendingPathComponent("_rels", isDirectory: true)
        let workbookRelationships = packageRoot.appendingPathComponent("xl/_rels", isDirectory: true)
        let worksheets = packageRoot.appendingPathComponent("xl/worksheets", isDirectory: true)
        try FileManager.default.createDirectory(at: relationships, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workbookRelationships, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worksheets, withIntermediateDirectories: true)

        try writeXML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
              <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
              <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
              <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
              <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """,
            to: packageRoot.appendingPathComponent("[Content_Types].xml")
        )
        try writeXML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """,
            to: relationships.appendingPathComponent(".rels")
        )
        try writeXML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets>
                <sheet name="概览" sheetId="1" r:id="rId1"/>
                <sheet name="明细" sheetId="2" r:id="rId2"/>
              </sheets>
            </workbook>
            """,
            to: packageRoot.appendingPathComponent("xl/workbook.xml")
        )
        try writeXML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
            </Relationships>
            """,
            to: workbookRelationships.appendingPathComponent("workbook.xml.rels")
        )
        try writeXML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">
              <si><t>收入</t></si>
              <si><t>稀疏单元格</t></si>
              <si><t>第二张表</t></si>
            </sst>
            """,
            to: packageRoot.appendingPathComponent("xl/sharedStrings.xml")
        )
        try writeXML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <fonts count="1"><font><sz val="11"/><name val="Arial"/></font></fonts>
              <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
              <borders count="1"><border/></borders>
              <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
              <cellXfs count="2">
                <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
                <xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
              </cellXfs>
            </styleSheet>
            """,
            to: packageRoot.appendingPathComponent("xl/styles.xml")
        )

        let firstSheetData = includeCells ? """
            <row r="1">
              <c r="A1" t="s"><v>0</v></c>
              <c r="B1" t="inlineStr"><is><t>内联文本</t></is></c>
              <c r="C1" t="b"><v>1</v></c>
              <c r="D1" t="n"><v>42</v></c>
              <c r="E1" t="n"><f>D1*2</f><v>84</v></c>
              <c r="F1" t="d"><v>2026-08-19T00:00:00Z</v></c>
              <c r="G1" s="1"><v>46253</v></c>
            </row>
            <row r="100"><c r="Z100" t="s"><v>1</v></c></row>
        """ : ""
        try writeXML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <dimension ref="A1:Z100"/>
              <sheetData>\(firstSheetData)</sheetData>
            </worksheet>
            """,
            to: worksheets.appendingPathComponent("sheet1.xml")
        )
        let secondSheetData = includeCells ? "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>2</v></c></row>" : ""
        try writeXML(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <dimension ref="A1:A1"/>
              <sheetData>\(secondSheetData)</sheetData>
            </worksheet>
            """,
            to: worksheets.appendingPathComponent("sheet2.xml")
        )

        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipper.currentDirectoryURL = packageRoot
        zipper.arguments = ["-q", "-r", destination.path, "[Content_Types].xml", "_rels", "xl"]
        try zipper.run()
        zipper.waitUntilExit()
        XCTAssertEqual(zipper.terminationStatus, 0)
    }

    private func writeXML(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
