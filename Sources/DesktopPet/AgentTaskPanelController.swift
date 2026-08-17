import AppKit

final class AgentTaskPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "桌面小柴 Agent")
    private let statusLabel = NSTextField(labelWithString: "准备中…")
    private let textView = NSTextView()
    private let approvalCard = NSView()
    private let approvalAccent = NSView()
    private let approvalTitleLabel = NSTextField(labelWithString: "需要你的确认")
    private let approvalLabel = NSTextField(wrappingLabelWithString: "")
    private let approveButton = NSButton(title: "允许一次", target: nil, action: nil)
    private let rejectButton = NSButton(title: "拒绝", target: nil, action: nil)
    private var scrollBottomToPanel: NSLayoutConstraint?
    private var scrollBottomToApproval: NSLayoutConstraint?
    private var approvalCompletion: ((AgentApprovalDecision) -> Void)?
    private var approvalTimer: Timer?
    private var transcript = ""
    private var activityLines: [String] = []

    override init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 360),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        configure()
    }

    func show(workspace: URL) {
        titleLabel.stringValue = "桌面小柴 Agent · \(workspace.lastPathComponent)"
        statusLabel.stringValue = "正在连接 DeepSeek Harness…"
        transcript = ""
        activityLines.removeAll()
        renderContent()
        hideApproval(answer: nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func updateTranscript(_ text: String) {
        transcript = text
        renderContent()
    }

    func showActivity(_ text: String) {
        statusLabel.stringValue = text
        if activityLines.last != text {
            activityLines.append(text)
            if activityLines.count > 12 { activityLines.removeFirst(activityLines.count - 12) }
        }
        renderContent()
    }

    func requestApproval(
        _ request: AgentApprovalRequest,
        anchoredTo anchorWindow: NSWindow,
        completion: @escaping (AgentApprovalDecision) -> Void
    ) {
        hideApproval(answer: .rejected)
        transcript = ""
        activityLines.removeAll()
        renderContent()
        approvalCompletion = completion
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.hideApproval(answer: .rejected)
            self?.statusLabel.stringValue = "审批已超时，操作已拒绝"
        }
        approvalTitleLabel.stringValue = "允许「\(request.toolName)」执行一次？"
        let details = [request.summary, request.reason, request.arguments]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        approvalLabel.stringValue = details.isEmpty ? request.displaySummary : details.joined(separator: "\n")
        approvalCard.isHidden = false
        scrollBottomToPanel?.isActive = false
        scrollBottomToApproval?.isActive = true
        statusLabel.stringValue = "等待你确认操作"
        panel.setContentSize(CGSize(width: 620, height: 230))
        reposition(anchoredTo: anchorWindow)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func cancelApproval() {
        hideApproval(answer: .rejected)
    }

    func finish(_ text: String) {
        hideApproval(answer: .rejected)
        statusLabel.stringValue = "任务完成"
        updateTranscript(text)
    }

    func showError(_ message: String) {
        hideApproval(answer: .rejected)
        statusLabel.stringValue = "Agent 出错"
        transcript = message
        renderContent()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        hideApproval(answer: .rejected)
    }

    @objc private func approve() {
        hideApproval(answer: .allowedOnce)
        statusLabel.stringValue = "操作已允许，继续执行…"
    }

    @objc private func reject() {
        hideApproval(answer: .rejected)
        statusLabel.stringValue = "操作已拒绝"
    }

    private func hideApproval(answer: AgentApprovalDecision?) {
        approvalTimer?.invalidate()
        approvalTimer = nil
        let completion = approvalCompletion
        approvalCompletion = nil
        approvalCard.isHidden = true
        scrollBottomToApproval?.isActive = false
        scrollBottomToPanel?.isActive = true
        if answer != nil { panel.orderOut(nil) }
        if let answer { completion?(answer) }
    }

    private func reposition(anchoredTo anchorWindow: NSWindow) {
        let anchor = anchorWindow.frame
        let visibleFrame = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        var x = anchor.midX - panel.frame.width / 2
        var y = anchor.maxY + 14
        x = min(max(x, visibleFrame.minX + 10), visibleFrame.maxX - panel.frame.width - 10)
        if y + panel.frame.height > visibleFrame.maxY {
            y = max(visibleFrame.minY + 10, anchor.minY - panel.frame.height - 14)
        }
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func renderContent() {
        let activity = activityLines.map { "• \($0)" }.joined(separator: "\n")
        textView.string = [activity, transcript]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        textView.scrollToEndOfDocument(nil)
    }

    private func configure() {
        panel.title = "桌面小柴 Agent"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityTitle("桌面小柴 Agent 任务面板")

        let background = NSVisualEffectView()
        background.translatesAutoresizingMaskIntoConstraints = false
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.58)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = CGSize(width: 8, height: 8)
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        approvalCard.translatesAutoresizingMaskIntoConstraints = false
        approvalCard.wantsLayer = true
        approvalCard.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.96).cgColor
        approvalCard.layer?.cornerRadius = 13
        approvalCard.layer?.borderWidth = 1
        approvalCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        approvalAccent.translatesAutoresizingMaskIntoConstraints = false
        approvalAccent.wantsLayer = true
        approvalAccent.layer?.backgroundColor = NSColor.systemPurple.cgColor
        approvalAccent.layer?.cornerRadius = 2

        approvalTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        approvalTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        approvalTitleLabel.textColor = .white
        approvalTitleLabel.lineBreakMode = .byTruncatingTail

        approvalLabel.translatesAutoresizingMaskIntoConstraints = false
        approvalLabel.font = .systemFont(ofSize: 12, weight: .regular)
        approvalLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        approvalLabel.maximumNumberOfLines = 3
        approvalLabel.lineBreakMode = .byTruncatingTail
        approveButton.translatesAutoresizingMaskIntoConstraints = false
        rejectButton.translatesAutoresizingMaskIntoConstraints = false
        configureApprovalButton(approveButton, emphasized: true)
        configureApprovalButton(rejectButton, emphasized: false)
        approveButton.target = self
        approveButton.action = #selector(approve)
        rejectButton.target = self
        rejectButton.action = #selector(reject)

        guard let content = panel.contentView else { return }
        content.addSubview(background)
        background.addSubview(titleLabel)
        background.addSubview(statusLabel)
        background.addSubview(scrollView)
        background.addSubview(approvalCard)
        approvalCard.addSubview(approvalAccent)
        approvalCard.addSubview(approvalTitleLabel)
        approvalCard.addSubview(approvalLabel)
        approvalCard.addSubview(approveButton)
        approvalCard.addSubview(rejectButton)

        scrollBottomToPanel = scrollView.bottomAnchor.constraint(
            equalTo: background.bottomAnchor,
            constant: -14
        )
        scrollBottomToApproval = scrollView.bottomAnchor.constraint(
            equalTo: approvalCard.topAnchor,
            constant: -12
        )
        scrollBottomToPanel?.isActive = true

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 17),
            titleLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            approvalCard.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            approvalCard.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            approvalCard.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
            approvalCard.heightAnchor.constraint(equalToConstant: 126),
            approvalAccent.leadingAnchor.constraint(equalTo: approvalCard.leadingAnchor, constant: 14),
            approvalAccent.topAnchor.constraint(equalTo: approvalCard.topAnchor, constant: 15),
            approvalAccent.widthAnchor.constraint(equalToConstant: 4),
            approvalAccent.heightAnchor.constraint(equalToConstant: 18),
            approvalTitleLabel.leadingAnchor.constraint(equalTo: approvalAccent.trailingAnchor, constant: 9),
            approvalTitleLabel.centerYAnchor.constraint(equalTo: approvalAccent.centerYAnchor),
            approvalTitleLabel.trailingAnchor.constraint(equalTo: approvalCard.trailingAnchor, constant: -14),
            approvalLabel.leadingAnchor.constraint(equalTo: approvalTitleLabel.leadingAnchor),
            approvalLabel.trailingAnchor.constraint(equalTo: approvalCard.trailingAnchor, constant: -14),
            approvalLabel.topAnchor.constraint(equalTo: approvalTitleLabel.bottomAnchor, constant: 7),
            approvalLabel.bottomAnchor.constraint(lessThanOrEqualTo: approveButton.topAnchor, constant: -8),
            rejectButton.leadingAnchor.constraint(equalTo: approvalTitleLabel.leadingAnchor),
            rejectButton.bottomAnchor.constraint(equalTo: approvalCard.bottomAnchor, constant: -13),
            rejectButton.widthAnchor.constraint(equalToConstant: 82),
            rejectButton.heightAnchor.constraint(equalToConstant: 32),
            approveButton.leadingAnchor.constraint(equalTo: rejectButton.trailingAnchor, constant: 8),
            approveButton.bottomAnchor.constraint(equalTo: rejectButton.bottomAnchor),
            approveButton.widthAnchor.constraint(equalToConstant: 104),
            approveButton.heightAnchor.constraint(equalTo: rejectButton.heightAnchor)
        ])
        hideApproval(answer: nil)
    }

    private func configureApprovalButton(_ button: NSButton, emphasized: Bool) {
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = emphasized
            ? NSColor.systemPurple.withAlphaComponent(0.9).cgColor
            : NSColor.white.withAlphaComponent(0.10).cgColor
    }
}
