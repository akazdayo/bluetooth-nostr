import SwiftUI

struct ContentView: View {
    @StateObject private var nearby = NearbyService()
    @StateObject private var store = EventStore()
    @AppStorage("nearbyEnabled") private var nearbyEnabled = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("近くの端末を探す", isOn: $nearbyEnabled)
                    LabeledContent("状態", value: nearby.status)
                    LabeledContent("見つけた端末", value: "\(nearby.discoveredCount)")
                    LabeledContent("受信した投稿", value: "\(nearby.receivedCount)")
                } header: {
                    Text("すれ違い通信")
                } footer: {
                    Text("近くの端末と直近 256 件の投稿を交換します。1 件の上限は 16 KiB です。バックグラウンドでの発見には時間がかかる場合があります。")
                }
                Section("自分の公開鍵") {
                    Text(store.publicKey.isEmpty ? "読み込み中" : store.publicKey)
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                Section("投稿を作成") {
                    TextField("いま何を考えている？", text: $store.draft, axis: .vertical)
                    Button("署名して保存") { if store.post(store.draft) { store.draft = "" } }
                        .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.publicKey.isEmpty)
                    Text("投稿は端末に保存され、すれ違った端末に共有されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("投稿") {
                    if store.events.isEmpty {
                        Text("投稿はまだありません").foregroundStyle(.secondary)
                    } else {
                        ForEach(store.events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.content)
                                Text(String(event.pubkey.prefix(16)) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(Date(timeIntervalSince1970: TimeInterval(event.created_at)), style: .date)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("データ管理") {
                    Button("投稿データを初期化", role: .destructive) {
                        store.showingResetConfirmation = true
                    }
                }
            }
            .navigationTitle("Bluetooth Nostr")
            .confirmationDialog("投稿データを初期化しますか？", isPresented: $store.showingResetConfirmation, titleVisibility: .visible) {
                Button("投稿データを初期化", role: .destructive) { store.resetEvents() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この端末に保存した投稿をすべて削除します。秘密鍵は保持されます。通信中は他の端末から投稿を再受信することがあります。")
            }
            .alert("エラー", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("閉じる", role: .cancel) {} } message: { Text(store.errorMessage ?? "") }
            .onChange(of: nearbyEnabled, initial: true) { _, enabled in
                nearby.bind(store)
                if enabled { nearby.start() } else { nearby.stop() }
            }
        }
    }
}
