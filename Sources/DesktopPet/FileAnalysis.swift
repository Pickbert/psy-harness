import AppKit
import CoreFoundation
import CoreXLSX
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum FileAnalysisLimits {
    static let defaultMaxFileSizeMB = 10
    static let minimumMaxFileSizeMB = 1
    static let maximumMaxFileSizeMB = 100
    static let maximumFileCount = 5
    static let maximumBatchBytes = 100 * 1_048_576
    static let maximumExtractedBytes = 100 * 1_048_576
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static let chunkCharacterCount = 8_000
    static let chunkOverlapCharacterCount = 500

    static func isValid(maxFileSizeMB value: Int) -> Bool {
        (minimumMaxFileSizeMB...maximumMaxFileSizeMB).contains(value)
    }

    static func normalized(maxFileSizeMB value: Int) -> Int {
        isValid(maxFileSizeMB: value) ? value : defaultMaxFileSizeMB
    }

    static func bytes(forMaxFileSizeMB value: Int) -> Int {
        normalized(maxFileSizeMB: value) * 1_048_576
    }
}

enum FileAnalysisError: LocalizedError, Equatable {
    case noFiles
    case tooManyFiles(Int)
    case notARegularFile(String)
    case unsupportedType(String)
    case fileTooLarge(name: String, limitMB: Int)
    case batchTooLarge
    case extractedTextTooLarge
    case unreadable(String)
    case lockedPDF(String)
    case scannedPDF(String)
    case protectedSpreadsheet(String)
    case invalidSpreadsheet(String)
    case emptySpreadsheet(String)
    case emptyDocument(String)
    case invalidSession

    var errorDescription: String? {
        switch self {
        case .noFiles:
            return "没有检测到可分析的文件。"
        case let .tooManyFiles(count):
            return "一次最多拖入 \(FileAnalysisLimits.maximumFileCount) 个文件，当前有 \(count) 个。"
        case let .notARegularFile(name):
            return "“\(name)”不是普通文件，暂不支持文件夹或特殊文件。"
        case let .unsupportedType(name):
            return "暂不支持“\(name)”的文件格式。"
        case let .fileTooLarge(name, limitMB):
            return "“\(name)”超过单份生涯资料 \(limitMB) MB 限制；可在职业咨询模型设置中修改。"
        case .batchTooLarge:
            return "这一批文件总大小超过 100 MB。"
        case .extractedTextTooLarge:
            return "这一批文件解析后的文字超过 100 MB，未创建不完整会话。"
        case let .unreadable(name):
            return "无法读取“\(name)”。"
        case let .lockedPDF(name):
            return "“\(name)”已加密或被密码保护，无法解析。"
        case let .scannedPDF(name):
            return "“\(name)”没有可提取文字，扫描版 PDF 暂不支持 OCR。"
        case let .protectedSpreadsheet(name):
            return "“\(name)”已加密或被密码保护，无法解析。"
        case let .invalidSpreadsheet(name):
            return "“\(name)”不是有效的 XLSX/XLSM 工作簿，或文件已经损坏。"
        case let .emptySpreadsheet(name):
            return "“\(name)”没有可分析的工作表单元格。"
        case let .emptyDocument(name):
            return "“\(name)”没有可分析的文字内容。"
        case .invalidSession:
            return "生涯资料分析会话已经失效，请重新拖入资料。"
        }
    }
}

struct FileAnalysisFileMetadata: Codable, Equatable {
    let displayName: String
    let kind: String
    let sourceRelativePath: String
    let normalizedRelativePath: String
    let chunkDirectoryRelativePath: String
    let sourceBytes: Int
    let extractedBytes: Int
    let chunkCount: Int
    let pageCount: Int?
    let sheetCount: Int?
}

struct FileAnalysisSessionMetadata: Codable, Equatable {
    let id: String
    var agentSessionID: String
    let createdAt: Date
    let expiresAt: Date
    let files: [FileAnalysisFileMetadata]
}

struct FileAnalysisSession: Equatable {
    let metadata: FileAnalysisSessionMetadata
    let sessionURL: URL

