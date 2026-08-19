import AppKit

enum AppMainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem(title: "哈妮丝", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "哈妮丝")
        applicationMenu.addItem(item(
            title: "退出哈妮丝",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(item(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(item(
            title: "重做",
            action: Selector(("redo:")),
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(item(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(item(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(item(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(item(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }

    private static func item(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}
