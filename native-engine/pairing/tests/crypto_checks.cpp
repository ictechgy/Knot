#include "knot_pairing.h"
#include <openssl/aead.h>
#include <openssl/digest.h>
#include <openssl/hkdf.h>
#include <array>
#include <algorithm>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

namespace {
uint32_t checks = 0;
void Need(bool ok, const char* label) {
    ++checks;
    if (!ok) { std::cerr << "Synthetic crypto check failed: " << label << '\n'; std::exit(1); }
}
using Context = std::unique_ptr<KnPairContext, decltype(&kn_pair_close)>;
std::vector<uint8_t> Hex(const char* text) {
    std::vector<uint8_t> value;
    for (size_t i = 0; i < std::strlen(text); i += 2)
        value.push_back(static_cast<uint8_t>(std::stoul(std::string(text + i, 2), nullptr, 16)));
    return value;
}
struct Pair {
    Context client{nullptr, kn_pair_close}, server{nullptr, kn_pair_close};
    std::array<uint8_t, 32> a{}, b{};
    Pair(const char* password = "01234567", bool wrong_slot = false) {
        std::array<uint8_t, 16> slot{};
        client.reset(kn_pair_create(KN_PAIR_CLIENT, reinterpret_cast<const uint8_t*>("01234567"), 8, slot.data(), 16));
        if (wrong_slot) slot[0] = 1;
        server.reset(kn_pair_create(KN_PAIR_SERVER, reinterpret_cast<const uint8_t*>(password), 8, slot.data(), 16));
        Need(client && server, "create contexts");
        uint32_t n = 0;
        Need(kn_pair_message(client.get(), a.data(), 32, &n) == 0 && n == 32, "client message");
        Need(kn_pair_message(server.get(), b.data(), 32, &n) == 0 && n == 32, "server message");
    }
    void Process() {
        Need(kn_pair_process(client.get(), b.data(), 32) == 0, "client process");
        Need(kn_pair_process(server.get(), a.data(), 32) == 0, "server process");
    }
};
std::vector<uint8_t> Seal(KnPairContext* ctx, uint8_t kind, const std::vector<uint8_t>& plain) {
    std::vector<uint8_t> data(plain.size() + 29, 0xA5);
    uint32_t n = 0;
    Need(kn_pair_seal(ctx, kind, plain.data(), static_cast<uint32_t>(plain.size()), data.data(),
         static_cast<uint32_t>(data.size() - 1), &n) == 0 && n == plain.size() + 28, "seal");
    Need(data.back() == 0xA5, "seal canary"); data.resize(n); return data;
}
void Confirm(Pair& p) {
    const std::vector<uint8_t> plain{'f','r','e','s','h','-','t','e','s','t'};
    const auto wire = Seal(p.client.get(), 3, plain);
    std::array<uint8_t, 64> out{}; uint32_t n = 0;
    Need(kn_pair_open(p.server.get(), 3, wire.data(), static_cast<uint32_t>(wire.size()), out.data(),
         static_cast<uint32_t>(out.size()), &n) == 0 && n == plain.size() &&
         std::equal(plain.begin(), plain.end(), out.begin()), "client key confirmation");
}
void KnownAnswers() {
    // RFC5869 A.1 HKDF-SHA256. Numeric vector data, no copied implementation.
    std::vector<uint8_t> ikm(22, 0x0b);
    const auto salt = Hex("000102030405060708090a0b0c");
    const auto info = Hex("f0f1f2f3f4f5f6f7f8f9");
    const auto expected = Hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");
    std::array<uint8_t, 42> out{};
    Need(HKDF(out.data(), out.size(), EVP_sha256(), ikm.data(), ikm.size(), salt.data(), salt.size(),
         info.data(), info.size()) == 1 && std::equal(expected.begin(), expected.end(), out.begin()), "HKDF known answer");
    // Pinned upstream crypto/cipher/test/aes_256_gcm_tests.txt, second vector.
    const auto key = Hex("73ad7bbbbc640c845a150f67d058b279849370cd2c1f3c67c4dd6c869213e13a");
    const auto nonce = Hex("a330a184fc245812f4820caa");
    const auto plain = Hex("f0535fe211"), aad = Hex("e91428be04");
    const auto encrypted = Hex("e9b8a896da9115ed79f26a030c14947b3e454db9e7");
    EVP_AEAD_CTX* ctx = EVP_AEAD_CTX_new(EVP_aead_aes_256_gcm(), key.data(), key.size(), 16);
    Need(ctx != nullptr, "AES context");
    std::array<uint8_t, 64> cipher{}, decoded{}; size_t n = 0;
    Need(EVP_AEAD_CTX_seal(ctx, cipher.data(), &n, cipher.size(), nonce.data(), nonce.size(),
         plain.data(), plain.size(), aad.data(), aad.size()) == 1 && n == encrypted.size() &&
         std::equal(encrypted.begin(), encrypted.end(), cipher.begin()), "AES-GCM known answer");
    Need(EVP_AEAD_CTX_open(ctx, decoded.data(), &n, decoded.size(), nonce.data(), nonce.size(),
         cipher.data(), encrypted.size(), aad.data(), aad.size()) == 1 && n == plain.size() &&
         std::equal(plain.begin(), plain.end(), decoded.begin()), "AES-GCM known answer open");
    EVP_AEAD_CTX_free(ctx);
}
}

