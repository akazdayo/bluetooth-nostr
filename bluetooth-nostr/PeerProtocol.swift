import Foundation

/// Private BLE protocol v1; events themselves remain unmodified NIP-01 JSON.
struct PeerMessage: Codable {
    let version: Int
    let type: String
    var ids: [String]?
    var events: [NostrEvent]?
    init(_ type: String, ids: [String]? = nil, events: [NostrEvent]? = nil) {
        self.version = 1; self.type = type; self.ids = ids; self.events = events
    }
}

enum PeerFraming {
    static let maxPayload = 65_536
    static let maxEvent = 16_384
    static let maxIDs = 256
    static let maxQueued = 8_388_608
    static let maxSharedEvents = 256
    static func encode(_ message: PeerMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count > 0 && payload.count <= maxPayload else { throw NostrError.encoding }
        var size = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + payload
    }
}

struct PeerDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [PeerMessage] {
        guard buffer.count + data.count <= PeerFraming.maxPayload + 4 else { throw NostrError.encoding }
        buffer.append(data)
        var messages: [PeerMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0 && length <= PeerFraming.maxPayload else { throw NostrError.encoding }
            guard buffer.count >= length + 4 else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(length + 4)
            let message = try JSONDecoder().decode(PeerMessage.self, from: payload)
            guard message.version == 1 else { throw NostrError.encoding }
            messages.append(message)
        }
        return messages
    }
}
