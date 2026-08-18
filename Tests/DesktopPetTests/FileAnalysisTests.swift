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
        try withStore { store, inputRoot, sessionRoot, _ in
            let original = inputRoot.appendingPathComponent("研究笔记.md")
            let text = String(repeating: "机器人供应链：电机、减速器、传感器。\n", count: 700)
            try text.write(to: original, atomically: true, encoding: .utf8)
            let originalHash = try sha256(original)

            let session = try store.createSession(from: [original], maxFileSizeMB: 10)

            XCTAssertEqual(session.displayNames, ["研究笔记.md"])
            XCTAssertGreaterThan(session.files[0].chunkCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.workspaceURL.appendingPathComponent("manifest.md").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.workspaceURL.appendingPathComponent(session.files[0].normalizedRelativePath).path))
            let firstChunk = session.workspaceURL
                .appendingPathComponent(session.files[0].chunkDirectoryRelativePath)
                .appendingPathComponent("chunk-0001.md")
            XCTAssertTrue(try String(contentsOf: firstChunk, encoding: .utf8).contains("标准化文本行：1-"))
            XCTAssertEqual(try sha256(original), originalHash)
            let manifest = try String(contentsOf: session.workspaceURL.appendingPathComponent("manifest.md"), encoding: .utf8)
            XCTAssertFalse(manifest.contains(inputRoot.path))
            XCTAssertEqual(store.activeSession()?.id, session.id)
            XCTAssertTrue(session.workspaceURL.path.hasPrefix(sessionRoot.path))
        }
    }

    func testRejectsMoreThanFiveFilesAndOversizedSingleFile() throws {
        try withStore { store, inputRoot, _, _ in
            let sixFiles = try (0..<6).map { index -> URL in
                let url = inputRoot.appendingPathComponent("\(index).txt")
                try "ok".write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            XCTAssertThrowsError(try store.createSession(from: sixFiles, maxFileSizeMB: 10)) {
                XCTAssertEqual($0 as? FileAnalysisError, .tooManyFiles(6))
            }

            let large = inputRoot.appendingPathComponent("large.txt")
            FileManager.default.createFile(atPath: large.path, contents: nil)
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: UInt64(1_048_577))
            try handle.close()
            XCTAssertThrowsError(try store.createSession(from: [large], maxFileSizeMB: 1)) {
                XCTAssertEqual($0 as? FileAnalysisError, .fileTooLarge(name: "large.txt", limitMB: 1))
            }
        }
    }

    func testRejectsBatchAboveOneHundredMiBBeforeExtraction() throws {
        try withStore { store, inputRoot, _, _ in
            let files = try (0..<2).map { index -> URL in
                let url = inputRoot.appendingPathComponent("large-\(index).txt")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(51 * 1_048_576))
                try handle.close()
                return url
            }
            XCTAssertThrowsError(try store.createSession(from: files, maxFileSizeMB: 100)) {
                XCTAssertEqual($0 as? FileAnalysisError, .batchTooLarge)
            }
        }
    }

    func testDuplicateNamesAreIsolatedAndExpiredSessionsAreCleaned() throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        try withStore(now: { clock }) { store, inputRoot, _, _ in
            let firstDirectory = inputRoot.appendingPathComponent("one", isDirectory: true)
            let secondDirectory = inputRoot.appendingPathComponent("two", isDirectory: true)
            try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
            let first = firstDirectory.appendingPathComponent("report.txt")
            let second = secondDirectory.appendingPathComponent("report.txt")
            try "first".write(to: first, atomically: true, encoding: .utf8)
            try "second".write(to: second, atomically: true, encoding: .utf8)

            let session = try store.createSession(from: [first, second], maxFileSizeMB: 10)
            XCTAssertEqual(session.files.map(\.sourceRelativePath), ["sources/report.txt", "sources/report-2.txt"])

            clock = clock.addingTimeInterval(FileAnalysisLimits.retentionInterval + 1)
            try store.cleanupExpiredSessions()
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.workspaceURL.path))
            XCTAssertNil(store.activeSession())
        }
    }

    func testPDFAndDOCXAreNormalizedLocally() throws {
        try withStore { store, inputRoot, _, _ in
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

            let session = try store.createSession(from: [pdfURL, docxURL], maxFileSizeMB: 10)
            let normalized = try session.files.map {
                try String(contentsOf: session.workspaceURL.appendingPathComponent($0.normalizedRelativePath), encoding: .utf8)
            }
            XCTAssertTrue(normalized[0].contains("PDF 第 1 页"))
            XCTAssertTrue(normalized[1].contains("DOCX 段落内容"))
        }
    }

    private func withStore(
        now: @escaping () -> Date = Date.init,
        _ body: (FileAnalysisSessionStore, URL, URL, UserDefaults) throws -> Void
    ) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopPetFileAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        let inputRoot = base.appendingPathComponent("input", isDirectory: true)
        let sessionRoot = base.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let suiteName = "FileAnalysisStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FileAnalysisSessionStore(rootURL: sessionRoot, defaults: defaults, now: now)
        try body(store, inputRoot, sessionRoot, defaults)
    }

    private func sha256(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }
}
