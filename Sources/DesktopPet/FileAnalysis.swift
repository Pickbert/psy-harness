import AppKit
import CoreFoundation
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
            return "“\(name)”超过单文件 \(limitMB) MB 限制；可在 DeepSeek 设置中修改。"
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
        case let .emptyDocument(name):
            return "“\(name)”没有可分析的文字内容。"
        case .invalidSession:
            return "文件分析会话已经失效，请重新拖入文件。"
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
    let workspaceURL: URL

    var id: String { metadata.id }
    var agentSessionID: String { metadata.agentSessionID }
    var files: [FileAnalysisFileMetadata] { metadata.files }
    var displayNames: [String] { files.map(\.displayName) }
}

final class FileAnalysisSessionStore {
    private static let activeSessionDefaultsKey = "desktopPetActiveFileAnalysisSessionID"
    private static let metadataFilename = ".desktop-pet-file-session.json"

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let rootURL: URL
    private let now: () -> Date

    init(
        rootURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.now = now
        self.rootURL = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("DesktopPet", isDirectory: true)
            .appendingPathComponent("FileSessions", isDirectory: true)
    }

    func createSession(from sourceURLs: [URL], maxFileSizeMB: Int) throws -> FileAnalysisSession {
        guard !sourceURLs.isEmpty else { throw FileAnalysisError.noFiles }
        guard sourceURLs.count <= FileAnalysisLimits.maximumFileCount else {
            throw FileAnalysisError.tooManyFiles(sourceURLs.count)
        }

        let normalizedLimitMB = FileAnalysisLimits.normalized(maxFileSizeMB: maxFileSizeMB)
        let maximumFileBytes = FileAnalysisLimits.bytes(forMaxFileSizeMB: normalizedLimitMB)
        let inputs = try validate(sourceURLs, maximumFileBytes: maximumFileBytes, limitMB: normalizedLimitMB)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let identifier = UUID().uuidString.lowercased()
        let stagingURL = rootURL.appendingPathComponent(".staging-\(identifier)", isDirectory: true)
        let finalURL = rootURL.appendingPathComponent(identifier, isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            let session = try materializeSession(identifier: identifier, inputs: inputs, workspaceURL: stagingURL)
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            let committed = FileAnalysisSession(metadata: session.metadata, workspaceURL: finalURL)
            defaults.set(identifier, forKey: Self.activeSessionDefaultsKey)
            return committed
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    func activeSession() -> FileAnalysisSession? {
        guard let identifier = defaults.string(forKey: Self.activeSessionDefaultsKey) else { return nil }
        guard let session = loadSession(identifier: identifier), session.metadata.expiresAt > now() else {
            defaults.removeObject(forKey: Self.activeSessionDefaultsKey)
            return nil
        }
        return session
    }

    func replaceAgentSessionID(for session: FileAnalysisSession) throws -> FileAnalysisSession {
        var metadata = session.metadata
        metadata.agentSessionID = Self.makeAgentSessionID()
        try writeMetadata(metadata, in: session.workspaceURL)
        return FileAnalysisSession(metadata: metadata, workspaceURL: session.workspaceURL)
    }

    func endActiveSession() {
        defaults.removeObject(forKey: Self.activeSessionDefaultsKey)
    }

    func cleanupExpiredSessions() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )
        let referenceDate = now()
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let metadataURL = child.appendingPathComponent(Self.metadataFilename)
            let metadata = try? decodeMetadata(at: metadataURL)
            if metadata?.expiresAt ?? .distantPast <= referenceDate {
                try fileManager.removeItem(at: child)
            }
        }
        if let activeID = defaults.string(forKey: Self.activeSessionDefaultsKey),
           !fileManager.fileExists(atPath: rootURL.appendingPathComponent(activeID).path) {
            defaults.removeObject(forKey: Self.activeSessionDefaultsKey)
        }
    }

    func clearCache() throws {
        defaults.removeObject(forKey: Self.activeSessionDefaultsKey)
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        for child in try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: child)
        }
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
        workspaceURL: URL
    ) throws -> FileAnalysisSession {
        let sourceDirectory = workspaceURL.appendingPathComponent("sources", isDirectory: true)
        let normalizedDirectory = workspaceURL.appendingPathComponent("normalized", isDirectory: true)
        let chunksDirectory = workspaceURL.appendingPathComponent("chunks", isDirectory: true)
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
                pageCount: extracted.pageCount
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
        try writeManifest(metadata, in: workspaceURL)
        try writeMetadata(metadata, in: workspaceURL)
        return FileAnalysisSession(metadata: metadata, workspaceURL: workspaceURL)
    }

    private func loadSession(identifier: String) -> FileAnalysisSession? {
        let workspaceURL = rootURL.appendingPathComponent(identifier, isDirectory: true)
        guard let metadata = try? decodeMetadata(
            at: workspaceURL.appendingPathComponent(Self.metadataFilename)
        ), metadata.id == identifier else { return nil }
        return FileAnalysisSession(metadata: metadata, workspaceURL: workspaceURL)
    }

    private func writeMetadata(_ metadata: FileAnalysisSessionMetadata, in workspaceURL: URL) throws {
        let data = try JSONEncoder.desktopPet.encode(metadata)
        try data.write(
            to: workspaceURL.appendingPathComponent(Self.metadataFilename),
            options: .atomic
        )
    }

    private func decodeMetadata(at url: URL) throws -> FileAnalysisSessionMetadata {
        try JSONDecoder.desktopPet.decode(FileAnalysisSessionMetadata.self, from: Data(contentsOf: url))
    }

    private func writeManifest(_ metadata: FileAnalysisSessionMetadata, in workspaceURL: URL) throws {
        var lines = [
            "# 桌面小柴文件分析会话",
            "",
            "这是一份由用户主动拖入文件后建立的隔离副本。请优先使用 `glob`、`grep` 和 `read` 检索 `chunks/`，需要连续上下文时再读取 `normalized/`。不要猜测未解析的图片内容。",
            "",
            "## 文件"
        ]
        for file in metadata.files {
            var details = "- **\(file.displayName)**（\(file.kind)，\(file.sourceBytes) bytes，\(file.chunkCount) 个片段"
            if let pageCount = file.pageCount { details += "，\(pageCount) 页" }
            details += "）"
            lines.append(details)
            lines.append("  - 标准化文本：`\(file.normalizedRelativePath)`")
            lines.append("  - 检索片段：`\(file.chunkDirectoryRelativePath)/*.md`")
            lines.append("  - 隔离副本：`\(file.sourceRelativePath)`")
        }
        lines.append("")
        lines.append("回答时尽量引用文件名、PDF 页码或标准化文本中的行号。")
        let manifestURL = workspaceURL.appendingPathComponent("manifest.md")
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
    case text

    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            self = .pdf
        } else if ext == "docx" {
            self = .docx
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
            pageCount: document.pageCount
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
            return ExtractedDocument(text: "# \(displayName)\n\n\(text)", pageCount: nil)
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
        return ExtractedDocument(text: "# \(displayName)\n\n\(text)", pageCount: nil)
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
