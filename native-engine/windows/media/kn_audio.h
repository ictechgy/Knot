#pragma once
#include <stdint.h>
#include "kn_media.h"

#ifdef __cplusplus
extern "C" {
#endif
enum KnAudioStatus { KN_AUDIO_SAMPLE = 0, KN_AUDIO_AGAIN = 1, KN_AUDIO_UNAVAILABLE = -1, KN_AUDIO_ERROR = -2, KN_AUDIO_ARGUMENT = -3 };
// The caller's dedicated MTA thread owns open/read/close. This captures only
// the default render endpoint's loopback; there is no microphone fallback.
// Output is always 48000Hz, stereo PCM16 little-endian. Capture opens only
// after the managed sidecar has authenticated its approved media session.
KN_MEDIA_API int32_t KN_MEDIA_CALL kn_audio_open(void** session);
KN_MEDIA_API int32_t KN_MEDIA_CALL kn_audio_read(void* session, uint8_t* samples,
    uint32_t capacity_frames, uint32_t* frames, uint64_t* first_sample_index, uint32_t timeout_ms);
KN_MEDIA_API void KN_MEDIA_CALL kn_audio_close(void* session);
#ifdef __cplusplus
}
#endif
