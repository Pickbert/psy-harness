import Foundation

struct AgentJSONRPCLineFramer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var frames: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: line),
                  let frame = value as? [String: Any]
            else { continue }
            frames.append(frame)
        }
        return frames
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
