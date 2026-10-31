import Foundation
import Combine

@MainActor final class EventStore: ObservableObject {
    @Published private(set) var events: [NostrEvent] = []
    @Published private(set) var publicKey = ""
    @Published var errorMessage: String?
    @Published var draft = ""
    @Published var showingResetConfirmation = false
    private var identity: NostrIdentity?
    private let file: URL
    var onChanged: (() -> Void)?

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("nostr-events.json")
        do {
            let identity = try NostrIdentity.loadOrCreate()
            self.identity = identity
            publicKey = identity.publicKey
            if FileManager.default.fileExists(atPath: file.path) {
                let loaded = try JSONDecoder().decode([NostrEvent].self, from: Data(contentsOf: file))
                events = loaded.filter { $0.isValid() }
                if events.count != loaded.count { errorMessage = "保存データに無効なイベントが含まれています。" }
            }
        } catch { errorMessage = "鍵または投稿を読み込めませんでした: \(error)" }
    }
    func post(_ content: String) -> Bool {
        guard let identity else { errorMessage = "秘密鍵を利用できません。"; return false }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            let event = try identity.makeEvent(kind: 1, content: content)
            guard event.isValid() else { throw NostrError.signature }
            guard try JSONEncoder().encode(event).count <= PeerFraming.maxEvent else { errorMessage = "投稿が大きすぎます。16 KiB 以下にしてください。"; return false }
            try save([event] + events)
            return true
        } catch { errorMessage = "投稿を保存できませんでした: \(error)"; return false }
    }
    private func save(_ updated: [NostrEvent]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        events = updated.sorted { $0.created_at == $1.created_at ? $0.id < $1.id : $0.created_at > $1.created_at }
        onChanged?()
    }
    func resetEvents() {
        do { try save([]) }
        catch { errorMessage = "投稿データを初期化できませんでした: \(error)" }
    }
    func accept(_ event: NostrEvent) -> Bool {
        guard !events.contains(where: { $0.id == event.id }), event.isValid(),
              (try? JSONEncoder().encode(event).count) ?? Int.max <= PeerFraming.maxEvent else { return false }
        do { try save([event] + events); return true }
        catch { errorMessage = "受信した投稿を保存できませんでした: \(error)"; return false }
    }
    var shareable: [NostrEvent] {
        Array(events.filter { ((try? JSONEncoder().encode($0).count) ?? Int.max) <= PeerFraming.maxEvent }.prefix(PeerFraming.maxSharedEvents))
    }

}
