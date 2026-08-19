import AppKit

final class AgentPluginSettingsController: NSObject, NSWindowDelegate {
    private let store: AgentPluginSettingsStore
    private let window: NSWindow
    private let statusLabel: NSTextField
    private let skillSummaryLabel: NSTextField
    private var checkboxes: [AgentPluginID: NSButton] = [:]
    private var runtimeLabels: [AgentPluginID: NSTextField] = [:]
    private var runtimeSnapshot: AgentRuntimePluginSnapshot?
    private var workspace: URL?
    private var onSave: ((AgentPluginConfiguration) -> Void)?

    init(store: AgentPluginSettingsStore) {
        self.store = store
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        statusLabel = NSTextField(labelWithString: "")
        skillSummaryLabel = NSTextField(labelWithString: "")
        super.init()

        window.title = "哈妮丝 · 插件与技能"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildContent()
    }

    func show(
        configuration: AgentPluginConfiguration,
        workspace: URL?,
        runtimeSnapshot: AgentRuntimePluginSnapshot?,
        onSave: @escaping (AgentPluginConfiguration) -> Void
    ) {
        self.runtimeSnapshot = runtimeSnapshot
        self.workspace = workspace
        self.onSave = onSave
        for plugin in AgentPluginID.allCases {
            checkboxes[plugin]?.state = configuration.isEnabled(plugin) ? .on : .off
        }
        statusLabel.stringValue = runtimeSnapshot == nil
            ? "Harness 当前未运行；保存后将在下次启动时加载所选插件。"
            : "状态来自正在运行的 DeepSeek Harness sidecar。"
        refreshSkillSummary()
        refreshRuntimeLabels()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func updateRuntimeSnapshot(_ snapshot: AgentRuntimePluginSnapshot?) {
        runtimeSnapshot = snapshot
        statusLabel.stringValue = snapshot == nil
            ? "暂时无法读取 Harness 插件状态。"
            : "已从 DeepSeek Harness 读取实际工具注册状态。"
        refreshSkillSummary()
        refreshRuntimeLabels()
    }

    private func buildContent() {
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let title = NSTextField(labelWithString: "插件与技能")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.frame = CGRect(x: 28, y: 466, width: 260, height: 32)
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "这些开关直接控制 DeepSeek Harness 的 Cordis 插件组合。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = CGRect(x: 28, y: 440, width: 620, height: 22)
        content.addSubview(subtitle)

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = CGRect(x: 28, y: 413, width: 620, height: 20)
        content.addSubview(statusLabel)

        var y: CGFloat = 352
        for plugin in AgentPluginID.allCases {
            let checkbox = NSButton(checkboxWithTitle: plugin.title, target: self, action: #selector(selectionChanged))
            checkbox.font = .systemFont(ofSize: 15, weight: .semibold)
            checkbox.frame = CGRect(x: 30, y: y + 24, width: 320, height: 24)
            checkbox.identifier = NSUserInterfaceItemIdentifier(plugin.rawValue)
            content.addSubview(checkbox)
            checkboxes[plugin] = checkbox

            let detail = NSTextField(wrappingLabelWithString: plugin.detail)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.frame = CGRect(x: 52, y: y - 2, width: 480, height: 42)
            content.addSubview(detail)

            let runtime = NSTextField(labelWithString: "")
            runtime.font = .systemFont(ofSize: 11, weight: .semibold)
            runtime.alignment = .right
            runtime.frame = CGRect(x: 536, y: y + 25, width: 112, height: 20)
            content.addSubview(runtime)
            runtimeLabels[plugin] = runtime
            y -= 76
        }

        let divider = NSBox(frame: CGRect(x: 28, y: 90, width: 624, height: 1))
        divider.boxType = .separator
        content.addSubview(divider)

        skillSummaryLabel.font = .systemFont(ofSize: 12)
        skillSummaryLabel.textColor = .secondaryLabelColor
        skillSummaryLabel.lineBreakMode = .byTruncatingMiddle
        skillSummaryLabel.frame = CGRect(x: 28, y: 44, width: 322, height: 22)
        content.addSubview(skillSummaryLabel)

        let openSkills = NSButton(title: "打开技能目录", target: self, action: #selector(openSkillDirectory))
        openSkills.bezelStyle = .rounded
        openSkills.frame = CGRect(x: 356, y: 38, width: 114, height: 30)
        content.addSubview(openSkills)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.frame = CGRect(x: 478, y: 38, width: 76, height: 30)
        content.addSubview(cancel)

        let save = NSButton(title: "保存并重启", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = CGRect(x: 560, y: 38, width: 92, height: 30)
        content.addSubview(save)
    }

    @objc private func selectionChanged() {
        refreshRuntimeLabels()
    }

    @objc private func openSkillDirectory() {
        guard let workspace,
              let directory = try? store.ensureSkillDirectory(in: workspace)
        else { return }
        NSWorkspace.shared.open(directory)
        refreshSkillSummary()
    }

    @objc private func cancel() {
        window.orderOut(nil)
    }

    @objc private func save() {
        var configuration = AgentPluginConfiguration(enabled: [])
        for plugin in AgentPluginID.allCases {
            configuration.setEnabled(checkboxes[plugin]?.state == .on, for: plugin)
        }
        onSave?(configuration)
        window.orderOut(nil)
    }

    private func refreshSkillSummary() {
        if let runtimeSnapshot, runtimeSnapshot.isActive(.skills) {
            let names = runtimeSnapshot.skillNames
            skillSummaryLabel.stringValue = names.isEmpty
                ? "Harness 技能插件已启用，当前目录中尚无有效技能。"
                : "Harness 已加载 \(names.count) 个技能：\(names.prefix(3).joined(separator: "、"))"
            return
        }
        guard workspace != nil else {
            skillSummaryLabel.stringValue = "请先选择 Agent 工作目录，再管理技能。"
            return
        }
        let names = store.installedSkillNames(in: workspace)
        if names.isEmpty {
            skillSummaryLabel.stringValue = "技能目录为空，可放入 <name>/SKILL.md"
        } else {
            skillSummaryLabel.stringValue = "已发现 \(names.count) 个技能：\(names.prefix(3).joined(separator: "、"))"
        }
    }

    private func refreshRuntimeLabels() {
        for plugin in AgentPluginID.allCases {
            let selected = checkboxes[plugin]?.state == .on
            guard let runtimeSnapshot else {
                runtimeLabels[plugin]?.stringValue = selected ? "待启动" : "已关闭"
                runtimeLabels[plugin]?.textColor = selected ? .systemOrange : .tertiaryLabelColor
                continue
            }
            let active = runtimeSnapshot.isActive(plugin)
            if active == selected {
                runtimeLabels[plugin]?.stringValue = active ? "Harness 已启用" : "已关闭"
                runtimeLabels[plugin]?.textColor = active ? .systemGreen : .tertiaryLabelColor
            } else {
                runtimeLabels[plugin]?.stringValue = "保存后重启"
                runtimeLabels[plugin]?.textColor = .systemOrange
            }
        }
    }
}
