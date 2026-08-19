import AppKit

enum ChatStartGate {
    static func blockMessage(
        isRequestInFlight: Bool,
        isPreparingFileAnalysis: Bool
    ) -> String? {
        if isPreparingFileAnalysis {
            return "文件仍在本地解析，请稍等一下～"
        }
        if isRequestInFlight {
            return "我还在想上一条问题，请稍等一下～"
        }
        return nil
    }
}

final class PetController: NSObject {
    private static let waitingTimeoutDefaultsKey = "waitingTimeoutMinutes"
    private static let defaultWaitingTimeoutMinutes = 3
    private static let agentSessionDefaultsKey = "deepSeekAgentSessionID"

    private(set) var isVisible = false

    var isPaused = false {
        didSet {
            recordUserInteraction()
            mood = .idle
            nextDecisionAt = ProcessInfo.processInfo.systemUptime + 2
        }
    }

    private let window: NSWindow
    private let petView: PetView
    private let settingsStore = DeepSeekSettingsStore()
    private let deepSeekClient = DeepSeekClient()
    private let agentManager = AgentProcessManager()
    private let agentWorkspaceStore = AgentWorkspaceStore()
    private let agentPluginStore = AgentPluginSettingsStore()
    private let fileAnalysisStore = FileAnalysisSessionStore()
    private let agentPanel = AgentTaskPanelController()
    private let speechBubble = SpeechBubbleController()
    private let chatInput = ChatInputController()
    private lazy var agentPluginSettingsController = AgentPluginSettingsController(store: agentPluginStore)
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var nextDecisionAt = ProcessInfo.processInfo.systemUptime + 2
    private var actionEndsAt = ProcessInfo.processInfo.systemUptime + 2
    private var targetX: CGFloat?
    private var bubbleDismissAt: TimeInterval?
    private var conversationHistory: [DeepSeekMessage] = []
    private var isRequestInFlight = false
    private var isAwaitingAgentApproval = false
    private var isDraggingPet = false
    private var isReceivingFileDrop = false
    private var isPreparingFileAnalysis = false
    private var activeFileAnalysisSession: FileAnalysisSession?
    private var toolStatusGeneration = 0
    private var securityScopedWorkspace: URL?
    private var lastInteractionAt = ProcessInfo.processInfo.systemUptime
    private var mood: PetMood = .idle {
        didSet { petView.mood = mood }
    }

    override init() {
        let initialSize = CGFloat(UserDefaults.standard.integer(forKey: "petSize"))
        let size = initialSize > 0 ? initialSize : 190
        let frames = Self.loadPetFrames()
        petView = PetView(frame: CGRect(x: 0, y: 0, width: size, height: size), frames: frames)

        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        if let workspace = agentWorkspaceStore.workspaceURL() {
            activateSecurityScopedWorkspace(workspace)
            try? fileAnalysisStore.cleanupExpiredSessions(in: workspace)
            activeFileAnalysisSession = fileAnalysisStore.activeSession(in: workspace)
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.contentView = petView
        window.title = "哈妮丝"
        window.setAccessibilityTitle("哈妮丝")

        petView.onDragStarted = { [weak self] in
            self?.beginDragging()
        }
        petView.onDragEnded = { [weak self] in
            self?.finishDragging()
        }
        petView.onTripleClick = { [weak self] in
            self?.startDeepSeekChat()
        }
        petView.onContextMenu = { [weak self] event in
            self?.showContextMenu(with: event)
        }
        petView.onInteraction = { [weak self] in
            self?.recordUserInteraction()
        }
        petView.canAcceptFileDrop = { [weak self] in
            guard let self else { return false }
            return AgentProcessManager.platformSupported
                && !self.isRequestInFlight
                && !self.isAwaitingAgentApproval
                && !self.isPreparingFileAnalysis
                && !self.chatInput.isVisible
        }
        petView.onFileDragStateChanged = { [weak self] active in
            guard let self else { return }
            self.isReceivingFileDrop = active
            if active {
                self.targetX = nil
                self.mood = .idle
            }
        }
        petView.onFilesDropped = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }

        agentManager.onTranscript = { [weak self] text in
            self?.showSpeech(text, duration: nil, followLatest: true)
        }
        agentManager.onActivity = { [weak self] text in
            self?.showSpeech(text, duration: 6)
        }
        agentManager.onToolExecutionState = { [weak self] state in
            self?.updateToolExecutionState(state)
        }
        agentManager.onApproval = { [weak self] request, completion in
            guard let self else {
                completion(.rejected)
                return
            }
            self.isAwaitingAgentApproval = true
            self.targetX = nil
            self.mood = .idle
            self.bubbleDismissAt = nil
            self.showSpeech("这个操作需要你确认一下～", duration: nil)
            self.agentPanel.requestApproval(request, anchoredTo: self.window) { [weak self] decision in
                guard let self else {
                    completion(.rejected)
                    return
                }
                self.isAwaitingAgentApproval = false
                self.nextDecisionAt = ProcessInfo.processInfo.systemUptime + 2
                completion(decision)
            }
        }

        resetPosition(animated: false)
        startTimer()
    }