    var id: String { metadata.id }
    var agentSessionID: String { metadata.agentSessionID }
    var files: [FileAnalysisFileMetadata] { metadata.files }
    var displayNames: [String] { files.map(\.displayName) }
    var relativePath: String { "\(FileAnalysisSessionStore.directoryName)/\(id)" }
}

final class FileAnalysisSessionStore {
    static let directoryName = "DesktopPet-FileAnalysis"

    private static let activeSessionDefaultsKey = "desktopPetActiveFileAnalysisSessionID"
    private static let metadataFilename = ".desktop-pet-file-session.json"

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let legacyRootURL: URL
    private let now: () -> Date

    init(
        legacyRootURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.now = now
        self.legacyRootURL = legacyRootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("DesktopPet", isDirectory: true)
            .appendingPathComponent("FileSessions", isDirectory: true)
    }

    func createSession(
        from sourceURLs: [URL],
        in agentWorkspaceURL: URL,
        maxFileSizeMB: Int
    ) throws -> FileAnalysisSession {
        guard !sourceURLs.isEmpty else { throw FileAnalysisError.noFiles }
        guard sourceURLs.count <= FileAnalysisLimits.maximumFileCount else {
            throw FileAnalysisError.tooManyFiles(sourceURLs.count)
        }

        let normalizedLimitMB = FileAnalysisLimits.normalized(maxFileSizeMB: maxFileSizeMB)
        let maximumFileBytes = FileAnalysisLimits.bytes(forMaxFileSizeMB: normalizedLimitMB)
        let inputs = try validate(sourceURLs, maximumFileBytes: maximumFileBytes, limitMB: normalizedLimitMB)
        let rootURL = sessionRootURL(in: agentWorkspaceURL)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let identifier = UUID().uuidString.lowercased()
        let stagingURL = rootURL.appendingPathComponent(".staging-\(identifier)", isDirectory: true)
        let finalURL = rootURL.appendingPathComponent(identifier, isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            let session = try materializeSession(identifier: identifier, inputs: inputs, sessionURL: stagingURL)
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            let committed = FileAnalysisSession(metadata: session.metadata, sessionURL: finalURL)
            defaults.set(identifier, forKey: Self.activeSessionDefaultsKey)
            return committed
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    func activeSession(in agentWorkspaceURL: URL) -> FileAnalysisSession? {
        guard let identifier = defaults.string(forKey: Self.activeSessionDefaultsKey),
              UUID(uuidString: identifier) != nil
        else { return nil }
        let rootURL = sessionRootURL(in: agentWorkspaceURL)
        guard let session = loadSession(identifier: identifier, rootURL: rootURL),
              session.metadata.expiresAt > now()
        else {
            defaults.removeObject(forKey: Self.activeSessionDefaultsKey)
            return nil
        }
        return session
    }

    func replaceAgentSessionID(for session: FileAnalysisSession) throws -> FileAnalysisSession {
        var metadata = session.metadata
        metadata.agentSessionID = Self.makeAgentSessionID()
        try writeMetadata(metadata, in: session.sessionURL)
        return FileAnalysisSession(metadata: metadata, sessionURL: session.sessionURL)
    }

    func endActiveSession() {
        defaults.removeObject(forKey: Self.activeSessionDefaultsKey)
    }

    func cleanupExpiredSessions(in agentWorkspaceURL: URL) throws {
        let rootURL = sessionRootURL(in: agentWorkspaceURL)
        try cleanupExpiredSessions(at: rootURL)
        try cleanupExpiredSessions(at: legacyRootURL)
        if let activeID = defaults.string(forKey: Self.activeSessionDefaultsKey),
           !fileManager.fileExists(atPath: rootURL.appendingPathComponent(activeID).path) {
            defaults.removeObject(forKey: Self.activeSessionDefaultsKey)
        }
    }

    func clearCache(in agentWorkspaceURL: URL) throws {
        defaults.removeObject(forKey: Self.activeSessionDefaultsKey)
        try clearChildren(at: sessionRootURL(in: agentWorkspaceURL))
        try clearChildren(at: legacyRootURL)
    }

    private func cleanupExpiredSessions(at rootURL: URL) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )
        let referenceDate = now()
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            if isStagingDirectory(child) {
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                if modifiedAt.addingTimeInterval(FileAnalysisLimits.retentionInterval) <= referenceDate {
                    try fileManager.removeItem(at: child)
                }
                continue
            }
            let metadataURL = child.appendingPathComponent(Self.metadataFilename)
            guard let metadata = try? decodeMetadata(at: metadataURL),
                  metadata.id == child.lastPathComponent,
                  UUID(uuidString: metadata.id) != nil
            else { continue }
            if metadata.expiresAt <= referenceDate {
                try fileManager.removeItem(at: child)
            }
        }
    }

    private func clearChildren(at rootURL: URL) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        for child in try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            guard isStagingDirectory(child) || isCommittedSessionDirectory(child) else { continue }
            try fileManager.removeItem(at: child)
        }
    }

    private func isStagingDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(".staging-") else { return false }
        return UUID(uuidString: String(name.dropFirst(".staging-".count))) != nil
    }

    private func isCommittedSessionDirectory(_ url: URL) -> Bool {
        let identifier = url.lastPathComponent
        guard UUID(uuidString: identifier) != nil,
              let metadata = try? decodeMetadata(at: url.appendingPathComponent(Self.metadataFilename))
        else { return false }
        return metadata.id == identifier
    }

    private func sessionRootURL(in agentWorkspaceURL: URL) -> URL {
        agentWorkspaceURL.standardizedFileURL
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private struct ValidatedInput {
        let url: URL
        let displayName: String
        let kind: FileAnalysisDocumentKind
        let bytes: Int
    }

    private func validate(
        _ urls: [URL],
        maximumFileBytes: Int,
        limitMB: Int
    ) throws -> [ValidatedInput] {
        var result: [ValidatedInput] = []
        var totalBytes = 0
        for originalURL in urls {
            let url = originalURL.resolvingSymlinksInPath().standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let name = url.lastPathComponent
            guard values.isRegularFile == true else { throw FileAnalysisError.notARegularFile(name) }
            guard let kind = FileAnalysisDocumentKind(url: url) else {
                throw FileAnalysisError.unsupportedType(name)
            }
            let bytes = values.fileSize ?? 0
            guard bytes <= maximumFileBytes else {
                throw FileAnalysisError.fileTooLarge(name: name, limitMB: limitMB)
            }
            totalBytes += bytes
            guard totalBytes <= FileAnalysisLimits.maximumBatchBytes else {
                throw FileAnalysisError.batchTooLarge
            }
            result.append(ValidatedInput(url: url, displayName: name, kind: kind, bytes: bytes))
        }
        return result
    }

    private func materializeSession(
        identifier: String,
        inputs: [ValidatedInput],
        sessionURL: URL
    ) throws -> FileAnalysisSession {
        let sourceDirectory = sessionURL.appendingPathComponent("sources", isDirectory: true)
        let normalizedDirectory = sessionURL.appendingPathComponent("normalized", isDirectory: true)
        let chunksDirectory = sessionURL.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: normalizedDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        var usedNames = Set<String>()
        var totalExtractedBytes = 0
        var files: [FileAnalysisFileMetadata] = []
        for (index, input) in inputs.enumerated() {
            let safeName = uniqueFilename(input.displayName, usedNames: &usedNames)
            let sourceURL = sourceDirectory.appendingPathComponent(safeName)
            let accessed = input.url.startAccessingSecurityScopedResource()
            defer { if accessed { input.url.stopAccessingSecurityScopedResource() } }
            do {
                try fileManager.copyItem(at: input.url, to: sourceURL)
            } catch {
                throw FileAnalysisError.unreadable(input.displayName)
            }
            let extracted = try FileAnalysisExtractor.extract(
                sourceURL: sourceURL,
                displayName: input.displayName,
                kind: input.kind
            )
            let extractedBytes = extracted.text.lengthOfBytes(using: .utf8)
            totalExtractedBytes += extractedBytes
            guard totalExtractedBytes <= FileAnalysisLimits.maximumExtractedBytes else {
                throw FileAnalysisError.extractedTextTooLarge
            }

            let stem = String(format: "%02d-%@", index + 1, Self.safeStem(safeName))
            let normalizedURL = normalizedDirectory.appendingPathComponent("\(stem).md")
            try extracted.text.write(to: normalizedURL, atomically: true, encoding: .utf8)

            let chunks = FileAnalysisExtractor.chunk(extracted.text)
            let fileChunksDirectory = chunksDirectory.appendingPathComponent(stem, isDirectory: true)
            try fileManager.createDirectory(at: fileChunksDirectory, withIntermediateDirectories: true)
            for (chunkIndex, chunk) in chunks.enumerated() {
                let chunkURL = fileChunksDirectory.appendingPathComponent(
                    String(format: "chunk-%04d.md", chunkIndex + 1)
                )
                let header = """
                # \(input.displayName)

                - 片段：\(chunkIndex + 1)/\(chunks.count)
                - 来源类型：\(input.kind.displayName)
                - 标准化文件：normalized/\(stem).md
                - 标准化文本行：\(chunk.startLine)-\(chunk.endLine)

                """
                try (header + chunk.text).write(to: chunkURL, atomically: true, encoding: .utf8)
            }

            files.append(FileAnalysisFileMetadata(
                displayName: input.displayName,
                kind: input.kind.rawValue,
                sourceRelativePath: "sources/\(safeName)",
                normalizedRelativePath: "normalized/\(stem).md",
                chunkDirectoryRelativePath: "chunks/\(stem)",
                sourceBytes: input.bytes,
                extractedBytes: extractedBytes,
                chunkCount: chunks.count,
                pageCount: extracted.pageCount,
                sheetCount: extracted.sheetCount
            ))
        }

        let createdAt = now()
        let metadata = FileAnalysisSessionMetadata(
            id: identifier,
            agentSessionID: Self.makeAgentSessionID(),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(FileAnalysisLimits.retentionInterval),
            files: files
        )
        try writeManifest(metadata, in: sessionURL)
        try writeMetadata(metadata, in: sessionURL)
        return FileAnalysisSession(metadata: metadata, sessionURL: sessionURL)
    }

    private func loadSession(identifier: String, rootURL: URL) -> FileAnalysisSession? {
        let sessionURL = rootURL.appendingPathComponent(identifier, isDirectory: true)
        guard let metadata = try? decodeMetadata(
            at: sessionURL.appendingPathComponent(Self.metadataFilename)
        ), metadata.id == identifier else { return nil }
        return FileAnalysisSession(metadata: metadata, sessionURL: sessionURL)
    }

    private func writeMetadata(_ metadata: FileAnalysisSessionMetadata, in sessionURL: URL) throws {
        let data = try JSONEncoder.desktopPet.encode(metadata)
        try data.write(
            to: sessionURL.appendingPathComponent(Self.metadataFilename),
            options: .atomic
        )
    }

    private func decodeMetadata(at url: URL) throws -> FileAnalysisSessionMetadata {
        try JSONDecoder.desktopPet.decode(FileAnalysisSessionMetadata.self, from: Data(contentsOf: url))
    }

    private func writeManifest(_ metadata: FileAnalysisSessionMetadata, in sessionURL: URL) throws {
        var lines = [
            "# 哈妮丝生涯资料分析会话",
            "",
            "这是一份由用户主动拖入文件后建立的隔离副本。请优先使用 `glob`、`grep` 和 `read` 检索 `chunks/`，需要连续上下文时再读取 `normalized/`。不要猜测未解析的图片内容。",
            "",
            "## 文件"
        ]
        for file in metadata.files {
            var details = "- **\(file.displayName)**（\(file.kind)，\(file.sourceBytes) bytes，\(file.chunkCount) 个片段"
            if let pageCount = file.pageCount { details += "，\(pageCount) 页" }
            if let sheetCount = file.sheetCount { details += "，\(sheetCount) 个工作表" }
            details += "）"
            lines.append(details)
            lines.append("  - 标准化文本：`\(file.normalizedRelativePath)`")
            lines.append("  - 检索片段：`\(file.chunkDirectoryRelativePath)/*.md`")
            lines.append("  - 隔离副本：`\(file.sourceRelativePath)`")
        }
        lines.append("")
        if metadata.files.contains(where: { $0.kind == FileAnalysisDocumentKind.spreadsheet.rawValue }) {
            lines.append("Excel 仅提取工作表中的单元格值、公式文本与文件内缓存结果；不会重新计算公式，缓存值可能已经过期，也不会执行宏或还原图表、图片、数据透视表和视觉样式。")
            lines.append("")
        }
        lines.append("回答时尽量引用文件名、PDF 页码、Excel 工作表与单元格坐标或标准化文本中的行号。")
        let manifestURL = sessionURL.appendingPathComponent("manifest.md")
        try lines.joined(separator: "\n").write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    private func uniqueFilename(_ filename: String, usedNames: inout Set<String>) -> String {
        let sanitized = filename.replacingOccurrences(of: ":", with: "-")
        let ext = (sanitized as NSString).pathExtension
        let base = (sanitized as NSString).deletingPathExtension
        var candidate = sanitized
        var suffix = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            suffix += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    private static func safeStem(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = base.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : Character("-")
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "file" : value
    }

    private static func makeAgentSessionID() -> String {
        "desktop-pet-file-\(UUID().uuidString.lowercased())"
    }
}

private enum FileAnalysisDocumentKind: String {
    case pdf
    case docx
    case spreadsheet
    case text

    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            self = .pdf
        } else if ext == "docx" {
            self = .docx
        } else if ext == "xlsx" || ext == "xlsm" {
            self = .spreadsheet
        } else if Self.textExtensions.contains(ext)
                    || Self.extensionlessTextNames.contains(url.lastPathComponent.lowercased())
                    || UTType(filenameExtension: ext)?.conforms(to: .text) == true {
            self = .text
        } else {
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "DOCX"
        case .spreadsheet: return "Excel"
        case .text: return "文本"
        }
    }

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "json", "jsonl", "yaml", "yml", "xml", "html", "htm",
        "log", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts",
        "py", "pyi", "js", "jsx", "ts", "tsx", "vue", "svelte", "go", "rs", "rb", "php",
        "sh", "bash", "zsh", "fish", "sql", "css", "scss", "less", "toml", "ini", "conf",
        "properties", "gradle", "cmake", "dockerfile"
    ]

    private static let extensionlessTextNames: Set<String> = [
        "makefile", "dockerfile", "readme", "license", "gemfile", "podfile"
    ]
}

