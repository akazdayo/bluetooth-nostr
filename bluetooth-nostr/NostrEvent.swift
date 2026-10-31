import Foundation
import CryptoKit
import Security

enum NostrError: Error { case invalidKey, random, keychain(OSStatus), encoding, signature }

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(strictHex: String, bytes: Int) {
        guard strictHex.utf8.count == bytes * 2,
              strictHex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.init()
        var index = strictHex.startIndex
        for _ in 0..<bytes {
            let next = strictHex.index(index, offsetBy: 2)
            guard let byte = UInt8(strictHex[index..<next], radix: 16) else { return nil }
            append(byte); index = next
        }
    }
}

struct NostrEvent: Codable, Identifiable {
    let id: String
    let pubkey: String
    let created_at: Int64
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String

    private static func encodedString(_ string: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let value = String(data: try encoder.encode(string), encoding: .utf8) else { throw NostrError.encoding }
        return value
    }
    static func digest(pubkey: String, timestamp: Int64, kind: Int, tags: [[String]], content: String) throws -> Data {
        let encodedTags = try tags.map { tag in "[" + (try tag.map(encodedString)).joined(separator: ",") + "]" }.joined(separator: ",")
        let serialized = "[0,\(try encodedString(pubkey)),\(timestamp),\(kind),[\(encodedTags)],\(try encodedString(content))]"
        return Data(SHA256.hash(data: Data(serialized.utf8)))
    }
    func isValid() -> Bool {
        guard (0...65535).contains(kind), let pub = Data(strictHex: pubkey, bytes: 32),
              let hash = Data(strictHex: id, bytes: 32), let signature = Data(strictHex: sig, bytes: 64),
              let computed = try? Self.digest(pubkey: pubkey, timestamp: created_at, kind: kind, tags: tags, content: content), hash == computed else { return false }
        return pub.withUnsafeBytes { p in hash.withUnsafeBytes { h in signature.withUnsafeBytes { s in
            nostr_verify(p.bindMemory(to: UInt8.self).baseAddress!, h.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!) == 1
        } } }
    }
}

struct NostrIdentity {
    private let secret: Data
    let publicKey: String
    private static let service = "BluetoothNostr.identity.v1"
    static func loadOrCreate() throws -> NostrIdentity {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "secret", kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try NostrIdentity(secret: data) }
        guard status == errSecItemNotFound else { throw NostrError.keychain(status) }
        var bytes = Data(count: 32)
        repeat {
            guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { throw NostrError.random }
        } while (try? NostrIdentity(secret: bytes)) == nil
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "secret", kSecValueData as String: bytes,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw NostrError.keychain(addStatus) }
        return try NostrIdentity(secret: bytes)
    }
    private init(secret: Data) throws {
        guard secret.count == 32 else { throw NostrError.invalidKey }
        var pub = Data(count: 32)
        let ok = secret.withUnsafeBytes { s in pub.withUnsafeMutableBytes { p in
            nostr_public_key(s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!)
        } }
        guard ok == 1 else { throw NostrError.invalidKey }
        self.secret = secret; self.publicKey = pub.hex
    }
    func makeEvent(kind: Int, content: String, tags: [[String]] = []) throws -> NostrEvent {
        guard (0...65535).contains(kind) else { throw NostrError.encoding }
        let timestamp = Int64(Date().timeIntervalSince1970)
        let hash = try NostrEvent.digest(pubkey: publicKey, timestamp: timestamp, kind: kind, tags: tags, content: content)
        var aux = Data(count: 32), signature = Data(count: 64)
        guard aux.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { throw NostrError.random }
        let ok = secret.withUnsafeBytes { s in hash.withUnsafeBytes { h in aux.withUnsafeBytes { a in signature.withUnsafeMutableBytes { sig in
            nostr_sign(s.bindMemory(to: UInt8.self).baseAddress!, h.bindMemory(to: UInt8.self).baseAddress!, a.bindMemory(to: UInt8.self).baseAddress!, sig.bindMemory(to: UInt8.self).baseAddress!)
        } } } }
        guard ok == 1 else { throw NostrError.signature }
        return NostrEvent(id: hash.hex, pubkey: publicKey, created_at: timestamp, kind: kind, tags: tags, content: content, sig: signature.hex)
    }
}
