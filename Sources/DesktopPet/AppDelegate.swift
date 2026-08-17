import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let deepSeekHotKeySignature: OSType = 0x44504730 // "DPG0"
    private static let deepSeekHotKeyID: UInt32 = 1

    private var petController: PetController?
    private var statusItem: NSStatusItem?
    private var chatItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var visibilityItem: NSMenuItem?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        petController = PetController()
        configureStatusItem()
        registerDeepSeekHotKey()
        petController?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterDeepSeekHotKey()
        petController?.stop()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "pawprint.fill",
            accessibilityDescription: "桌面小柴"
        )
        item.button?.toolTip = "桌面小柴"

        let menu = NSMenu()
        let chatItem = NSMenuItem(title: "开始 AI 对话…", action: #selector(startChat), keyEquivalent: "0")
        chatItem.keyEquivalentModifierMask = [.command, .option]
        chatItem.target = self
        menu.addItem(chatItem)
        self.chatItem = chatItem

        let deepSeekItem = NSMenuItem(title: "设置 DeepSeek API…", action: #selector(configureDeepSeek), keyEquivalent: "")
        deepSeekItem.target = self
        menu.addItem(deepSeekItem)
        if AgentProcessManager.platformSupported {
            let agentMenu = NSMenu(title: "本地 Agent")
            let agentEntries: [(String, Selector)] = [
                ("选择 Agent 工作目录…", #selector(selectAgentWorkspace)),
                ("清除 Agent 工作目录", #selector(clearAgentWorkspace)),
                ("新建对话", #selector(newAgentConversation)),
                ("停止当前任务", #selector(stopAgentTask)),
                ("插件与技能…", #selector(configureAgentPlugins)),
                ("重启 Agent", #selector(restartAgent)),
                ("查看 Agent 状态", #selector(showAgentStatus))
            ]
            for (title, action) in agentEntries {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                agentMenu.addItem(entry)
            }
            let agentRoot = NSMenuItem(title: "本地 Agent", action: nil, keyEquivalent: "")
            agentRoot.submenu = agentMenu
            menu.addItem(agentRoot)
        }
        let waitingItem = NSMenuItem(title: "设置等待时间…", action: #selector(configureWaiting), keyEquivalent: "")
        waitingItem.target = self
        menu.addItem(waitingItem)
        menu.addItem(.separator())

        let callItem = NSMenuItem(title: "呼唤小狗", action: #selector(callPet), keyEquivalent: "")
        callItem.target = self
        menu.addItem(callItem)

        let pauseItem = NSMenuItem(title: "暂停活动", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseItem = pauseItem

        let visibilityItem = NSMenuItem(title: "隐藏小狗", action: #selector(toggleVisibility), keyEquivalent: "")
        visibilityItem.target = self
        menu.addItem(visibilityItem)
        self.visibilityItem = visibilityItem

        let sizeMenu = NSMenu(title: "小狗大小")
        for (title, size) in [("小", 150), ("中", 190), ("大", 240)] {
            let sizeItem = NSMenuItem(title: title, action: #selector(changeSize(_:)), keyEquivalent: "")
            sizeItem.target = self
            sizeItem.representedObject = size
            sizeMenu.addItem(sizeItem)
        }
        let sizeRootItem = NSMenuItem(title: "小狗大小", action: nil, keyEquivalent: "")
        sizeRootItem.submenu = sizeMenu
        menu.addItem(sizeRootItem)

        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "回到屏幕右下角", action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let aboutItem = NSMenuItem(title: "关于桌面小柴", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func registerDeepSeekHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID(signature: 0, id: 0)
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard
                    status == noErr,
                    hotKeyID.signature == AppDelegate.deepSeekHotKeySignature,
                    hotKeyID.id == AppDelegate.deepSeekHotKeyID
                else { return OSStatus(eventNotHandledErr) }

                let appDelegate = Unmanaged<AppDelegate>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    appDelegate.openDeepSeekFromGlobalHotKey()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
        guard handlerStatus == noErr else {
            markHotKeyUnavailable()
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.deepSeekHotKeySignature,
            id: Self.deepSeekHotKeyID
        )
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_0),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registrationStatus != noErr {
            if let hotKeyHandler {
                RemoveEventHandler(hotKeyHandler)
                self.hotKeyHandler = nil
            }
            markHotKeyUnavailable()
        }
    }

    private func unregisterDeepSeekHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }
    }

    private func markHotKeyUnavailable() {
        chatItem?.title = "开始 AI 对话…（⌥⌘0 已被占用）"
        chatItem?.keyEquivalent = ""
    }

    private func openDeepSeekFromGlobalHotKey() {
        guard let petController else { return }
        if !petController.isVisible {
            petController.show()
            visibilityItem?.title = "隐藏小狗"
        }
        NSApp.activate(ignoringOtherApps: true)
        petController.startDeepSeekChat()
    }

    @objc private func callPet() {
        petController?.callPet()
        visibilityItem?.title = "隐藏小狗"
    }

    @objc private func startChat() {
        petController?.startDeepSeekChat()
    }

    @objc private func configureDeepSeek() {
        petController?.configureDeepSeek()
    }

    @objc private func configureWaiting() {
        petController?.configureWaiting()
    }

    @objc private func selectAgentWorkspace() {
        petController?.selectAgentWorkspace()
    }

    @objc private func clearAgentWorkspace() {
        petController?.clearAgentWorkspace()
    }

    @objc private func newAgentConversation() {
        petController?.newAgentConversation()
    }

    @objc private func stopAgentTask() {
        petController?.stopAgentTask()
    }

    @objc private func restartAgent() {
        petController?.restartAgent()
    }

    @objc private func configureAgentPlugins() {
        petController?.configureAgentPlugins()
    }

    @objc private func showAgentStatus() {
        petController?.showAgentStatus()
    }

    @objc private func togglePause() {
        guard let petController else { return }
        petController.isPaused.toggle()
        pauseItem?.title = petController.isPaused ? "继续活动" : "暂停活动"
    }

    @objc private func toggleVisibility() {
        guard let petController else { return }
        if petController.isVisible {
            petController.hide()
            visibilityItem?.title = "显示小狗"
        } else {
            petController.show()
            visibilityItem?.title = "隐藏小狗"
        }
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Int else { return }
        petController?.setPetSize(CGFloat(size))
    }

    @objc private func resetPosition() {
        petController?.resetPosition(animated: true)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "桌面小柴"
        alert.informativeText = "一只会散步、打盹，也喜欢被摸摸的 macOS 桌面宠物。\n\n拖动它可以改变位置，单击它会获得回应。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好呀")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
