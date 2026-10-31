#include "vendor/libsecp256k1/include/secp256k1.h"
#include "vendor/libsecp256k1/include/secp256k1_extrakeys.h"
#include "vendor/libsecp256k1/include/secp256k1_schnorrsig.h"
int nostr_public_key(const unsigned char *secret, unsigned char *pubkey);
int nostr_sign(const unsigned char *secret, const unsigned char *message, const unsigned char *aux, unsigned char *signature);
int nostr_verify(const unsigned char *pubkey, const unsigned char *message, const unsigned char *signature);