    deinit {
        stop()
    }

    func show() {
        recordUserInteraction()
        window.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        recordUserInteraction()
        chatInput.cancelPrompt()
        agentPanel.cancelApproval()
        window.orderOut(nil)
        speechBubble.hide()
        isVisible = false
    }

    func callPet() {
        recordUserInteraction()
        show()
        resetPosition(animated: true)
        petView.showAffection()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        chatInput.cancelPrompt()
        agentPanel.cancelApproval()
        speechBubble.hide()
        agentManager.shutdown()
        releaseSecurityScopedWorkspace()
    }

    @objc func configureDeepSeek() {
        recordUserInteraction()
        NSApp.activate(ignoringOtherApps: true)
        let hasAPIKey = settingsStore.apiKey() != nil
        let alert = NSAlert()
        alert.messageText = "DeepSeek 设置"
        alert.informativeText = hasAPIKey
            ? "API Key 已配置。留空可保持原密钥不变；Token 范围为 1–384000，文件上限为 1–100 MB。"
            : "API Key 将安全保存在 macOS 钥匙串中；Token 范围为 1–384000，文件上限为 1–100 MB。"

        let accessory = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 182))
        func label(_ title: String, y: CGFloat) -> NSTextField {
            let field = NSTextField(labelWithString: title)
            field.frame = CGRect(x: 0, y: y, width: 150, height: 24)
            field.alignment = .right
            return field
        }

        let keyField = NSSecureTextField(frame: CGRect(x: 162, y: 154, width: 258, height: 24))
        keyField.placeholderString = hasAPIKey ? "已安全保存" : "DeepSeek API Key"
        let modelPopup = NSPopUpButton(frame: CGRect(x: 162, y: 118, width: 258, height: 28))
        DeepSeekModel.allCases.forEach { modelPopup.addItem(withTitle: $0.displayName) }
        modelPopup.selectItem(at: DeepSeekModel.allCases.firstIndex(of: settingsStore.selectedModel) ?? 0)

        let agentTokenField = NSTextField(frame: CGRect(x: 162, y: 82, width: 258, height: 24))
        agentTokenField.stringValue = String(settingsStore.agentMaxOutputTokens)
        agentTokenField.placeholderString = String(DeepSeekOutputLimits.defaultAgent)

        let directTokenField = NSTextField(frame: CGRect(x: 162, y: 46, width: 258, height: 24))
        directTokenField.stringValue = String(settingsStore.directChatMaxOutputTokens)
        directTokenField.placeholderString = String(DeepSeekOutputLimits.defaultDirectChat)

        let fileLimitField = NSTextField(frame: CGRect(x: 162, y: 10, width: 258, height: 24))
        fileLimitField.stringValue = String(settingsStore.fileAnalysisMaxFileSizeMB)
        fileLimitField.placeholderString = String(FileAnalysisLimits.defaultMaxFileSizeMB)

        accessory.addSubview(label("API Key", y: 154))
        accessory.addSubview(label("模型", y: 120))
        accessory.addSubview(label("Agent 最大输出 Token", y: 82))
        accessory.addSubview(label("普通对话最大输出 Token", y: 46))
        accessory.addSubview(label("单文件分析上限（MB）", y: 10))
        accessory.addSubview(keyField)
        accessory.addSubview(modelPopup)
        accessory.addSubview(agentTokenField)
        accessory.addSubview(directTokenField)
        accessory.addSubview(fileLimitField)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if hasAPIKey {
            alert.addButton(withTitle: "清除密钥")
        }
        alert.window.initialFirstResponder = keyField

        let result = alert.runModal()
        if result == .alertThirdButtonReturn {
            do {
                try settingsStore.clearAPIKey()
                conversationHistory.removeAll()
                agentManager.shutdown()
                resetAgentSession()
                showSpeech("DeepSeek 密钥已清除。", duration: 4)
            } catch {
                showError(error)
            }
            return
        }
        guard result == .alertFirstButtonReturn else { return }

        let agentTokenValue = agentTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let directTokenValue = directTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileLimitValue = fileLimitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agentMaxOutputTokens = Int(agentTokenValue),
              DeepSeekOutputLimits.isValid(agentMaxOutputTokens),
              let directChatMaxOutputTokens = Int(directTokenValue),
              DeepSeekOutputLimits.isValid(directChatMaxOutputTokens),
              let fileAnalysisMaxFileSizeMB = Int(fileLimitValue),
              FileAnalysisLimits.isValid(maxFileSizeMB: fileAnalysisMaxFileSizeMB)
        else {
            showSpeech("Token 必须是 1 到 384000 的整数；单文件分析上限必须是 1 到 100 MB 的整数。", duration: 8)
            return
        }

        do {
            let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try settingsStore.saveAPIKey(key)
            }
            settingsStore.selectedModel = DeepSeekModel.allCases[modelPopup.indexOfSelectedItem]
            settingsStore.agentMaxOutputTokens = agentMaxOutputTokens
            settingsStore.directChatMaxOutputTokens = directChatMaxOutputTokens
            settingsStore.fileAnalysisMaxFileSizeMB = fileAnalysisMaxFileSizeMB
            agentManager.shutdown()
            resetAgentSession()
            if settingsStore.apiKey() == nil {
                showSpeech("还没有填写 API Key 哦。", duration: 5)
            } else {
                showSpeech("DeepSeek 已配置好啦！连续点我三次就能聊天。", duration: 7)
            }
        } catch {
            showError(error)
        }
    }

    @objc func startDeepSeekChat() {
        recordUserInteraction()
        if let message = ChatStartGate.blockMessage(
            isRequestInFlight: isRequestInFlight,
            isPreparingFileAnalysis: isPreparingFileAnalysis
        ) {
            showSpeech(message, duration: 5)
            return
        }
        guard settingsStore.apiKey() != nil else {
            configureDeepSeek()
            guard settingsStore.apiKey() != nil else { return }
            return startDeepSeekChat()
        }

        if AgentProcessManager.platformSupported, let fileSession = activeFileAnalysisSession {
            guard let workspace = agentWorkspaceStore.workspaceURL(),
                  FileManager.default.fileExists(atPath: fileSession.sessionURL.path)
            else {
                activeFileAnalysisSession = nil
                fileAnalysisStore.endActiveSession()
                showError(FileAnalysisError.invalidSession)
                return
            }
            chatInput.prompt(
                on: window.screen,
                attachments: fileSession.displayNames
            ) { [weak self] question in
                guard let self, let question else { return }
                self.sendToAgent(
                    question,
                    workspace: workspace,
                    sessionID: fileSession.agentSessionID,
                    fileSession: fileSession
                )
            }
        } else if AgentProcessManager.platformSupported {
            guard let workspace = agentWorkspaceStore.workspaceURL() ?? chooseAgentWorkspace() else { return }
            chatInput.prompt(on: window.screen) { [weak self] question in
                guard let self, let question else { return }
                self.sendToAgent(question, workspace: workspace)
            }
        } else {
            chatInput.prompt(on: window.screen) { [weak self] question in
                guard let self, let question else { return }
                self.sendToDeepSeek(question)
            }
        }
    }

    @objc func selectAgentWorkspace() {
        recordUserInteraction()
        guard AgentProcessManager.platformSupported else {
            showSpeech("当前系统不启用本地 Agent，将继续使用普通 DeepSeek 对话。", duration: 8)
            return
        }
        _ = chooseAgentWorkspace()
    }

    @objc func clearAgentWorkspace() {
        recordUserInteraction()
        agentManager.shutdown()
        releaseSecurityScopedWorkspace()
        fileAnalysisStore.endActiveSession()
        activeFileAnalysisSession = nil
        agentWorkspaceStore.clear()
        resetAgentSession()
        showSpeech("Agent 工作目录已清除，下次使用时会重新选择。", duration: 7)
    }

    @objc func newAgentConversation() {
        recordUserInteraction()
        agentPanel.cancelApproval()
        agentManager.shutdown()
        isRequestInFlight = false
        isAwaitingAgentApproval = false
        if let fileSession = activeFileAnalysisSession {
            do {
                activeFileAnalysisSession = try fileAnalysisStore.replaceAgentSessionID(for: fileSession)
            } catch {
                showError(error)
                return
            }
        } else {
            resetAgentSession()
        }
        showSpeech("新的 Agent 对话已经准备好啦。", duration: 5)
    }

    @objc func endFileAnalysis() {
        recordUserInteraction()
        guard activeFileAnalysisSession != nil else {
            showSpeech("当前没有正在使用的文件分析会话。", duration: 5)
            return
        }
        agentPanel.cancelApproval()
        agentManager.shutdown()
        fileAnalysisStore.endActiveSession()
        activeFileAnalysisSession = nil
        isRequestInFlight = false
        showSpeech("文件分析已结束，之后会恢复普通 Agent 工作目录。", duration: 7)
    }

    @objc func clearFileAnalysisCache() {
        recordUserInteraction()
        guard !isRequestInFlight, !isAwaitingAgentApproval else {
            showSpeech("请先等待当前 Agent 任务结束，再清除文件分析缓存。", duration: 7)
            return
        }
        guard let workspace = agentWorkspaceStore.workspaceURL() else {
            showSpeech("请先选择 Agent 工作目录，再清除其中的文件分析缓存。", duration: 7)
            return
        }
        activateSecurityScopedWorkspace(workspace)
        agentManager.shutdown()
        do {
            try fileAnalysisStore.clearCache(in: workspace)
            activeFileAnalysisSession = nil
            showSpeech("当前工作目录的文件分析缓存已经清除。", duration: 6)
        } catch {
            showError(error)
        }
    }

    @objc func stopAgentTask() {
        recordUserInteraction()
        agentPanel.cancelApproval()
        agentManager.stopCurrentTask()
        isRequestInFlight = false
        showSpeech("已经停下来了，汪。", duration: 5)
    }

    @objc func restartAgent() {
        recordUserInteraction()
        guard AgentProcessManager.platformSupported,
              let workspace = currentAgentWorkspace,
              let apiKey = settingsStore.apiKey()
        else {
            showSpeech("请先配置 API Key 并选择 Agent 工作目录。", duration: 7)
            return
        }
        activateSecurityScopedWorkspace(workspace)
        showSpeech("正在重启 Agent…", duration: nil)
        agentManager.stopCurrentTask()
        agentManager.start(
            workspace: workspace,
            apiKey: apiKey,
            model: settingsStore.selectedModel,
            maxOutputTokens: settingsStore.agentMaxOutputTokens,
            plugins: agentPluginStore.configuration
        ) { [weak self] result in
            switch result {
            case .success:
                self?.showSpeech("Agent 已重新启动", duration: 5)
            case let .failure(error):
                self?.showError(error)
            }
        }
    }

    @objc func showAgentStatus() {
        recordUserInteraction()
        let workspace = currentAgentWorkspace?.path ?? "未选择工作目录"
        let fileContext = activeFileAnalysisSession.map {
            "文件分析：\($0.displayNames.joined(separator: "、"))"
        } ?? "文件分析：未启用"
        let configured = agentPluginStore.configuration
        let actual = AgentPluginID.allCases
            .filter { agentManager.runtimePluginSnapshot?.isActive($0) == true }
            .map(\.title)
            .joined(separator: "、")
        showSpeech(
            "\(agentManager.statusText)\n工作目录：\(workspace)\n\(fileContext)\n审批模式：\(agentManager.approvalModeText)\n最大输出 Token：\(settingsStore.agentMaxOutputTokens)\n已配置：\(configured.displaySummary)\nHarness 实际启用：\(actual.isEmpty ? "未运行或无可选插件" : actual)",
            duration: 12
        )
    }

    @objc func configureAgentPlugins() {
        recordUserInteraction()
        guard AgentProcessManager.platformSupported else {
            showSpeech("当前系统不启用本地 Agent 插件。", duration: 6)
            return
        }
        guard !isRequestInFlight, !isAwaitingAgentApproval else {
            showSpeech("请先等待当前 Agent 任务结束，再修改插件设置。", duration: 7)
            return
        }

        let pluginWorkspace = currentAgentWorkspace
        if let pluginWorkspace { activateSecurityScopedWorkspace(pluginWorkspace) }
        agentPluginSettingsController.show(
            configuration: agentPluginStore.configuration,
            workspace: pluginWorkspace,
            runtimeSnapshot: agentManager.runtimePluginSnapshot
        ) { [weak self] configuration in
            self?.applyAgentPluginConfiguration(configuration)
        }
        agentManager.refreshPluginStatus { [weak self] result in
            if case let .success(snapshot) = result {
                self?.agentPluginSettingsController.updateRuntimeSnapshot(snapshot)
            }
        }
    }

    @objc func configureWaiting() {
        recordUserInteraction()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "等待召唤设置"
        alert.informativeText = "连续多少分钟没有互动后，让哈妮丝蹲坐等待？填写 0 可关闭。"
        let inputField = NSTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 26))
        inputField.stringValue = String(waitingTimeoutMinutes)
        inputField.placeholderString = "分钟数（0–1440）"
        alert.accessoryView = inputField
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = inputField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let value = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(value), (0...1440).contains(minutes) else {
            showSpeech("请输入 0 到 1440 之间的整数分钟。", duration: 6)
            return
        }
        UserDefaults.standard.set(minutes, forKey: Self.waitingTimeoutDefaultsKey)
        recordUserInteraction()
        if minutes == 0 {
            showSpeech("自动等待召唤已关闭。", duration: 5)
        } else {
            showSpeech("好哒，\(minutes) 分钟没人理我，我就蹲下等你。", duration: 6)
        }
    }

    func setPetSize(_ size: CGFloat) {
        recordUserInteraction()
        let clampedSize = min(max(size, 120), 280)
        UserDefaults.standard.set(Int(clampedSize), forKey: "petSize")

        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        window.setFrame(
            CGRect(
                x: center.x - clampedSize / 2,
                y: center.y - clampedSize / 2,
                width: clampedSize,
                height: clampedSize
            ),
            display: true,
            animate: true
        )
        clampToVisibleScreen()
    }

    func resetPosition(animated: Bool) {
        recordUserInteraction()
        guard let screen = preferredScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let destination = CGPoint(
            x: visibleFrame.maxX - window.frame.width - 24,
            y: visibleFrame.minY + 8
        )
        window.setFrameOrigin(destination)
        if animated {
            window.alphaValue = 0.25
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                window.animator().alphaValue = 1
            }
        }
        mood = .idle
        targetX = nil
        nextDecisionAt = ProcessInfo.processInfo.systemUptime + 1.5
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let deltaTime = min(max(now - lastTick, 0), 0.05)
        lastTick = now
        petView.update(deltaTime: deltaTime)
        if speechBubble.isVisible {
            speechBubble.reposition(anchoredTo: window)
        }
        if let bubbleDismissAt, now >= bubbleDismissAt {
            speechBubble.hide()
            self.bubbleDismissAt = nil
        }

        guard !isPaused,
              !isAwaitingAgentApproval,
              !isDraggingPet,
              !isReceivingFileDrop,
              !isPreparingFileAnalysis,
              isVisible
        else { return }

        let timeout = TimeInterval(waitingTimeoutMinutes * 60)
        if timeout > 0, !isRequestInFlight, now - lastInteractionAt >= timeout {
            if mood != .waiting {
                targetX = nil
                mood = .waiting
            }
            return
        }

        if mood == .walking, let targetX {
            let step = PetMotion.step(
                currentX: window.frame.minX,
                targetX: targetX,
                speed: max(45, window.frame.width * 0.32),
                deltaTime: deltaTime
            )
            petView.isFacingRight = step.isFacingRight
            window.setFrameOrigin(CGPoint(x: step.x, y: window.frame.minY))
            if step.reachedTarget {
                self.targetX = nil
                mood = .idle
                nextDecisionAt = now + Double.random(in: 1.5...4.2)
            }
        } else if mood == .sleeping, now >= actionEndsAt {
            mood = .idle
            nextDecisionAt = now + Double.random(in: 1.5...3.5)
        } else if mood == .idle, now >= nextDecisionAt {
            chooseNextAction(now: now)
        }
    }

    private func chooseNextAction(now: TimeInterval) {
        guard let screen = window.screen ?? preferredScreen() else { return }
        let roll = Int.random(in: 0..<100)

        if roll < 64 {
            let frame = screen.visibleFrame
            let minimumX = frame.minX
            let maximumX = max(minimumX, frame.maxX - window.frame.width)
            targetX = CGFloat.random(in: minimumX...maximumX)
            mood = .walking
        } else if roll < 82 {
            mood = .sleeping
            actionEndsAt = now + Double.random(in: 4...8)
        } else {
            mood = .idle
            nextDecisionAt = now + Double.random(in: 2...5)
        }
    }

    private func beginDragging() {
        recordUserInteraction()
        isDraggingPet = true
        targetX = nil
        mood = .idle
    }

    private func finishDragging() {
        recordUserInteraction()
        isDraggingPet = false
        clampToVisibleScreen()
        targetX = nil
        mood = .idle
        nextDecisionAt = ProcessInfo.processInfo.systemUptime + 2
    }

    private func clampToVisibleScreen() {
        guard let screen = window.screen ?? preferredScreen() else { return }
        let origin = PetMotion.clampedOrigin(
            window.frame.origin,
            windowSize: window.frame.size,
            visibleFrame: screen.visibleFrame
        )
        window.setFrameOrigin(origin)
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func showContextMenu(with event: NSEvent) {
        recordUserInteraction()
        let menu = NSMenu(title: "哈妮丝")
        let chatItem = NSMenuItem(title: "开始 AI 对话…", action: #selector(startDeepSeekChat), keyEquivalent: "")
        chatItem.target = self
        menu.addItem(chatItem)
        let settingsItem = NSMenuItem(title: "设置 DeepSeek…", action: #selector(configureDeepSeek), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        if AgentProcessManager.platformSupported {
            menu.addItem(agentMenuItem())
        }
        let waitingItem = NSMenuItem(title: "设置等待时间…", action: #selector(configureWaiting), keyEquivalent: "")
        waitingItem.target = self
        menu.addItem(waitingItem)
        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "回到屏幕右下角", action: #selector(contextResetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        NSMenu.popUpContextMenu(menu, with: event, for: petView)
    }

    @objc private func contextResetPosition() {
        resetPosition(animated: true)
    }

    private func sendToDeepSeek(_ question: String) {
        guard let apiKey = settingsStore.apiKey() else { return }
        isRequestInFlight = true
        showSpeech("让我想一想…", duration: nil)
        let model = settingsStore.selectedModel
        let history = Array(conversationHistory.suffix(10))
        let maxOutputTokens = settingsStore.directChatMaxOutputTokens

        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await deepSeekClient.reply(
                    to: question,
                    apiKey: apiKey,
                    model: model,
                    history: history,
                    maxOutputTokens: maxOutputTokens
                )
                await MainActor.run {
                    self.isRequestInFlight = false
                    self.conversationHistory.append(DeepSeekMessage(role: "user", content: question))
                    self.conversationHistory.append(DeepSeekMessage(role: "assistant", content: answer))
                    if self.conversationHistory.count > 12 {
                        self.conversationHistory.removeFirst(self.conversationHistory.count - 12)
                    }
                    self.showSpeech(answer, duration: 30)
                    self.petView.showAffection()
                }
            } catch let error as DeepSeekError {
                await MainActor.run {
                    self.isRequestInFlight = false
                    if case let .outputLimitReached(partial) = error {
                        self.showOutputLimitWarning(partial: partial, source: "普通对话")
                    } else {
                        self.showError(error)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRequestInFlight = false
                    self.showError(error)
                }
            }
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        recordUserInteraction()
        guard AgentProcessManager.platformSupported else {
            showSpeech("当前系统不启用 Agent 文件分析。", duration: 7)
            return
        }
        guard !isRequestInFlight, !isAwaitingAgentApproval, !isPreparingFileAnalysis else {
            showSpeech("哈妮丝正在处理任务，请完成后再拖入文件。", duration: 6)
            return
        }
        guard settingsStore.apiKey() != nil else {
            configureDeepSeek()
            guard settingsStore.apiKey() != nil else { return }
            return handleDroppedFiles(urls)
        }
        guard let workspace = agentWorkspaceStore.workspaceURL() ?? chooseAgentWorkspace() else { return }
        activateSecurityScopedWorkspace(workspace)
        try? fileAnalysisStore.cleanupExpiredSessions(in: workspace)

        isPreparingFileAnalysis = true
        targetX = nil
        mood = .idle
        let limitMB = settingsStore.fileAnalysisMaxFileSizeMB
        showSpeech(
            "正在本地解析 \(urls.count) 个文件…\n单文件不能超过 \(limitMB) MB；可在 DeepSeek 设置中修改。",
            duration: nil
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result {
                try self.fileAnalysisStore.createSession(
                    from: urls,
                    in: workspace,
                    maxFileSizeMB: limitMB
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPreparingFileAnalysis = false
                switch result {
                case let .success(session):
                    self.agentPanel.cancelApproval()
                    self.agentManager.shutdown()
                    self.activeFileAnalysisSession = session
                    self.showSpeech(
                        "文件已准备好：\(session.displayNames.joined(separator: "、"))\n请输入你希望我怎样分析。",
                        duration: 8
                    )
                    self.chatInput.prompt(
                        on: self.window.screen,
                        attachments: session.displayNames
                    ) { [weak self] question in
                        guard let self, let question else { return }
                        self.sendToAgent(
                            question,
                            workspace: workspace,
                            sessionID: session.agentSessionID,
                            fileSession: session
                        )
                    }
                case let .failure(error):
                    self.showError(error)
                }
            }
        }
    }

    private func sendToAgent(
        _ question: String,
        workspace: URL,
        sessionID: String? = nil,
        fileSession: FileAnalysisSession? = nil
    ) {
        guard let apiKey = settingsStore.apiKey() else { return }
        activateSecurityScopedWorkspace(workspace)
        isRequestInFlight = true
        showSpeech("哈妮丝 Agent 开始工作啦…", duration: 5)
        let prompt = fileSession.map { fileAnalysisPrompt(question: question, session: $0) } ?? question
        let requestedSessionID = sessionID ?? agentSessionID
        agentManager.start(
            workspace: workspace,
            apiKey: apiKey,
            model: settingsStore.selectedModel,
            maxOutputTokens: settingsStore.agentMaxOutputTokens,
            plugins: agentPluginStore.configuration
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.agentManager.sendPrompt(prompt, sessionID: requestedSessionID) { [weak self] promptResult in
                    guard let self else { return }
                    self.isRequestInFlight = false
                    switch promptResult {
                    case let .success(answer):
                        self.showSpeech(answer, duration: 45)
                        self.petView.showAffection()
                    case let .failure(error):
                        self.handleAgentPromptFailure(
                            question: question,
                            error: error,
                            allowsDirectFallback: fileSession == nil
                        )
                    }
                }
            case let .failure(error):
                self.isRequestInFlight = false
                if fileSession == nil {
                    self.offerDirectChatFallback(question: question, error: error)
                } else {
                    self.showSpeech(
                        "文件分析 Agent 暂时无法启动：\(error.localizedDescription)\n文件会话已保留，请稍后重试。",
                        duration: nil
                    )
                }
            }
        }
    }

    private func fileAnalysisPrompt(question: String, session: FileAnalysisSession) -> String {
        let names = session.displayNames.map { "- \($0)" }.joined(separator: "\n")
        return """
        你正在用户长期使用的 Agent 工作目录中执行任务。先读取 `\(session.relativePath)/manifest.md`，随后优先复用当前工作目录已有的 Skill、脚本和工具流程；检索附件内容时，按需使用 glob、grep、read 读取 `\(session.relativePath)/chunks/` 与 `\(session.relativePath)/normalized/`，不要在回答前无差别读取所有全文。回答时尽量注明文件名、PDF 页码、Excel 工作表与单元格坐标或标准化文本行号。`\(session.relativePath)/sources/` 中是用户拖入文件的隔离副本，绝不能尝试定位或修改用户原文件；若用户要求修改文件，只能修改工作目录里的隔离副本或另存结果，并遵循正常审批流程。

        本次文件：
        \(names)

        用户的分析要求：
        \(question)
        """
    }

    private func offerDirectChatFallback(question: String, error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "本地 Agent 无法使用"
        alert.informativeText = "\(error.localizedDescription)\n\n要改用普通 DeepSeek 对话回答这条问题吗？"
        alert.addButton(withTitle: "使用普通对话")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            sendToDeepSeek(question)
        } else {
            showError(error)
        }
    }

    private func handleAgentPromptFailure(
        question: String,
        error: Error,
        allowsDirectFallback: Bool
    ) {
        guard let agentError = error as? AgentRuntimeError else {
            if allowsDirectFallback {
                offerDirectChatFallback(question: question, error: error)
            } else {
                showSpeech(
                    "文件分析 Agent 通信失败：\(error.localizedDescription)\n文件会话已保留，请稍后重试。",
                    duration: nil
                )
            }
            return
        }
        switch agentError {
        case .taskStopped:
            showSpeech("任务已停止，Agent 已重置", duration: 6)
        case let .outputLimitReached(partial):
            showOutputLimitWarning(partial: partial, source: "Agent")
        default:
            if allowsDirectFallback {
                offerDirectChatFallback(question: question, error: error)
            } else {
                showSpeech(
                    "文件分析 Agent 出错：\(error.localizedDescription)\n文件会话已保留，请稍后重试。",
                    duration: nil
                )
            }
        }
    }

    private func showOutputLimitWarning(partial: String, source: String) {
        let warning = "⚠️ \(source) 已达到本轮最大输出 Token，以上内容可能不完整。请在 DeepSeek 设置中提高上限，或让我分段完成。"
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        showSpeech(text.isEmpty ? warning : "\(text)\n\n---\n\(warning)", duration: nil)
    }

    private func updateToolExecutionState(_ state: AgentToolExecutionState) {
        toolStatusGeneration += 1
        let generation = toolStatusGeneration

        switch state {
        case .idle:
            speechBubble.setToolStatus(nil, isRunning: false, anchoredTo: window)
        case let .waitingForApproval(toolName):
            bubbleDismissAt = nil
            speechBubble.setToolStatus(
                "等待确认：\(toolName)",
                isRunning: false,
                anchoredTo: window
            )
        case let .running(toolName):
            bubbleDismissAt = nil
            speechBubble.setToolStatus(
                "正在执行：\(toolName)",
                isRunning: true,
                anchoredTo: window
            )
        case let .succeeded(toolName):
            showTransientToolStatus("✓ 已完成：\(toolName)", generation: generation)
        case let .failed(toolName):
            showTransientToolStatus("✕ 执行失败：\(toolName)", generation: generation)
        }
    }

    private func showTransientToolStatus(_ text: String, generation: Int) {
        speechBubble.setToolStatus(text, isRunning: false, anchoredTo: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toolStatusGeneration == generation else { return }
            self.speechBubble.setToolStatus(nil, isRunning: false, anchoredTo: self.window)
        }
    }

    private func chooseAgentWorkspace() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        picker.title = "选择哈妮丝 Agent 工作目录"
        picker.message = "Agent 只能读取和操作这个目录；写入和命令仍会逐次请求确认。"
        picker.prompt = "选择目录"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        guard picker.runModal() == .OK, let url = picker.url else { return nil }
        do {
            let previousWorkspace = agentWorkspaceStore.workspaceURL()?.standardizedFileURL
            let workspaceChanged = previousWorkspace != url.standardizedFileURL
            try agentWorkspaceStore.save(url)
            agentManager.shutdown()
            releaseSecurityScopedWorkspace()
            activateSecurityScopedWorkspace(url)
            if workspaceChanged {
                fileAnalysisStore.endActiveSession()
                activeFileAnalysisSession = nil
            }
            try? fileAnalysisStore.cleanupExpiredSessions(in: url)
            if !workspaceChanged {
                activeFileAnalysisSession = fileAnalysisStore.activeSession(in: url)
            }
            resetAgentSession()
            showSpeech("Agent 工作目录已设为：\(url.lastPathComponent)", duration: 7)
            return url
        } catch {
            showError(error)
            return nil
        }
    }

    private func applyAgentPluginConfiguration(_ configuration: AgentPluginConfiguration) {
        agentPluginStore.save(configuration)
        resetAgentSession()

        guard let workspace = currentAgentWorkspace,
              let apiKey = settingsStore.apiKey()
        else {
            showSpeech("插件设置已保存，将在下次启动 Agent 时生效。", duration: 7)
            return
        }

        activateSecurityScopedWorkspace(workspace)
        showSpeech("正在应用 Harness 插件设置…", duration: nil)
        agentManager.start(
            workspace: workspace,
            apiKey: apiKey,
            model: settingsStore.selectedModel,
            maxOutputTokens: settingsStore.agentMaxOutputTokens,
            plugins: configuration
        ) { [weak self] result in
            switch result {
            case .success:
                self?.showSpeech("插件设置已生效：\(configuration.displaySummary)", duration: 8)
            case let .failure(error):
                self?.showError(error)
            }
        }
    }

    private func activateSecurityScopedWorkspace(_ workspace: URL) {
        if securityScopedWorkspace?.standardizedFileURL == workspace.standardizedFileURL { return }
        releaseSecurityScopedWorkspace()
        if workspace.startAccessingSecurityScopedResource() {
            securityScopedWorkspace = workspace
        }
    }

    private func releaseSecurityScopedWorkspace() {
        securityScopedWorkspace?.stopAccessingSecurityScopedResource()
        securityScopedWorkspace = nil
    }

    private var currentAgentWorkspace: URL? {
        agentWorkspaceStore.workspaceURL()
    }

    private var agentSessionID: String {
        if let existing = UserDefaults.standard.string(forKey: Self.agentSessionDefaultsKey), !existing.isEmpty {
            return existing
        }
        let created = "desktop-pet-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(created, forKey: Self.agentSessionDefaultsKey)
        return created
    }

    private func resetAgentSession() {
        UserDefaults.standard.removeObject(forKey: Self.agentSessionDefaultsKey)
        _ = agentSessionID
    }

    private func agentMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "本地 Agent")
        let entries: [(String, Selector)] = [
            ("选择 Agent 工作目录…", #selector(selectAgentWorkspace)),
            ("清除 Agent 工作目录", #selector(clearAgentWorkspace)),
            ("新建对话", #selector(newAgentConversation)),
            ("停止当前任务", #selector(stopAgentTask)),
            ("结束文件分析", #selector(endFileAnalysis)),
            ("清除文件分析缓存", #selector(clearFileAnalysisCache)),
            ("插件与技能…", #selector(configureAgentPlugins)),
            ("重启 Agent", #selector(restartAgent)),
            ("查看 Agent 状态", #selector(showAgentStatus))
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
        }
        let root = NSMenuItem(title: "本地 Agent", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private func showSpeech(_ text: String, duration: TimeInterval?, followLatest: Bool = false) {
        speechBubble.show(text: text, anchoredTo: window, followLatest: followLatest)
        bubbleDismissAt = duration.map { ProcessInfo.processInfo.systemUptime + $0 }
    }

    private func showError(_ error: Error) {
        showSpeech("出错了：\(error.localizedDescription)", duration: 15)
    }

    private func recordUserInteraction() {
        let now = ProcessInfo.processInfo.systemUptime
        lastInteractionAt = now
        if mood == .waiting {
            mood = .idle
            targetX = nil
            nextDecisionAt = now + 1.5
        }
    }

    private var waitingTimeoutMinutes: Int {
        if UserDefaults.standard.object(forKey: Self.waitingTimeoutDefaultsKey) == nil {
            return Self.defaultWaitingTimeoutMinutes
        }
        return min(max(UserDefaults.standard.integer(forKey: Self.waitingTimeoutDefaultsKey), 0), 1440)
    }

    private static func loadPetFrames() -> PetFrames {
        let idle = loadImage(named: "shiba") ?? fallbackImage()
        let blink = loadImage(named: "shiba-blink-v2") ?? idle
        let walking = (1...4).compactMap { loadImage(named: "shiba-walk-\($0)-v2") }
        let lifted = [
            loadImage(named: "shiba-lift-1"),
            loadImage(named: "shiba-lift-blink")
        ].compactMap { $0 }
        let waiting = loadImage(named: "shiba-waiting") ?? idle
        let waitingBlink = loadImage(named: "shiba-waiting-blink") ?? waiting
        let waitingEar = loadImage(named: "shiba-waiting-ear") ?? waiting
        let waitingTail = loadImage(named: "shiba-waiting-tail") ?? waiting
        return PetFrames(
            idle: idle,
            blink: blink,
            walking: walking,
            lifted: lifted,
            waiting: waiting,
            waitingBlink: waitingBlink,
            waitingEar: waitingEar,
            waitingTail: waitingTail
        )
    }

    private static func loadImage(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    private static func fallbackImage() -> NSImage {
        let fallback = NSImage(size: CGSize(width: 256, height: 256))
        fallback.lockFocus()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: CGRect(x: 28, y: 28, width: 200, height: 200)).fill()
        fallback.unlockFocus()
        return fallback
    }
}