private enum FileAnalysisExtractor {
    struct ExtractedDocument {
        let text: String
        let pageCount: Int?
        let sheetCount: Int?
    }

    struct Chunk {
        let text: String
        let startLine: Int
        let endLine: Int
    }

    static func extract(
        sourceURL: URL,
        displayName: String,
        kind: FileAnalysisDocumentKind
    ) throws -> ExtractedDocument {
        switch kind {
        case .pdf:
            return try extractPDF(sourceURL, displayName: displayName)
        case .docx:
            return try extractDOCX(sourceURL, displayName: displayName)
        case .spreadsheet:
            return try extractSpreadsheet(sourceURL, displayName: displayName)
        case .text:
            return try extractText(sourceURL, displayName: displayName)
        }
    }

    static func chunk(_ text: String) -> [Chunk] {
        guard text.count > FileAnalysisLimits.chunkCharacterCount else {
            let endLine = 1 + text.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            return [Chunk(text: text, startLine: 1, endLine: endLine)]
        }
        var result: [Chunk] = []
        var start = text.startIndex
        var startLine = 1
        while start < text.endIndex {
            let proposedEnd = text.index(
                start,
                offsetBy: FileAnalysisLimits.chunkCharacterCount,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            var end = proposedEnd
            if proposedEnd < text.endIndex,
               let newline = text[start..<proposedEnd].lastIndex(of: "\n"),
               text.distance(from: start, to: newline) >= FileAnalysisLimits.chunkCharacterCount / 2 {
                end = text.index(after: newline)
            }
            let chunkText = String(text[start..<end])
            let endLine = startLine + chunkText.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            result.append(Chunk(text: chunkText, startLine: startLine, endLine: endLine))
            guard end < text.endIndex else { break }
            let overlapStart = text.index(
                end,
                offsetBy: -FileAnalysisLimits.chunkOverlapCharacterCount,
                limitedBy: start
            ) ?? start
            let overlapLineBreaks = text[overlapStart..<end].reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            startLine = endLine - overlapLineBreaks
            start = overlapStart > start ? overlapStart : end
        }
        return result
    }

    private static func extractPDF(_ url: URL, displayName: String) throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else { throw FileAnalysisError.unreadable(displayName) }
        guard !document.isLocked else { throw FileAnalysisError.lockedPDF(displayName) }
        var sections: [String] = []
        var hasText = false
        for index in 0..<document.pageCount {
            let pageText = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pageText.isEmpty { hasText = true }
            sections.append("## PDF 第 \(index + 1) 页\n\n\(pageText)")
        }
        guard hasText else { throw FileAnalysisError.scannedPDF(displayName) }
        return ExtractedDocument(
            text: "# \(displayName)\n\n" + sections.joined(separator: "\n\n---\n\n"),
            pageCount: document.pageCount,
            sheetCount: nil
        )
    }

