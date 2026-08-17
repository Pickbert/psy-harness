import XCTest
@testable import DesktopPet

final class AgentPromptNotificationTrackerTests: XCTestCase {
    func testRestorationNotificationsBeforeReceiptAreDiscarded() throws {
        var tracker = AgentPromptNotificationTracker()

        XCTAssertTrue(try tracker.receive(method: "session.status", params: status("running")).isEmpty)
        XCTAssertTrue(try tracker.receive(method: "session.event", params: event(
            type: "turn/end",
            data: ["reason": ["kind": "error"]]
        )).isEmpty)
        XCTAssertTrue(try tracker.receive(method: "session.status", params: status("idle")).isEmpty)
        XCTAssertTrue(try tracker.setMessageID("new-message").isEmpty)

        let receipt = try tracker.receive(
            method: "session.event",
            params: inboxReceipt(messageID: "new-message")
        )
        XCTAssertEqual(receipt.count, 1)
        XCTAssertTrue(tracker.receiptObserved)

        let idle = try tracker.receive(method: "session.status", params: status("idle"))
        XCTAssertEqual(idle.count, 1)
    }

    func testNotificationsArrivingBeforePromptResponseReplayFromMatchingReceipt() throws {
        var tracker = AgentPromptNotificationTracker()

        _ = try tracker.receive(method: "session.status", params: status("idle"))
        _ = try tracker.receive(method: "session.event", params: inboxReceipt(messageID: "owned-message"))
        _ = try tracker.receive(method: "session.status", params: status("running"))
        _ = try tracker.receive(method: "session.event", params: event(
            type: "assistant/message",
            data: ["message": ["content": [["type": "text", "text": "ok"]]]]
        ))
        _ = try tracker.receive(method: "session.status", params: status("idle"))

        let replayed = try tracker.setMessageID("owned-message")

        XCTAssertEqual(replayed.count, 4)
        XCTAssertTrue(AgentPromptNotificationTracker.isInboxReceipt(replayed[0], messageID: "owned-message"))
        XCTAssertEqual(replayed.last?.params["status"] as? String, "idle")
    }

    func testReceiptForDifferentMessageDoesNotOpenInterval() throws {
        var tracker = AgentPromptNotificationTracker()
        _ = try tracker.setMessageID("expected")

        XCTAssertTrue(try tracker.receive(
            method: "session.event",
            params: inboxReceipt(messageID: "other")
        ).isEmpty)
        XCTAssertFalse(tracker.receiptObserved)

        let matched = try tracker.receive(
            method: "session.event",
            params: inboxReceipt(messageID: "expected")
        )
        XCTAssertEqual(matched.count, 1)
        XCTAssertTrue(tracker.receiptObserved)
    }

    func testNotificationBufferIsBounded() throws {
        var tracker = AgentPromptNotificationTracker(maximumBufferedNotifications: 1)
        XCTAssertTrue(try tracker.receive(method: "session.status", params: status("running")).isEmpty)
        XCTAssertThrowsError(try tracker.receive(method: "session.status", params: status("idle"))) { error in
            XCTAssertTrue(error is AgentPromptTrackingError)
        }
    }

    func testNestedHarnessErrorMessageIsPreserved() {
        let message = AgentProcessManager.turnFailureMessage([
            "kind": "error",
            "error": ["message": "provider unavailable", "code": "SERVER"]
        ])

        XCTAssertEqual(message, "provider unavailable（SERVER）")
        XCTAssertNil(AgentProcessManager.turnFailureMessage(["kind": "completed"]))
    }

    private func status(_ value: String) -> [String: Any] {
        ["sessionId": "session", "status": value]
    }

    private func event(type: String, data: [String: Any]) -> [String: Any] {
        ["sessionId": "session", "event": ["type": type, "data": data]]
    }

    private func inboxReceipt(messageID: String) -> [String: Any] {
        event(type: "agent/inbox/spliced", data: [
            "target": "next-turn",
            "inserted": [["id": messageID]]
        ])
    }
}
