#ifndef KNOT_PAIRING_H
#define KNOT_PAIRING_H

#include <stdint.h>

#if defined(_WIN32) && defined(KN_PAIRING_EXPORTS)
#define KN_PAIR_API __declspec(dllexport)
#elif defined(__GNUC__)
#define KN_PAIR_API __attribute__((visibility("default")))
#else
#define KN_PAIR_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KnPairContext KnPairContext;
enum { KN_PAIR_CLIENT = 0, KN_PAIR_SERVER = 1 };
enum { KN_PAIR_OK = 0, KN_PAIR_INVALID = -1, KN_PAIR_AUTH = -2,
       KN_PAIR_STATE = -3, KN_PAIR_CRYPTO = -4, KN_PAIR_CAPACITY = -5 };
enum { KN_PAIR_CONFIRM = 3, KN_PAIR_OFFER = 4 };

KN_PAIR_API uint32_t kn_pair_abi_version(void);
KN_PAIR_API KnPairContext* kn_pair_create(uint32_t role, const uint8_t* password,
    uint32_t password_length, const uint8_t* slot, uint32_t slot_length);
KN_PAIR_API int32_t kn_pair_message(KnPairContext* context, uint8_t* output,
    uint32_t capacity, uint32_t* written);
KN_PAIR_API int32_t kn_pair_process(KnPairContext* context, const uint8_t* peer,
    uint32_t peer_length);
KN_PAIR_API int32_t kn_pair_seal(KnPairContext* context, uint8_t kind,
    const uint8_t* plaintext, uint32_t length, uint8_t* output,
    uint32_t capacity, uint32_t* written);
KN_PAIR_API int32_t kn_pair_open(KnPairContext* context, uint8_t kind,
    const uint8_t* sealed, uint32_t length, uint8_t* output,
    uint32_t capacity, uint32_t* written);
KN_PAIR_API void kn_pair_close(KnPairContext* context);

#ifdef __cplusplus
}
#endif
#endif
