import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var petController: PetController?
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var visibilityItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        petController = PetController()
        configureStatusItem()
        petController?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        let chatItem = NSMenuItem(title: "开始 AI 对话…", action: #selector(startChat), keyEquivalent: "")
        chatItem.target = self
        menu.addItem(chatItem)

        let deepSeekItem = NSMenuItem(title: "设置 DeepSeek API…", action: #selector(configureDeepSeek), keyEquivalent: "")
        deepSeekItem.target = self
        menu.addItem(deepSeekItem)
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
