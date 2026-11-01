#pragma once
#include <stdint.h>

#if defined(_WIN32)
# if defined(KN_MEDIA_EXPORTS)
#  define KN_MEDIA_API __declspec(dllexport)
# else
#  define KN_MEDIA_API __declspec(dllimport)
# endif
# define KN_MEDIA_CALL __cdecl
#else
# define KN_MEDIA_API
# define KN_MEDIA_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

#pragma pack(push, 4)
typedef struct KnMediaConfig {
    uint32_t width, height, fps, bitrate;
} KnMediaConfig;
typedef struct KnMediaInfo {
    uint32_t width, height, fps, bitrate;
    // Physical captured primary-monitor rectangle, BEFORE encoder scaling.
    // This is not the virtual-desktop size. Use it for normalized input mapping.
    int32_t left, top, desktopWidth, desktopHeight;
    uint32_t hardwareEncoder;
} KnMediaInfo;
#pragma pack(pop)

enum KnMediaStatus {
    KN_MEDIA_SAMPLE = 0, KN_MEDIA_TRY_AGAIN = 1,
    KN_MEDIA_ERROR = -1, KN_MEDIA_UNSUPPORTED_DISPLAY = -2,
    KN_MEDIA_NO_HARDWARE_ENCODER = -3, KN_MEDIA_DEVICE_FAILURE = -4,
    KN_MEDIA_INVALID_ARGUMENT = -5
};

// All three functions must be called on the SAME dedicated MTA thread.
// create owns balanced COM/MF startup; normal creation ALWAYS requires hardware.
// width/height are even bounds (16..1920/1080); output preserves display aspect.
KN_MEDIA_API void* KN_MEDIA_CALL kn_media_create(const KnMediaConfig* config,
    KnMediaInfo* info, int32_t* error);
// Nonblocking event polling, <=450 ms application wait budget (<500 ms contract).
// OS/driver calls cannot be preempted. A wedged GPU/codec requires process exit.
// AU <=4,194,287 bytes; flags bit0=actual IDR; monotonic host capture timestamp.
// On non-sample: written/flags/timestamp are zero. No output is ever truncated.
KN_MEDIA_API int32_t KN_MEDIA_CALL kn_media_read(void* session, uint8_t* buffer,
    uint32_t capacity, uint32_t* written, uint32_t* flags, uint64_t* timestampMicros);
// null is allowed. Wrong-thread close is rejected (caller must close correctly).
KN_MEDIA_API void KN_MEDIA_CALL kn_media_close(void* session);

#ifdef __cplusplus
}
static_assert(sizeof(KnMediaConfig) == 16, "Config ABI");
static_assert(sizeof(KnMediaInfo) == 36, "Info ABI");
#endif
