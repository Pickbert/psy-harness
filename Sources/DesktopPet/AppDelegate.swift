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
        NSApp.mainMenu = AppMainMenu.make()
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
            accessibilityDescription: "哈妮丝"
        )
        item.button?.toolTip = "哈妮丝"

        let menu = NSMenu()
        let chatItem = NSMenuItem(title: "开始本轮生涯规划…", action: #selector(startChat), keyEquivalent: "0")
        chatItem.keyEquivalentModifierMask = [.command, .option]
        chatItem.target = self
        menu.addItem(chatItem)
        self.chatItem = chatItem

        let endConsultationItem = NSMenuItem(
            title: "结束本轮生涯规划",
            action: #selector(newAgentConversation),
            keyEquivalent: ""
        )
        endConsultationItem.target = self
        menu.addItem(endConsultationItem)

        let deepSeekItem = NSMenuItem(title: "职业咨询模型设置…", action: #selector(configureDeepSeek), keyEquivalent: "")
        deepSeekItem.target = self
        menu.addItem(deepSeekItem)
        if AgentProcessManager.platformSupported {
            let agentMenu = NSMenu(title: "生涯规划助手")
            let agentEntries: [(String, Selector)] = [
                ("选择生涯资料目录…", #selector(selectAgentWorkspace)),
                ("清除生涯资料目录", #selector(clearAgentWorkspace)),
                ("停止当前处理", #selector(stopAgentTask)),
                ("生涯规划助手设置…", #selector(configureAgentSettings)),
                ("重启生涯规划助手", #selector(restartAgent)),
                ("查看生涯规划助手状态", #selector(showAgentStatus))
            ]
            for (title, action) in agentEntries {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                agentMenu.addItem(entry)
            }
            let agentRoot = NSMenuItem(title: "生涯规划助手", action: nil, keyEquivalent: "")
            agentRoot.submenu = agentMenu
            menu.addItem(agentRoot)
        }
        let waitingItem = NSMenuItem(title: "设置陪伴等待时间…", action: #selector(configureWaiting), keyEquivalent: "")
        waitingItem.target = self
        menu.addItem(waitingItem)
        menu.addItem(.separator())

        let callItem = NSMenuItem(title: "呼唤职业咨询猫", action: #selector(callPet), keyEquivalent: "")
        callItem.target = self
        menu.addItem(callItem)

        let pauseItem = NSMenuItem(title: "暂停陪伴", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseItem = pauseItem

        let visibilityItem = NSMenuItem(title: "隐藏职业咨询猫", action: #selector(toggleVisibility), keyEquivalent: "")
        visibilityItem.target = self
        menu.addItem(visibilityItem)
        self.visibilityItem = visibilityItem

        let sizeMenu = NSMenu(title: "职业咨询猫大小")
        for (title, size) in [("小", 150), ("中", 190), ("大", 240)] {
            let sizeItem = NSMenuItem(title: title, action: #selector(changeSize(_:)), keyEquivalent: "")
            sizeItem.target = self
            sizeItem.representedObject = size
            sizeMenu.addItem(sizeItem)
        }
        let sizeRootItem = NSMenuItem(title: "职业咨询猫大小", action: nil, keyEquivalent: "")
        sizeRootItem.submenu = sizeMenu
        menu.addItem(sizeRootItem)

        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "回到屏幕右下角", action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let aboutItem = NSMenuItem(title: "关于哈妮丝", action: #selector(showAbout), keyEquivalent: "")
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
        chatItem?.title = "开始本轮生涯规划…（⌥⌘0 已被占用）"
        chatItem?.keyEquivalent = ""
    }

    private func openDeepSeekFromGlobalHotKey() {
        guard let petController else { return }
        if !petController.isVisible {
            petController.show()
            visibilityItem?.title = "隐藏职业咨询猫"
        }
        NSApp.activate(ignoringOtherApps: true)
        petController.startDeepSeekChat()
    }

    @objc private func callPet() {
        petController?.callPet()
        visibilityItem?.title = "隐藏职业咨询猫"
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

    @objc private func configureAgentSettings() {
        petController?.configureAgentSettings()
    }

    @objc private func showAgentStatus() {
        petController?.showAgentStatus()
    }

    @objc private func togglePause() {
        guard let petController else { return }
        petController.isPaused.toggle()
        pauseItem?.title = petController.isPaused ? "继续陪伴" : "暂停陪伴"
    }

    @objc private func toggleVisibility() {
        guard let petController else { return }
        if petController.isVisible {
            petController.hide()
            visibilityItem?.title = "显示职业咨询猫"
        } else {
            petController.show()
            visibilityItem?.title = "隐藏职业咨询猫"
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
        alert.messageText = "哈妮丝"
        alert.informativeText = "一只会陪学生探索专业、职业与成长路径，也会散步和打盹的职业咨询猫。\n\n你可以和哈妮丝讨论选科、选专业、升学、实习、求职和长期生涯方向；她会帮助你认识自己、比较选项并制定行动计划，但不会替你作决定或承诺结果。\n\n拖动她可以改变位置，单击她会获得回应。\n\n作者：pry"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好呀")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
