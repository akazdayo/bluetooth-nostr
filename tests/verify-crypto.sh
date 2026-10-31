#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d "${TMPDIR:-/tmp}/nostr-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
src=bluetooth-nostr/vendor/libsecp256k1/src
flags='-DECMULT_WINDOW_SIZE=15 -DECMULT_GEN_PREC_BITS=4'
clang $flags -DENABLE_MODULE_EXTRAKEYS=1 -DENABLE_MODULE_SCHNORRSIG=1 -c "$src/secp256k1.c" -o "$tmp/secp.o"
clang $flags -c "$src/precomputed_ecmult.c" -o "$tmp/ecmult.o"
clang $flags -c "$src/precomputed_ecmult_gen.c" -o "$tmp/gen.o"
clang -c bluetooth-nostr/NostrCrypto.c -o "$tmp/wrapper.o"
swiftc -module-cache-path "$tmp/cache" -import-objc-header bluetooth-nostr/Bridge.h bluetooth-nostr/NostrEvent.swift bluetooth-nostr/PeerProtocol.swift tests/main.swift "$tmp/secp.o" "$tmp/ecmult.o" "$tmp/gen.o" "$tmp/wrapper.o" -o "$tmp/test"
"$tmp/test"
