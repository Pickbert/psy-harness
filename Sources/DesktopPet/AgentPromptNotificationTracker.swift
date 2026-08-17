import Foundation

struct AgentPromptNotification {
    let method: String
    let params: [String: Any]
}

enum AgentPromptTrackingError: LocalizedError {
    case notificationBufferOverflow

    var errorDescription: String? {
        switch self {
        case .notificationBufferOverflow:
            return "Agent 在确认问题入队前发送了过多通知。"
        }
    }
}

/// Owns one Harness prompt interval. Notifications before the durable inbox
/// receipt belong to session restoration or earlier queued work and must not be
/// attributed to the newly submitted prompt.
struct AgentPromptNotificationTracker {
    private(set) var messageID: String?
    private(set) var receiptObserved = false
    private var bufferedNotifications: [AgentPromptNotification] = []
    private let maximumBufferedNotifications: Int

    init(maximumBufferedNotifications: Int = 4_096) {
        self.maximumBufferedNotifications = maximumBufferedNotifications
    }

    mutating func reset() {
        messageID = nil
        receiptObserved = false
        bufferedNotifications.removeAll(keepingCapacity: true)
    }

    mutating func setMessageID(_ messageID: String) throws -> [AgentPromptNotification] {
        self.messageID = messageID
        return drainFromReceiptIfPossible()
    }

    mutating func receive(method: String, params: [String: Any]) throws -> [AgentPromptNotification] {
        let notification = AgentPromptNotification(method: method, params: params)
        if receiptObserved {
            return [notification]
        }

        bufferedNotifications.append(notification)
        guard bufferedNotifications.count <= maximumBufferedNotifications else {
            throw AgentPromptTrackingError.notificationBufferOverflow
        }
        return drainFromReceiptIfPossible()
    }

    private mutating func drainFromReceiptIfPossible() -> [AgentPromptNotification] {
        guard !receiptObserved, let messageID,
              let receiptIndex = bufferedNotifications.firstIndex(where: {
                  Self.isInboxReceipt($0, messageID: messageID)
              })
        else { return [] }

        receiptObserved = true
        let ownedNotifications = Array(bufferedNotifications[receiptIndex...])
        bufferedNotifications.removeAll(keepingCapacity: true)
        return ownedNotifications
    }

    static func isInboxReceipt(_ notification: AgentPromptNotification, messageID: String) -> Bool {
        guard notification.method == "session.event",
              let event = notification.params["event"] as? [String: Any],
              event["type"] as? String == "agent/inbox/spliced",
              let data = event["data"] as? [String: Any],
              let inserted = data["inserted"] as? [[String: Any]]
        else { return false }

        return inserted.contains { $0["id"] as? String == messageID }
    }
}
