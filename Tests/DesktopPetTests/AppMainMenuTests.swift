import AppKit
import XCTest
@testable import DesktopPet

final class AppMainMenuTests: XCTestCase {
    func testEditMenuProvidesStandardResponderChainCommands() throws {
        let mainMenu = AppMainMenu.make()
        let editMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "编辑" }?.submenu)

        assertItem(editMenu, action: "undo:", key: "z", modifiers: [.command])
        assertItem(editMenu, action: "redo:", key: "z", modifiers: [.command, .shift])
        assertItem(editMenu, action: "cut:", key: "x", modifiers: [.command])
        assertItem(editMenu, action: "copy:", key: "c", modifiers: [.command])
        assertItem(editMenu, action: "paste:", key: "v", modifiers: [.command])
        assertItem(editMenu, action: "selectAll:", key: "a", modifiers: [.command])
    }

    func testApplicationMenuKeepsStandardQuitShortcut() throws {
        let mainMenu = AppMainMenu.make()
        let applicationMenu = try XCTUnwrap(
            mainMenu.items.first { $0.title == "哈妮丝" }?.submenu
        )
        assertItem(
            applicationMenu,
            action: "terminate:",
            key: "q",
            modifiers: [.command]
        )
    }

    private func assertItem(
        _ menu: NSMenu,
        action: String,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let item = menu.items.first { $0.action == Selector((action)) }
        XCTAssertNotNil(item, file: file, line: line)
        XCTAssertEqual(item?.keyEquivalent, key, file: file, line: line)
        XCTAssertEqual(item?.keyEquivalentModifierMask, modifiers, file: file, line: line)
        XCTAssertNil(item?.target, file: file, line: line)
    }
}
