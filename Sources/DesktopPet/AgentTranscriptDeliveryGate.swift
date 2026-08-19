import Foundation

struct AgentTranscriptDelivery: Equatable {
    let id: Int
    let generation: Int
    let text: String
}

/// Queue-confined state for coalescing transcript snapshots with UI backpressure.
struct AgentTranscriptDeliveryGate {
    private(set) var generation = 0
    private(set) var isFlushScheduled = false
    private(set) var inFlightDelivery: AgentTranscriptDelivery?
    private var pendingText: String?
    private var nextDeliveryID = 1

    mutating func beginGeneration() {
        generation &+= 1
        pendingText = nil
        isFlushScheduled = false
    }

    /// Returns true when the owner should schedule an 80 ms flush.
    mutating func update(text: String) -> Bool {
        pendingText = text
        guard inFlightDelivery == nil, !isFlushScheduled else { return false }
        isFlushScheduled = true
        return true
    }

    mutating func takeScheduledDelivery(
        expectedGeneration: Int
    ) -> AgentTranscriptDelivery? {
        guard expectedGeneration == generation,
              isFlushScheduled,
              inFlightDelivery == nil,
              let pendingText
        else { return nil }

        isFlushScheduled = false
        self.pendingText = nil
        let delivery = AgentTranscriptDelivery(
            id: nextDeliveryID,
            generation: generation,
            text: pendingText
        )
        nextDeliveryID &+= 1
        inFlightDelivery = delivery
        return delivery
    }

    /// Returns true when newer pending text should be scheduled after the acknowledgement.
    mutating func acknowledge(_ delivery: AgentTranscriptDelivery) -> Bool {
        guard inFlightDelivery?.id == delivery.id else { return false }
        inFlightDelivery = nil
        guard pendingText != nil, !isFlushScheduled else { return false }
        isFlushScheduled = true
        return true
    }

    mutating func invalidateGeneration() {
        beginGeneration()
    }
}