    private static func extractDOCX(_ url: URL, displayName: String) throws -> ExtractedDocument {
        do {
            let attributed = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil
            )
            let text = normalizeNewlines(attributed.string).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw FileAnalysisError.emptyDocument(displayName) }
            return ExtractedDocument(text: "# \(displayName)\n\n\(text)", pageCount: nil, sheetCount: nil)
        } catch let error as FileAnalysisError {
            throw error
        } catch {
            throw FileAnalysisError.unreadable(displayName)
        }
    }

    private static func extractText(_ url: URL, displayName: String) throws -> ExtractedDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FileAnalysisError.unreadable(displayName)
        }
        guard let decoded = decodeText(data) else { throw FileAnalysisError.unreadable(displayName) }
        let text = normalizeNewlines(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FileAnalysisError.emptyDocument(displayName) }
        return ExtractedDocument(text: "# \(displayName)\n\n\(text)", pageCount: nil, sheetCount: nil)
    }

    private static func extractSpreadsheet(_ url: URL, displayName: String) throws -> ExtractedDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FileAnalysisError.unreadable(displayName)
        }
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            throw FileAnalysisError.protectedSpreadsheet(displayName)
        }

        let file: XLSXFile
        do {
            file = try XLSXFile(data: data)
        } catch {
            throw FileAnalysisError.invalidSpreadsheet(displayName)
        }

        do {
            let sharedStrings = try file.parseSharedStrings()
            let styles = try? file.parseStyles()
            let workbooks = try file.parseWorkbooks()
            var builder = SpreadsheetTextBuilder()
            try builder.append("# \(displayName)\n\n")
            try builder.append("> XLSX/XLSM 只读提取；公式不会重新计算，value 列是文件内保存的缓存结果。宏不会执行。\n")

            var sheetCount = 0
            var populatedCellCount = 0
            for workbook in workbooks {
                for (index, item) in try file.parseWorksheetPathsAndNames(workbook: workbook).enumerated() {
                    let worksheet = try file.parseWorksheet(at: item.path)
                    let sheetName = item.name ?? "Sheet \(index + 1)"
                    sheetCount += 1
                    try builder.append("\n## 工作表：\(escapeMarkdownHeading(sheetName))\n\n")
                    if let reference = worksheet.dimension?.reference {
                        try builder.append("- 使用区域：`\(reference)`\n\n")
                    }
                    try builder.append("```tsv\ncell\ttype\tvalue\tformula\n")
                    for row in worksheet.data?.rows ?? [] {
                        for cell in row.cells {
                            let rendered = spreadsheetCell(
                                cell,
                                sharedStrings: sharedStrings,
                                styles: styles
                            )
                            let formula = cell.formula?.value ?? ""
                            guard !rendered.value.isEmpty || !formula.isEmpty else { continue }
                            populatedCellCount += 1
                            try builder.append(
                                "\(cell.reference)\t\(escapeTSV(rendered.type))\t\(escapeTSV(rendered.value))\t\(escapeTSV(formula))\n"
                            )
                        }
                    }
                    try builder.append("```\n")
                }
            }
            guard sheetCount > 0, populatedCellCount > 0 else {
                throw FileAnalysisError.emptySpreadsheet(displayName)
            }
            return ExtractedDocument(text: builder.text, pageCount: nil, sheetCount: sheetCount)
        } catch let error as FileAnalysisError {
            throw error
        } catch {
            throw FileAnalysisError.invalidSpreadsheet(displayName)
        }
    }

    private static func spreadsheetCell(
        _ cell: Cell,
        sharedStrings: SharedStrings?,
        styles: Styles?
    ) -> (type: String, value: String) {
        if cell.type == .sharedString,
           let index = cell.value.flatMap(Int.init),
           let sharedStrings,
           sharedStrings.items.indices.contains(index) {
            let item = sharedStrings.items[index]
            return (cell.type?.rawValue ?? "string", item.text ?? item.richText.compactMap(\.text).joined())
        }
        if cell.type == .inlineStr {
            return (cell.type?.rawValue ?? "string", cell.inlineString?.text ?? cell.value ?? "")
        }
        if cell.type == .bool {
            switch cell.value {
            case "0": return (cell.type?.rawValue ?? "boolean", "FALSE")
            case "1": return (cell.type?.rawValue ?? "boolean", "TRUE")
            default: break
            }
        }
        if cell.type == .date, let raw = cell.value,
           let date = ISO8601DateFormatter().date(from: raw) {
            return ("date", ISO8601DateFormatter().string(from: date))
        }
        if let styles, isDateFormatted(cell, styles: styles), let date = cell.dateValue {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return ("date", formatter.string(from: date))
        }
        return (cell.type?.rawValue ?? "number", cell.value ?? "")
    }

    private static func isDateFormatted(_ cell: Cell, styles: Styles) -> Bool {
        guard let numberFormatID = cell.format(in: styles)?.numberFormatId else { return false }
        let builtInDateFormats = 14...22
        let builtInEastAsianDateFormats = 27...36
        let builtInTimeFormats = 45...47
        let builtInAdditionalDateFormats = 50...58
        if builtInDateFormats.contains(numberFormatID)
            || builtInEastAsianDateFormats.contains(numberFormatID)
            || builtInTimeFormats.contains(numberFormatID)
            || builtInAdditionalDateFormats.contains(numberFormatID) {
            return true
        }
        guard let code = styles.numberFormats?.items.first(where: { $0.id == numberFormatID })?.formatCode else {
            return false
        }
        let normalized = stripNumberFormatLiterals(code).lowercased()
        return normalized.contains("y")
            || normalized.contains("d")
            || normalized.contains("h")
            || normalized.contains("s")
            || normalized.contains("am/pm")
    }

    private static func stripNumberFormatLiterals(_ format: String) -> String {
        var result = ""
        var isQuoted = false
        var isEscaped = false
        var bracketed = ""
        for character in format {
            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\" || character == "_" || character == "*" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                isQuoted.toggle()
                continue
            }
            guard !isQuoted else { continue }
            if character == "[" {
                bracketed = "["
                continue
            }
            if !bracketed.isEmpty {
                bracketed.append(character)
                if character == "]" {
                    let token = bracketed.dropFirst().dropLast().lowercased()
                    if ["h", "hh", "m", "mm", "s", "ss"].contains(token) {
                        result.append(contentsOf: token)
                    }
                    bracketed = ""
                }
                continue
            }
            result.append(character)
        }
        return result
    }

    private static func escapeTSV(_ value: String) -> String {
        normalizeNewlines(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func escapeMarkdownHeading(_ value: String) -> String {
        normalizeNewlines(value).replacingOccurrences(of: "\n", with: " ")
    }

    private struct SpreadsheetTextBuilder {
        private(set) var text = ""
        private var byteCount = 0

        mutating func append(_ value: String) throws {
            byteCount += value.lengthOfBytes(using: .utf8)
            guard byteCount <= FileAnalysisLimits.maximumExtractedBytes else {
                throw FileAnalysisError.extractedTextTooLarge
            }
            text.append(value)
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
        ]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.unicodeScalars.contains(where: { $0.value == 0 }) {
                return text
            }
        }
        return nil
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

private extension JSONEncoder {
    static var desktopPet: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var desktopPet: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
