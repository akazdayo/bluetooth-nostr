#include "Bridge.h"

int nostr_public_key(const unsigned char *secret, unsigned char *pubkey) {
    secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    secp256k1_keypair key;
    secp256k1_xonly_pubkey xonly;
    int result = ctx && secp256k1_keypair_create(ctx, &key, secret) &&
        secp256k1_keypair_xonly_pub(ctx, &xonly, NULL, &key) &&
        secp256k1_xonly_pubkey_serialize(ctx, pubkey, &xonly);
    if (ctx) secp256k1_context_destroy(ctx);
    return result;
}
int nostr_sign(const unsigned char *secret, const unsigned char *message, const unsigned char *aux, unsigned char *signature) {
    secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    secp256k1_keypair key;
    int result = ctx && secp256k1_context_randomize(ctx, aux) &&
        secp256k1_keypair_create(ctx, &key, secret) &&
        secp256k1_schnorrsig_sign32(ctx, signature, message, &key, aux);
    if (ctx) secp256k1_context_destroy(ctx);
    return result;
}
int nostr_verify(const unsigned char *pubkey, const unsigned char *message, const unsigned char *signature) {
    secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    secp256k1_xonly_pubkey key;
    int result = ctx && secp256k1_xonly_pubkey_parse(ctx, &key, pubkey) &&
        secp256k1_schnorrsig_verify(ctx, signature, message, 32, &key);
    if (ctx) secp256k1_context_destroy(ctx);
    return result;
}
