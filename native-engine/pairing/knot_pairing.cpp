#include "knot_pairing.h"

#include <openssl/aead.h>
#include <openssl/curve25519.h>
#include <openssl/digest.h>
#include <openssl/hkdf.h>
#include <openssl/mem.h>
#include <openssl/rand.h>
#include <openssl/sha.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace {
constexpr size_t kMessage = 32, kSlot = 16, kNonce = 12, kTag = 16;
constexpr uint32_t kPlain = 3072, kConfirmPlain = 512 - kNonce - kTag;
constexpr char kDomain[] = "KnotNative/Enrollment/v2";
constexpr char kClient[] = "KnotNative/Enrollment/v2/client";
constexpr char kServer[] = "KnotNative/Enrollment/v2/server";
constexpr char kClientKey[] = "KnotNative/Enrollment/v2/client-confirm";
constexpr char kServerKey[] = "KnotNative/Enrollment/v2/server-offer";

std::vector<uint8_t> Identity(const char* role, const uint8_t* slot) {
    std::vector<uint8_t> value(role, role + std::strlen(role) + 1);
    value.insert(value.end(), slot, slot + kSlot);
    return value;
}
}

struct KnPairContext {
    uint32_t role = KN_PAIR_CLIENT;
    SPAKE2_CTX* spake = nullptr;
    std::array<uint8_t, kSlot> slot{};
    std::array<uint8_t, kMessage> message{};
    std::array<uint8_t, SHA256_DIGEST_LENGTH> context{}, client_key{}, server_key{};
    bool processed = false, confirm = false, offer = false, failed = false;

    ~KnPairContext() {
        SPAKE2_CTX_free(spake);
        OPENSSL_cleanse(client_key.data(), client_key.size());
        OPENSSL_cleanse(server_key.data(), server_key.size());
    }
    int Fail(int code) {
        failed = true;
        OPENSSL_cleanse(client_key.data(), client_key.size());
        OPENSSL_cleanse(server_key.data(), server_key.size());
        return code;
    }
};

extern "C" uint32_t kn_pair_abi_version(void) { return 2; }

extern "C" KnPairContext* kn_pair_create(uint32_t role, const uint8_t* password,
    uint32_t password_length, const uint8_t* slot, uint32_t slot_length) {
    if (role > KN_PAIR_SERVER || !password || password_length != 8 || !slot || slot_length != kSlot)
        return nullptr;
    for (uint32_t i = 0; i < password_length; ++i)
        if (password[i] < '0' || password[i] > '9') return nullptr;
    try {
        auto value = std::make_unique<KnPairContext>();
        value->role = role;
        std::copy(slot, slot + kSlot, value->slot.begin());
        const auto mine = Identity(role == KN_PAIR_CLIENT ? kClient : kServer, slot);
        const auto theirs = Identity(role == KN_PAIR_CLIENT ? kServer : kClient, slot);
        value->spake = SPAKE2_CTX_new(role == KN_PAIR_CLIENT ? spake2_role_alice : spake2_role_bob,
            mine.data(), mine.size(), theirs.data(), theirs.size());
        size_t length = 0;
        if (!value->spake || !SPAKE2_generate_msg(value->spake, value->message.data(), &length,
            value->message.size(), password, password_length) || length != kMessage) return nullptr;
        return value.release();
    } catch (...) { return nullptr; }
}

extern "C" int32_t kn_pair_message(KnPairContext* context, uint8_t* output,
    uint32_t capacity, uint32_t* written) {
    if (written) *written = 0;
    if (!context || !output || !written) return KN_PAIR_INVALID;
    if (context->failed) return KN_PAIR_STATE;
    if (capacity < kMessage) return KN_PAIR_CAPACITY;
    std::copy(context->message.begin(), context->message.end(), output);
    *written = kMessage;
    return KN_PAIR_OK;
}

