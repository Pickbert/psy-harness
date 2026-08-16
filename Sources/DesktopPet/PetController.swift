import AppKit

final class PetController: NSObject {
    private(set) var isVisible = false

    var isPaused = false {
        didSet {
            mood = .idle
            nextDecisionAt = ProcessInfo.processInfo.systemUptime + 2
        }
    }

    private let window: NSWindow
    private let petView: PetView
    private let settingsStore = DeepSeekSettingsStore()
    private let deepSeekClient = DeepSeekClient()
    private let speechBubble = SpeechBubbleController()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var nextDecisionAt = ProcessInfo.processInfo.systemUptime + 2
    private var actionEndsAt = ProcessInfo.processInfo.systemUptime + 2
    private var targetX: CGFloat?
    private var bubbleDismissAt: TimeInterval?
    private var conversationHistory: [DeepSeekMessage] = []
    private var isRequestInFlight = false
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.contentView = petView
        window.title = "桌面小柴"
        window.setAccessibilityTitle("桌面小柴")

        petView.onDragEnded = { [weak self] in
            self?.finishDragging()
        }
        petView.onTripleClick = { [weak self] in
            self?.startDeepSeekChat()
        }
        petView.onContextMenu = { [weak self] event in
            self?.showContextMenu(with: event)
        }

        resetPosition(animated: false)
        startTimer()
    }

    deinit {
        stop()
    }

    func show() {
        window.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        window.orderOut(nil)
        speechBubble.hide()
        isVisible = false
    }

    func callPet() {
        show()
        resetPosition(animated: true)
        petView.showAffection()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        speechBubble.hide()
    }

    @objc func configureDeepSeek() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "DeepSeek 设置"
        alert.informativeText = settingsStore.apiKey() == nil
            ? "API Key 将安全保存在 macOS 钥匙串中。"
            : "API Key 已配置。留空可保持原密钥不变。"

        let accessory = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 74))
        let keyField = NSSecureTextField(frame: CGRect(x: 0, y: 42, width: 360, height: 24))
        keyField.placeholderString = settingsStore.apiKey() == nil ? "DeepSeek API Key" : "已安全保存"
        let modelPopup = NSPopUpButton(frame: CGRect(x: 0, y: 4, width: 360, height: 28))
        DeepSeekModel.allCases.forEach { modelPopup.addItem(withTitle: $0.displayName) }
        modelPopup.selectItem(at: DeepSeekModel.allCases.firstIndex(of: settingsStore.selectedModel) ?? 0)
        accessory.addSubview(keyField)
        accessory.addSubview(modelPopup)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if settingsStore.apiKey() != nil {
            alert.addButton(withTitle: "清除密钥")
        }
        alert.window.initialFirstResponder = keyField

        let result = alert.runModal()
        if result == .alertThirdButtonReturn {
            do {
                try settingsStore.clearAPIKey()
                conversationHistory.removeAll()
                showSpeech("DeepSeek 密钥已清除。", duration: 4)
            } catch {
                showError(error)
            }
            return
        }
        guard result == .alertFirstButtonReturn else { return }

        do {
            let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try settingsStore.saveAPIKey(key)
            }
            settingsStore.selectedModel = DeepSeekModel.allCases[modelPopup.indexOfSelectedItem]
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
        guard !isRequestInFlight else {
            showSpeech("我还在想上一条问题，请稍等一下～", duration: 5)
            return
        }
        guard settingsStore.apiKey() != nil else {
            configureDeepSeek()
            guard settingsStore.apiKey() != nil else { return }
            return startDeepSeekChat()
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "和桌面小柴聊聊"
        alert.informativeText = "输入内容后按回车发送给 DeepSeek。"
        let inputField = NSTextField(frame: CGRect(x: 0, y: 0, width: 380, height: 26))
        inputField.placeholderString = "想问小柴什么？"
        alert.accessoryView = inputField
        alert.addButton(withTitle: "发送")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = inputField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let question = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        sendToDeepSeek(question)
    }

    func setPetSize(_ size: CGFloat) {
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

        guard !isPaused, isVisible else { return }

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

    private func finishDragging() {
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
        let menu = NSMenu(title: "桌面小柴")
        let chatItem = NSMenuItem(title: "开始 AI 对话…", action: #selector(startDeepSeekChat), keyEquivalent: "")
        chatItem.target = self
        menu.addItem(chatItem)
        let settingsItem = NSMenuItem(title: "设置 DeepSeek API…", action: #selector(configureDeepSeek), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
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

        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await deepSeekClient.reply(
                    to: question,
                    apiKey: apiKey,
                    model: model,
                    history: history
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
            } catch {
                await MainActor.run {
                    self.isRequestInFlight = false
                    self.showError(error)
                }
            }
        }
    }

    private func showSpeech(_ text: String, duration: TimeInterval?) {
        speechBubble.show(text: text, anchoredTo: window)
        bubbleDismissAt = duration.map { ProcessInfo.processInfo.systemUptime + $0 }
    }

    private func showError(_ error: Error) {
        showSpeech("出错了：\(error.localizedDescription)", duration: 15)
    }

    private static func loadPetFrames() -> PetFrames {
        let idle = loadImage(named: "shiba") ?? fallbackImage()
        let blink = loadImage(named: "shiba-blink-v2") ?? idle
        let walking = (1...4).compactMap { loadImage(named: "shiba-walk-\($0)-v2") }
        return PetFrames(idle: idle, blink: blink, walking: walking)
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
