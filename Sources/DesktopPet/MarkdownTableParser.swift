import Foundation

enum MarkdownTableAlignment: Equatable {
    case left
    case center
    case right
}

struct MarkdownTableModel: Equatable {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
}

enum MarkdownContentSegment: Equatable {
    case text(String)
    case table(MarkdownTableModel)
}

enum MarkdownTableParser {
    static func parse(_ markdown: String) -> [MarkdownContentSegment] {
        let lines = markdown.components(separatedBy: "\n")
        var segments: [MarkdownContentSegment] = []
        var textLines: [String] = []
        var index = 0

        func flushText() {
            guard !textLines.isEmpty else { return }
            segments.append(.text(textLines.joined(separator: "\n")))
            textLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            guard index + 1 < lines.count,
                  let header = splitRow(lines[index]),
                  let alignments = delimiterAlignments(
                    for: lines[index + 1],
                    expectedColumnCount: header.count
                  )
            else {
                textLines.append(lines[index])
                index += 1
                continue
            }

            flushText()
            index += 2
            var rows: [[String]] = []
            while index < lines.count, let row = splitRow(lines[index]) {
                var normalized = Array(row.prefix(header.count))
                if normalized.count < header.count {
                    normalized.append(contentsOf: repeatElement("", count: header.count - normalized.count))
                }
                rows.append(normalized)
                index += 1
            }
            segments.append(.table(MarkdownTableModel(
                headers: header,
                alignments: alignments,
                rows: rows
            )))
        }

        flushText()
        return segments
    }

    private static func delimiterAlignments(
        for line: String,
        expectedColumnCount: Int
    ) -> [MarkdownTableAlignment]? {
        guard let cells = splitRow(line), cells.count == expectedColumnCount else { return nil }
        var result: [MarkdownTableAlignment] = []
        for cell in cells {
            let marker = cell.trimmingCharacters(in: .whitespaces)
            let leftColon = marker.hasPrefix(":")
            let rightColon = marker.hasSuffix(":")
            let hyphens = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard hyphens.count >= 3, hyphens.allSatisfy({ $0 == "-" }) else { return nil }
            if leftColon && rightColon {
                result.append(.center)
            } else if rightColon {
                result.append(.right)
            } else {
                result.append(.left)
            }
        }
        return result
    }

    private static func splitRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var cells = [""]
        var foundPipe = false
        let hasLeadingDelimiter = trimmed.first == "|"
        var lastWasDelimiter = false
        var codeDelimiterLength = 0
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character == "\\" {
                let next = trimmed.index(after: index)
                if next < trimmed.endIndex, trimmed[next] == "|" {
                    cells[cells.count - 1].append("|")
                    lastWasDelimiter = false
                    index = trimmed.index(after: next)
                    continue
                }
            }
            if character == "`" {
                var end = index
                var length = 0
                while end < trimmed.endIndex, trimmed[end] == "`" {
                    length += 1
                    end = trimmed.index(after: end)
                }
                if codeDelimiterLength == 0 {
                    codeDelimiterLength = length
                } else if codeDelimiterLength == length {
                    codeDelimiterLength = 0
                }
                cells[cells.count - 1].append(contentsOf: trimmed[index..<end])
                lastWasDelimiter = false
                index = end
                continue
            }
            if character == "|", codeDelimiterLength == 0 {
                foundPipe = true
                cells.append("")
                lastWasDelimiter = true
            } else {
                cells[cells.count - 1].append(character)
                lastWasDelimiter = false
            }
            index = trimmed.index(after: index)
        }

        guard foundPipe else { return nil }
        if hasLeadingDelimiter { cells.removeFirst() }
        if lastWasDelimiter { cells.removeLast() }
        guard !cells.isEmpty else { return nil }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
