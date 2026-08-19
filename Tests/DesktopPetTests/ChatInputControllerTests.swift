import AppKit
import XCTest
@testable import DesktopPet

final class ChatInputControllerTests: XCTestCase {
    func testCommandVPastesIntoTheChatField() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.general
        let savedItems = Self.snapshot(pasteboard)
        defer { Self.restore(savedItems, to: pasteboard) }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("从剪贴板粘贴", forType: .string))

        let controller = ChatInputController()
        XCTAssertTrue(controller.prompt(on: nil) { _ in })
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: controller.panelForTesting.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))

        XCTAssertTrue(controller.panelForTesting.performKeyEquivalent(with: event))
        XCTAssertEqual(controller.inputTextForTesting, "从剪贴板粘贴")
        controller.cancelPrompt()
    }

    func testPromptReturnsImmediatelyAndRejectsASecondPrompt() {
        _ = NSApplication.shared
        let controller = ChatInputController()
        var firstResults: [String?] = []
        var secondCompletionCalled = false

        XCTAssertTrue(controller.prompt(on: nil) { firstResults.append($0) })
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.prompt(on: nil) { _ in secondCompletionCalled = true })

        controller.cancelPrompt()

        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(firstResults.count, 1)
        XCTAssertNil(firstResults[0])
        XCTAssertFalse(secondCompletionCalled)
    }

    func testRepeatedPromptRecoversAnOrderedOutPanelWithoutReplacingCompletion() {
        _ = NSApplication.shared
        let controller = ChatInputController()
        var firstResults: [String?] = []
        var secondCompletionCalled = false

        XCTAssertTrue(controller.prompt(on: nil) { firstResults.append($0) })
        controller.panelForTesting.orderOut(nil)
        XCTAssertFalse(controller.isVisible)

        XCTAssertFalse(controller.prompt(on: nil) { _ in secondCompletionCalled = true })
        XCTAssertTrue(controller.isVisible)

        controller.cancelPrompt()

        XCTAssertEqual(firstResults.count, 1)
        XCTAssertNil(firstResults[0])
        XCTAssertFalse(secondCompletionCalled)
    }

    func testChatStartGateBlocksWhileFileAnalysisIsPreparing() {
        XCTAssertEqual(
            ChatStartGate.blockMessage(
                isRequestInFlight: false,
                isPreparingFileAnalysis: true
            ),
            "文件仍在本地解析，请稍等一下～"
        )
        XCTAssertEqual(
            ChatStartGate.blockMessage(
                isRequestInFlight: true,
                isPreparingFileAnalysis: false
            ),
            "我还在想上一条问题，请稍等一下～"
        )
        XCTAssertNil(
            ChatStartGate.blockMessage(
                isRequestInFlight: false,
                isPreparingFileAnalysis: false
            )
        )
    }

    private typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
    }

    private static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
