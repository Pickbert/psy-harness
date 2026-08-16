import AppKit

final class SpeechBubbleController {
    private let panel: NSPanel
    private let textView: NSTextView
    private let scrollView: NSScrollView

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
        container.addSubview(scrollView)
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    func show(text: String, anchoredTo anchorWindow: NSWindow) {
        let renderedText = renderMarkdown(text)
        textView.textStorage?.setAttributedString(renderedText)
        textView.scrollToBeginningOfDocument(nil)
        resize(for: renderedText)
        reposition(anchoredTo: anchorWindow)
        panel.orderFrontRegardless()
    }

    func reposition(anchoredTo anchorWindow: NSWindow) {
        guard panel.isVisible || !textView.string.isEmpty else { return }
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
    }

    private func renderMarkdown(_ markdown: String) -> NSAttributedString {
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

    private func resize(for text: NSAttributedString) {
        let width: CGFloat = 360
        let bounds = text.boundingRect(
            with: CGSize(width: width - 42, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let height = min(max(82, ceil(bounds.height) + 38), 240)
        panel.setContentSize(CGSize(width: width, height: height))
    }
}
