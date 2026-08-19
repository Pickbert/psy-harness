import XCTest
@testable import DesktopPet

final class AgentTranscriptDeliveryGateTests: XCTestCase {
    func testBackpressureKeepsOnlyTheLatestSnapshot() throws {
        var gate = AgentTranscriptDeliveryGate()
        gate.beginGeneration()

        XCTAssertTrue(gate.update(text: "一"))
        XCTAssertFalse(gate.update(text: "一二"))
        let first = try XCTUnwrap(gate.takeScheduledDelivery(
            expectedGeneration: gate.generation
        ))
        XCTAssertEqual(first.text, "一二")

        XCTAssertFalse(gate.update(text: "一二三"))
        XCTAssertFalse(gate.update(text: "一二三四"))
        XCTAssertTrue(gate.acknowledge(first))

        let latest = try XCTUnwrap(gate.takeScheduledDelivery(
            expectedGeneration: gate.generation
        ))
        XCTAssertEqual(latest.text, "一二三四")
        XCTAssertNotEqual(first.id, latest.id)
    }

    func testOldGenerationCannotConsumeOrAcknowledgeNewWork() throws {
        var gate = AgentTranscriptDeliveryGate()
        gate.beginGeneration()
        XCTAssertTrue(gate.update(text: "旧回答"))
        let oldGeneration = gate.generation
        let oldDelivery = try XCTUnwrap(gate.takeScheduledDelivery(
            expectedGeneration: oldGeneration
        ))

        gate.invalidateGeneration()
        XCTAssertFalse(gate.update(text: "新回答"))
        XCTAssertNil(gate.takeScheduledDelivery(expectedGeneration: oldGeneration))
        XCTAssertTrue(gate.acknowledge(oldDelivery))

        let newDelivery = try XCTUnwrap(gate.takeScheduledDelivery(
            expectedGeneration: gate.generation
        ))
        XCTAssertEqual(newDelivery.text, "新回答")
        XCTAssertNotEqual(newDelivery.generation, oldGeneration)
        XCTAssertFalse(gate.acknowledge(oldDelivery))
    }

    func testInvalidationDropsScheduledTextWithoutAnInFlightDelivery() {
        var gate = AgentTranscriptDeliveryGate()
        gate.beginGeneration()
        XCTAssertTrue(gate.update(text: "不应显示"))
        let oldGeneration = gate.generation

        gate.invalidateGeneration()

        XCTAssertNil(gate.takeScheduledDelivery(expectedGeneration: oldGeneration))
        XCTAssertFalse(gate.isFlushScheduled)
    }
}