int main() {
    Need(kn_pair_abi_version() == 2, "ABI version");
    KnownAnswers();
    std::array<uint8_t, 16> slot{};
    Need(!kn_pair_create(2, reinterpret_cast<const uint8_t*>("01234567"), 8, slot.data(), 16), "invalid role");
    Need(!kn_pair_create(0, reinterpret_cast<const uint8_t*>("1234567x"), 8, slot.data(), 16), "invalid password");
    Need(!kn_pair_create(0, reinterpret_cast<const uint8_t*>("12345678"), 8, slot.data(), 15), "invalid slot");
    {
        Pair p; p.Process(); Confirm(p);
        const std::vector<uint8_t> plain(3072, 0x5a); const auto wire = Seal(p.server.get(), 4, plain);
        std::vector<uint8_t> out(3073, 0xA5); uint32_t n = 0;
        Need(kn_pair_open(p.client.get(), 4, wire.data(), static_cast<uint32_t>(wire.size()), out.data(),
             3072, &n) == 0 && n == 3072 && std::equal(plain.begin(), plain.end(), out.begin()), "reciprocal offer confirmation");
        Need(out.back() == 0xA5, "open canary");
        Need(kn_pair_open(p.client.get(), 4, wire.data(), static_cast<uint32_t>(wire.size()), out.data(),
             3072, &n) == KN_PAIR_STATE && n == 0, "offer replay rejected");
    }
    for (bool wrong_slot : {false, true}) {
        Pair p(wrong_slot ? "01234567" : "01234568", wrong_slot); p.Process();
        const auto wire = Seal(p.client.get(), 3, std::vector<uint8_t>{'t','e','s','t'});
        std::array<uint8_t, 64> out{}; uint32_t n = 99;
        Need(kn_pair_open(p.server.get(), 3, wire.data(), static_cast<uint32_t>(wire.size()), out.data(),
             64, &n) == KN_PAIR_AUTH && n == 0, wrong_slot ? "wrong slot rejected" : "wrong password rejected");
    }
    {
        Pair p; p.Process();
        auto wire = Seal(p.client.get(), 3, std::vector<uint8_t>{'t','e','s','t'}); wire.back() ^= 1;
        std::array<uint8_t, 64> out{}; out.fill(0xA5); uint32_t n = 99;
        Need(kn_pair_open(p.server.get(), 3, wire.data(), static_cast<uint32_t>(wire.size()), out.data(),
             64, &n) == KN_PAIR_AUTH && n == 0, "tampered tag rejected");
        Need(std::all_of(out.begin(), out.begin() + 4, [](uint8_t x) { return x == 0; }), "failed output cleansed");
        Need(kn_pair_process(p.server.get(), p.a.data(), 32) == KN_PAIR_STATE, "failed context invalidated");
    }
    {
        Pair p; p.Process(); uint8_t out[64]{}; uint32_t n = 0;
        Need(kn_pair_seal(p.server.get(), 4, reinterpret_cast<const uint8_t*>("x"), 1, out, 64, &n)
             == KN_PAIR_STATE, "no offer before confirmation");
    }
    {
        Pair p; p.Process();
        Need(kn_pair_process(p.client.get(), p.b.data(), 32) == KN_PAIR_STATE, "process reuse rejected");
    }
    {
        Pair p; p.Process();
        const auto wire = Seal(p.client.get(), 3, std::vector<uint8_t>{'x'});
        uint8_t out[64]{}; uint32_t n = 0;
        Need(kn_pair_seal(p.client.get(), 3, reinterpret_cast<const uint8_t*>("x"), 1, out, 64, &n)
             == KN_PAIR_STATE, "seal reuse rejected");
        Need(kn_pair_open(p.server.get(), 4, wire.data(), static_cast<uint32_t>(wire.size()), out, 64, &n)
             == KN_PAIR_STATE, "role reflection rejected");
    }
    {
        Pair p; uint8_t out[64]{}; uint32_t n = 0;
        Need(kn_pair_process(p.client.get(), p.b.data(), 31) == KN_PAIR_INVALID, "bad peer size rejected");
        Need(kn_pair_seal(p.client.get(), 3, reinterpret_cast<const uint8_t*>("x"), 1, out, 64, &n)
             == KN_PAIR_STATE, "bad peer destroys context");
    }
    {
        Pair p; p.Process(); uint8_t out[64]{}; uint32_t n = 0;
        Need(kn_pair_seal(p.client.get(), 3, reinterpret_cast<const uint8_t*>("x"), 1, out, 28, &n)
             == KN_PAIR_CAPACITY && n == 0, "undersized destination rejected");
    }
    {
        Pair p; p.Process(); std::vector<uint8_t> over(485, 'x'), out(600); uint32_t n = 0;
        Need(kn_pair_seal(p.client.get(), 3, over.data(), 485, out.data(), 600, &n)
             == KN_PAIR_INVALID, "oversize confirmation rejected");
    }
    std::cout << "{\"schema\":1,\"status\":\"passed\",\"freshSyntheticOnly\":true,"
        "\"networkInvoked\":false,\"captureInvoked\":false,\"actualInputInvoked\":false,"
        "\"abiVersion\":2,\"checks\":" << checks << ",\"hkdfKnownAnswer\":true,"
        "\"aesGcmKnownAnswer\":true,\"mutualConfirmation\":true,\"replayRejected\":true}\n";
}
