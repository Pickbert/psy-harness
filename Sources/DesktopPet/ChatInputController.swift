import AppKit

private final class ChatInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let commandModifiers = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        guard event.type == .keyDown,
              commandModifiers == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "v"
        else { return super.performKeyEquivalent(with: event) }

        if firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: nil) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class ChatInputController: NSObject, NSTextFieldDelegate {
    private let panel: ChatInputPanel
    private let inputField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private var completion: ((String?) -> Void)?
    private var presentationGeneration = 0

    override init() {
        panel = ChatInputPanel(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 108),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    var isVisible: Bool { panel.isVisible }

#if DEBUG
    var panelForTesting: NSPanel { panel }
    var inputTextForTesting: String { inputField.stringValue }
#endif

    @discardableResult
    func prompt(
        on screen: NSScreen?,
        attachments: [String] = [],
        completion: @escaping (String?) -> Void
    ) -> Bool {
        let startedNewPrompt = self.completion == nil
        if startedNewPrompt {
            self.completion = completion
            inputField.stringValue = ""
        }

        updateContext(attachments: attachments)
        presentPanel(on: screen ?? NSScreen.main ?? NSScreen.screens.first)
        return startedNewPrompt
    }

    private func presentPanel(on screen: NSScreen?) {
        presentationGeneration += 1
        let generation = presentationGeneration

        forcePanelToFront(on: screen)

        // App activation after a cross-application drag is asynchronous. Reasserting
        // presentation on the next run loop prevents AppKit from leaving this
        // accessory-app panel ordered but inaccessible behind the source app.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.completion != nil,
                  self.presentationGeneration == generation
            else { return }
            self.forcePanelToFront(on: screen)
        }

        // Recover from a WindowServer state where isVisible is true even though the
        // panel never became key, active-space-visible, or remained on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.completion != nil,
                  self.presentationGeneration == generation,
                  !self.isPanelAccessible(on: screen)
            else { return }
            self.forcePanelToFront(on: screen)
        }
    }

    private func forcePanelToFront(on screen: NSScreen?) {
        position(on: screen)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(inputField)
    }

    private func isPanelAccessible(on screen: NSScreen?) -> Bool {
        let targetFrame = screen?.visibleFrame
            ?? panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        let intersectsScreen = targetFrame.map { $0.intersects(panel.frame) } ?? panel.isVisible
        return panel.isVisible
            && panel.isKeyWindow
            && panel.isOnActiveSpace
            && intersectsScreen
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.title = "和哈妮丝开始本轮生涯规划"
        panel.setAccessibilityTitle("和哈妮丝开始本轮生涯规划")

        let background = NSVisualEffectView()
        background.translatesAutoresizingMaskIntoConstraints = false
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 17
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        background.layer?.masksToBounds = true

        let accent = NSView()
        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.wantsLayer = true
        accent.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        accent.layer?.cornerRadius = 1.5

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.delegate = self
        inputField.isBezeled = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.font = .systemFont(ofSize: 25, weight: .medium)
        inputField.textColor = .white
        inputField.maximumNumberOfLines = 1
        inputField.lineBreakMode = .byTruncatingTail
        inputField.placeholderAttributedString = NSAttributedString(
            string: "这次想聊些什么？",
            attributes: [
                .font: NSFont.systemFont(ofSize: 25, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.38)
            ]
        )
        inputField.setAccessibilityLabel("生涯规划咨询输入")
        inputField.setAccessibilityHelp("输入内容后按回车发送，按 Escape 取消")

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.42)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = Self.chatIcon()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityLabel("哈妮丝")

        guard let contentView = panel.contentView else { return }
        contentView.addSubview(background)
        background.addSubview(accent)
        background.addSubview(inputField)
        background.addSubview(hintLabel)
        background.addSubview(iconView)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            background.topAnchor.constraint(equalTo: contentView.topAnchor),
            background.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            accent.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            accent.topAnchor.constraint(equalTo: background.topAnchor, constant: 20),
            accent.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -20),
            accent.widthAnchor.constraint(equalToConstant: 3),

            iconView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            iconView.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: -1),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            inputField.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 17),
            inputField.trailingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -18),
            inputField.topAnchor.constraint(equalTo: background.topAnchor, constant: 22),
            inputField.heightAnchor.constraint(equalToConstant: 40),

            hintLabel.leadingAnchor.constraint(equalTo: inputField.leadingAnchor, constant: 2),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: iconView.leadingAnchor, constant: -18),
            hintLabel.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: 7)
        ])
    }

    private func updateContext(attachments: [String]) {
        if attachments.isEmpty {
            hintLabel.stringValue = "↵ 发送    esc 取消    职业咨询猫"
            inputField.setAccessibilityHelp("输入内容后按回车发送，按 Escape 取消")
            return
        }

        let visibleNames = attachments.prefix(2).joined(separator: "、")
        let remaining = attachments.count - min(attachments.count, 2)
        let suffix = remaining > 0 ? "  +\(remaining)" : ""
        hintLabel.stringValue = "📎 \(visibleNames)\(suffix)    ↵ 发送    esc 取消"
        inputField.setAccessibilityHelp("正在分析附件 \(attachments.joined(separator: "、"))。输入要求后按回车发送，按 Escape 取消")
    }

    private func position(on screen: NSScreen?) {
        guard let screen else {
            panel.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.maxY - panel.frame.height - max(72, visibleFrame.height * 0.12)
        )
        panel.setFrameOrigin(origin)
    }

    private func submit() {
        let value = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            NSSound.beep()
            return
        }
        finish(with: value)
    }

    private func cancel() {
        finish(with: nil)
    }

    func cancelPrompt() {
        guard panel.isVisible || completion != nil else { return }
        finish(with: nil)
    }

    private func finish(with value: String?) {
        presentationGeneration += 1
        let completion = self.completion
        self.completion = nil
        panel.orderOut(nil)
        completion?(value)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    private static func chatIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "cat-chat-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.module.url(forResource: "cat-chat-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "哈妮丝")
    }
}
