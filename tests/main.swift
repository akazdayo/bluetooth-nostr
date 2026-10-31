import Foundation
let event = NostrEvent(id: "beba4c73fda2eace45478ef77c4e070d2db2414d426094ca23bb9f16a5a3d87e", pubkey: "1beecee55f69ebc2890403606f28b5e8ebbab23d226730e12b4bf762d29d2162", created_at: 1792681791, kind: 1, tags: [], content: "てすとてすと", sig: "7e5886e4aef4ebe18687f4b635b06753da1dc9f51ebcc7a2690aedbf614cd86523a231c8ef9b72d95afff1931b3e8c4163b18251fc8b06e5cde2676d61e0f189")
precondition(event.isValid(), "article event should validate")
let altered = NostrEvent(id: event.id, pubkey: event.pubkey, created_at: event.created_at, kind: event.kind, tags: event.tags, content: "変更", sig: event.sig)
precondition(!altered.isValid(), "tampered event must fail")
print("Article event verifies; tampered content rejected")
let message = PeerMessage("event", events: [event])
let frame = try PeerFraming.encode(message)
var decoder = PeerDecoder()
var decoded: [PeerMessage] = []
for byte in frame { decoded += try decoder.append(Data([byte])) }
precondition(decoded.count == 1 && decoded[0].events?.first?.id == event.id)
var multipleDecoder = PeerDecoder()
let double = try multipleDecoder.append(frame + frame)
precondition(double.count == 2)
var invalidDecoder = PeerDecoder()
do { _ = try invalidDecoder.append(Data([0, 1, 0, 1])); fatalError("oversized frame accepted") } catch {}
print("Fragmented, combined, and oversized frames verified")