extern "C" int32_t kn_pair_process(KnPairContext* value, const uint8_t* peer,
    uint32_t peer_length) {
    if (!value) return KN_PAIR_INVALID;
    if (value->failed || value->processed) return value->Fail(KN_PAIR_STATE);
    if (!peer || peer_length != kMessage) return value->Fail(KN_PAIR_INVALID);
    std::array<uint8_t, SPAKE2_MAX_KEY_SIZE> material{};
    size_t material_length = 0;
    if (!SPAKE2_process_msg(value->spake, material.data(), &material_length,
        material.size(), peer, peer_length) || material_length == 0 || material_length > material.size()) {
        OPENSSL_cleanse(material.data(), material.size());
        return value->Fail(KN_PAIR_AUTH);
    }
    // Fixed-width transcript: domain || slot || pA || pB. Public message order
    // follows roles, not packet arrival order. No password or key is exported.
    std::array<uint8_t, sizeof(kDomain) - 1 + kSlot + kMessage * 2> transcript{};
    auto at = std::copy(kDomain, kDomain + sizeof(kDomain) - 1, transcript.begin());
    at = std::copy(value->slot.begin(), value->slot.end(), at);
    if (value->role == KN_PAIR_CLIENT) {
        at = std::copy(value->message.begin(), value->message.end(), at);
        std::copy(peer, peer + kMessage, at);
    } else {
        at = std::copy(peer, peer + kMessage, at);
        std::copy(value->message.begin(), value->message.end(), at);
    }
    SHA256(transcript.data(), transcript.size(), value->context.data());
    const bool ok = HKDF(value->client_key.data(), value->client_key.size(), EVP_sha256(),
        material.data(), material_length, value->context.data(), value->context.size(),
        reinterpret_cast<const uint8_t*>(kClientKey), sizeof(kClientKey) - 1) &&
        HKDF(value->server_key.data(), value->server_key.size(), EVP_sha256(),
        material.data(), material_length, value->context.data(), value->context.size(),
        reinterpret_cast<const uint8_t*>(kServerKey), sizeof(kServerKey) - 1);
    OPENSSL_cleanse(material.data(), material.size());
    SPAKE2_CTX_free(value->spake); value->spake = nullptr;
    if (!ok) return value->Fail(KN_PAIR_CRYPTO);
    value->processed = true;
    return KN_PAIR_OK;
}

namespace {
int Crypt(KnPairContext* value, uint8_t kind, bool sealing, const uint8_t* input,
    uint32_t length, uint8_t* output, uint32_t capacity, uint32_t* written) {
    if (written) *written = 0;
    if (!value) return KN_PAIR_INVALID;
    if (value->failed || !value->processed) return value->Fail(KN_PAIR_STATE);
    const bool confirm = kind == KN_PAIR_CONFIRM;
    if ((!confirm && kind != KN_PAIR_OFFER) ||
        (sealing != (value->role == (confirm ? KN_PAIR_CLIENT : KN_PAIR_SERVER))) ||
        (confirm ? value->confirm : (!value->confirm || value->offer)))
        return value->Fail(KN_PAIR_STATE);
    const uint32_t maximum = confirm ? kConfirmPlain : kPlain;
    if (!input || !output || !written || length == 0 ||
        (sealing ? length > maximum : (length < kNonce + kTag + 1 || length > maximum + kNonce + kTag)))
        return value->Fail(KN_PAIR_INVALID);
    const uint32_t required = sealing ? length + kNonce + kTag : length - kNonce - kTag;
    if (capacity < required) return value->Fail(KN_PAIR_CAPACITY);
    std::array<uint8_t, SHA256_DIGEST_LENGTH + 1> aad{};
    std::copy(value->context.begin(), value->context.end(), aad.begin()); aad.back() = kind;
    const auto& key = confirm ? value->client_key : value->server_key;
    EVP_AEAD_CTX* aead = EVP_AEAD_CTX_new(EVP_aead_aes_256_gcm(), key.data(), key.size(), kTag);
    if (!aead) return value->Fail(KN_PAIR_CRYPTO);
    size_t actual = 0;
    int ok = 0;
    if (sealing) {
        ok = RAND_bytes(output, kNonce) && EVP_AEAD_CTX_seal(aead, output + kNonce, &actual,
            capacity - kNonce, output, kNonce, input, length, aad.data(), aad.size());
        if (ok) actual += kNonce;
    } else {
        ok = EVP_AEAD_CTX_open(aead, output, &actual, capacity, input, kNonce,
            input + kNonce, length - kNonce, aad.data(), aad.size());
    }
    EVP_AEAD_CTX_free(aead);
    if (!ok || actual != required) {
        OPENSSL_cleanse(output, required);
        return value->Fail(sealing ? KN_PAIR_CRYPTO : KN_PAIR_AUTH);
    }
    if (confirm) value->confirm = true; else value->offer = true;
    *written = static_cast<uint32_t>(actual);
    return KN_PAIR_OK;
}
}

extern "C" int32_t kn_pair_seal(KnPairContext* context, uint8_t kind,
    const uint8_t* plaintext, uint32_t length, uint8_t* output,
    uint32_t capacity, uint32_t* written) {
    return Crypt(context, kind, true, plaintext, length, output, capacity, written);
}
extern "C" int32_t kn_pair_open(KnPairContext* context, uint8_t kind,
    const uint8_t* sealed, uint32_t length, uint8_t* output,
    uint32_t capacity, uint32_t* written) {
    return Crypt(context, kind, false, sealed, length, output, capacity, written);
}
extern "C" void kn_pair_close(KnPairContext* context) { delete context; }
