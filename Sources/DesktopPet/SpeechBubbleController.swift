import AppKit

final class SpeechBubbleController {
    private let panel: NSPanel
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let toolStatusBar = NSView()
    private let toolProgressIndicator = NSProgressIndicator()
    private let toolStatusLabel = NSTextField(labelWithString: "")
    private var isToolStatusVisible = false
    private var prefersWideLayout = false

    init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let container = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.material = .popover
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        scrollView = NSScrollView(frame: container.bounds.insetBy(dx: 14, dy: 12))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = CGSize(width: 3, height: 3)
        textView.font = .systemFont(ofSize: 15, weight: .medium)
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        toolStatusBar.isHidden = true
        toolProgressIndicator.style = .spinning
        toolProgressIndicator.controlSize = .small
        toolProgressIndicator.isDisplayedWhenStopped = false
        toolProgressIndicator.frame = CGRect(x: 0, y: 2, width: 16, height: 16)
        toolStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        toolStatusLabel.textColor = .secondaryLabelColor
        toolStatusLabel.lineBreakMode = .byTruncatingTail
        toolStatusBar.addSubview(toolProgressIndicator)
        toolStatusBar.addSubview(toolStatusLabel)

        container.addSubview(scrollView)
        container.addSubview(toolStatusBar)
        panel.contentView = container
        layoutContent()
    }

    var isVisible: Bool { panel.isVisible }

    func show(text: String, anchoredTo anchorWindow: NSWindow, followLatest: Bool = false) {
        let segments = MarkdownTableParser.parse(text)
        prefersWideLayout = segments.contains { segment in
            if case .table = segment { return true }
            return false
        }
        let renderedText = renderMarkdown(segments)
        textView.textStorage?.setAttributedString(renderedText)
        resize(for: renderedText)
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        if followLatest {
            textView.scrollToEndOfDocument(nil)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
        reposition(anchoredTo: anchorWindow)
        panel.orderFrontRegardless()
    }

    func setToolStatus(
        _ text: String?,
        isRunning: Bool,
        anchoredTo anchorWindow: NSWindow
    ) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isToolStatusVisible = !normalized.isEmpty
        toolStatusBar.isHidden = !isToolStatusVisible
        toolStatusLabel.stringValue = normalized
        toolProgressIndicator.isHidden = !isRunning
        if isRunning {
            toolProgressIndicator.startAnimation(nil)
        } else {
            toolProgressIndicator.stopAnimation(nil)
        }
        let currentText = textView.textStorage.map(NSAttributedString.init(attributedString:))
            ?? NSAttributedString(string: textView.string)
        resize(for: currentText)
        reposition(anchoredTo: anchorWindow)
        if isToolStatusVisible { panel.orderFrontRegardless() }
    }

    func reposition(anchoredTo anchorWindow: NSWindow) {
        guard panel.isVisible || !textView.string.isEmpty || isToolStatusVisible else { return }
        let anchor = anchorWindow.frame
        let screenFrame = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        var x = anchor.midX - panel.frame.width / 2
        var y = anchor.maxY + 10
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - panel.frame.width - 8)
        if y + panel.frame.height > screenFrame.maxY {
            y = max(screenFrame.minY + 8, anchor.minY - panel.frame.height - 10)
        }
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func hide() {
        panel.orderOut(nil)
        textView.string = ""
        isToolStatusVisible = false
        prefersWideLayout = false
        toolStatusBar.isHidden = true
        toolProgressIndicator.stopAnimation(nil)
    }

    func renderMarkdown(_ segments: [MarkdownContentSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            switch segment {
            case let .text(markdown):
                result.append(renderTextMarkdown(markdown))
            case let .table(table):
                result.append(renderTable(table))
            }
        }
        return result
    }

    private func renderTextMarkdown(_ markdown: String) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let parsed = (try? AttributedString(markdown: markdown, options: options))
            .map(NSAttributedString.init) ?? NSAttributedString(string: markdown)
        let result = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: result.length)
        let baseFont = NSFont.systemFont(ofSize: 15, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 5
        result.addAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ], range: fullRange)

        let inlineIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")
        var inlineRuns: [(NSRange, Int)] = []
        result.enumerateAttribute(inlineIntentKey, in: fullRange) { value, range, _ in
            if let number = value as? NSNumber {
                inlineRuns.append((range, number.intValue))
            }
        }
        for (range, intent) in inlineRuns {
            var font = baseFont
            if intent & 1 != 0 {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent & 2 != 0 {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if intent & 4 != 0 {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
            }
            if intent & 8 != 0 {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.addAttributes(attributes, range: range)
        }

        enum BlockStyle {
            case heading(Int)
            case bullet
            case quote
        }
        struct Block {
            let lineRange: NSRange
            let prefixLength: Int
            let style: BlockStyle
        }

        var blocks: [Block] = []
        var location = 0
        for line in result.string.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineLength = (String(line) as NSString).length
            let value = String(line)
            let hashes = value.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, value.dropFirst(hashes).hasPrefix(" ") {
                blocks.append(Block(
                    lineRange: NSRange(location: location, length: lineLength),
                    prefixLength: hashes + 1,
                    style: .heading(hashes)
                ))
            } else if value.hasPrefix("- ") || value.hasPrefix("* ") || value.hasPrefix("+ ") {
                blocks.append(Block(
                    lineRange: NSRange(location: location, length: lineLength),
                    prefixLength: 2,
                    style: .bullet
                ))
            } else if value.hasPrefix("> ") {
                blocks.append(Block(
                    lineRange: NSRange(location: location, length: lineLength),
                    prefixLength: 2,
                    style: .quote
                ))
            }
            location += lineLength + 1
        }

        for block in blocks.reversed() {
            let prefixRange = NSRange(location: block.lineRange.location, length: block.prefixLength)
            switch block.style {
            case let .heading(level):
                result.deleteCharacters(in: prefixRange)
                let contentRange = NSRange(
                    location: block.lineRange.location,
                    length: block.lineRange.length - block.prefixLength
                )
                let size = max(16, 22 - CGFloat(level - 1))
                result.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: size, weight: .bold),
                    range: contentRange
                )
            case .bullet:
                result.replaceCharacters(in: prefixRange, with: "• ")
            case .quote:
                result.replaceCharacters(in: prefixRange, with: "▌ ")
                result.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: block.lineRange
                )
            }
        }

        return result
    }

    private func renderTable(_ model: MarkdownTableModel) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = model.headers.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        let columnWidth = 100 / CGFloat(model.headers.count)

        let rows = [model.headers] + model.rows
        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0..<model.headers.count {
                let rawValue = columnIndex < row.count ? row[columnIndex] : ""
                let cell = renderTextMarkdown(rawValue.isEmpty ? " " : rawValue)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 2
                paragraph.paragraphSpacing = 0
                switch model.alignments[columnIndex] {
                case .left: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                }

                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setContentWidth(columnWidth, type: .percentageValueType)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setBorderColor(NSColor.separatorColor.withAlphaComponent(0.48))
                block.backgroundColor = rowIndex == 0
                    ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                    : (rowIndex.isMultiple(of: 2)
                        ? NSColor.labelColor.withAlphaComponent(0.055)
                        : NSColor.clear)
                paragraph.textBlocks = [block]
                if rowIndex == 0 {
                    cell.addAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: 14, weight: .semibold),
                        range: NSRange(location: 0, length: cell.length)
                    )
                }
                let isLastCell = rowIndex == rows.count - 1
                    && columnIndex == model.headers.count - 1
                if !isLastCell { cell.append(NSAttributedString(string: "\n")) }
                cell.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: cell.length)
                )
                result.append(cell)
            }
        }
        return result
    }

    private func resize(for text: NSAttributedString) {
        let width: CGFloat = prefersWideLayout ? 500 : 360
        let bounds = text.boundingRect(
            with: CGSize(width: width - 42, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textHeight = min(max(82, ceil(bounds.height) + 38), 240)
        let height = textHeight + (isToolStatusVisible ? 30 : 0)
        panel.setContentSize(CGSize(width: width, height: height))
        layoutContent()
    }

    private func layoutContent() {
        guard let content = panel.contentView else { return }
        let bounds = content.bounds
        let horizontalInset: CGFloat = 14
        let verticalInset: CGFloat = 12
        let statusHeight: CGFloat = isToolStatusVisible ? 22 : 0
        let statusSpacing: CGFloat = isToolStatusVisible ? 6 : 0

        toolStatusBar.frame = CGRect(
            x: horizontalInset,
            y: bounds.height - verticalInset - statusHeight,
            width: max(0, bounds.width - horizontalInset * 2),
            height: statusHeight
        )
        let labelX: CGFloat = toolProgressIndicator.isHidden ? 0 : 22
        toolStatusLabel.frame = CGRect(
            x: labelX,
            y: 1,
            width: max(0, toolStatusBar.bounds.width - labelX),
            height: 20
        )
        scrollView.frame = CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: max(0, bounds.width - horizontalInset * 2),
            height: max(0, bounds.height - verticalInset * 2 - statusHeight - statusSpacing)
        )
    }
}
