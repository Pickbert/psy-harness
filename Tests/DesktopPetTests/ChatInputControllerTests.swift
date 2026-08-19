import AppKit
import XCTest
@testable import DesktopPet

final class ChatInputControllerTests: XCTestCase {
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
}
