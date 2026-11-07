// SPDX-License-Identifier: GPL-3.0-only
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "kn_audio.h"
#include "audio_convert.h"
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <chrono>
#include <memory>
#include <new>
#include <string>

namespace {
using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;
struct AudioSession {
    DWORD owner = GetCurrentThreadId();
    bool com = false, started = false;
    HANDLE event = nullptr;
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> endpoint;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    std::wstring endpointId;
    std::unique_ptr<knot::AudioConverter> converter;
    Clock::time_point lastRead = Clock::now();
    Clock::time_point nextEndpointCheck = Clock::now();
    ~AudioSession() {
        if (started && client) client->Stop();
        capture.Reset(); client.Reset(); endpoint.Reset(); enumerator.Reset();
        if (event) CloseHandle(event);
        if (com) CoUninitialize();
    }
    HRESULT Start() {
        HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(hr)) return hr;
        com = true;
        hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enumerator));
        if (FAILED(hr)) return hr;
        // Never select eCapture or enumerate microphones, even on failure.
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &endpoint);
        if (FAILED(hr)) return hr;
        LPWSTR id = nullptr;
        hr = endpoint->GetId(&id);
        if (FAILED(hr)) return hr;
        struct IdOwner { LPWSTR value; ~IdOwner() { CoTaskMemFree(value); } } ownedId{ id };
        if (!id) return E_FAIL;
        endpointId = id;
        hr = endpoint->Activate(__uuidof(IAudioClient), CLSCTX_INPROC_SERVER, nullptr, reinterpret_cast<void**>(client.GetAddressOf()));
        if (FAILED(hr)) return hr;
        WAVEFORMATEX* mix = nullptr;
        hr = client->GetMixFormat(&mix);
        if (FAILED(hr)) return hr;
        struct FormatOwner { WAVEFORMATEX* p; ~FormatOwner() { CoTaskMemFree(p); } } owned{ mix };
        if (!mix) return E_FAIL;
        knot::AudioInputFormat format;
        format.rate = mix->nSamplesPerSec; format.channels = mix->nChannels;
        WORD tag = mix->wFormatTag;
        if (tag == WAVE_FORMAT_EXTENSIBLE) {
            if (mix->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) return AUDCLNT_E_UNSUPPORTED_FORMAT;
            const auto* extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(mix);
            format.channelMask = extended->dwChannelMask;
            if (IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) tag = WAVE_FORMAT_IEEE_FLOAT;
            else if (IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_PCM)) tag = WAVE_FORMAT_PCM;
            else return AUDCLNT_E_UNSUPPORTED_FORMAT;
        }
        if (tag == WAVE_FORMAT_IEEE_FLOAT && mix->wBitsPerSample == 32) format.sample = knot::AudioSample::Float32;
        else if (tag == WAVE_FORMAT_PCM && mix->wBitsPerSample == 16) format.sample = knot::AudioSample::Pcm16;
        else if (tag == WAVE_FORMAT_PCM && mix->wBitsPerSample == 24) format.sample = knot::AudioSample::Pcm24;
        else if (tag == WAVE_FORMAT_PCM && mix->wBitsPerSample == 32) format.sample = knot::AudioSample::Pcm32;
        else return AUDCLNT_E_UNSUPPORTED_FORMAT;
        if (!format.Valid() || mix->nBlockAlign != format.channels * format.BytesPerSample() ||
            mix->nAvgBytesPerSec != format.rate * mix->nBlockAlign) return AUDCLNT_E_UNSUPPORTED_FORMAT;
        converter.reset(new knot::AudioConverter(format));
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event) return HRESULT_FROM_WIN32(GetLastError());
        // Read the returned native mix format; never guess that loopback data
        // was converted to the requested PCM type by a particular driver.
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
            1000000, 0, mix, nullptr); //100ms endpoint buffer
        if (FAILED(hr)) return hr;
        hr = client->SetEventHandle(event);
        if (FAILED(hr)) return hr;
        hr = client->GetService(IID_PPV_ARGS(&capture));
        if (FAILED(hr)) return hr;
        hr = client->Start();
        if (SUCCEEDED(hr)) started = true;
        return hr;
    }
    HRESULT CheckDefaultEndpoint(Clock::time_point now) {
        if (now < nextEndpointCheck) return S_OK;
        nextEndpointCheck = now + std::chrono::seconds(1);
        ComPtr<IMMDevice> current;
        HRESULT hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &current);
        if (FAILED(hr)) return hr;
        LPWSTR id = nullptr; hr = current->GetId(&id);
        if (FAILED(hr)) return hr;
        struct IdOwner { LPWSTR value; ~IdOwner() { CoTaskMemFree(value); } } owned{ id };
        // A changed render endpoint must be reopened and its mix format checked
        // afresh. Never reinterpret its packets using the old device's format.
        return id && endpointId == id ? S_OK : AUDCLNT_E_DEVICE_INVALIDATED;
    }
    HRESULT Drain() {
        // A bounded number of endpoint packets prevents a defective driver
        // from keeping this owner thread busy indefinitely.
        for (uint32_t packets = 0; packets < 32; ++packets) {
            UINT32 available = 0;
            HRESULT hr = capture->GetNextPacketSize(&available);
            if (FAILED(hr)) return hr;
            if (available == 0) return S_OK;
            BYTE* bytes = nullptr; UINT32 count = 0; DWORD flags = 0;
            hr = capture->GetBuffer(&bytes, &count, &flags, nullptr, nullptr);
            if (FAILED(hr)) return hr;
            if (count == 0) return S_OK;
            // Release the borrowed endpoint buffer even if conversion runs out
            // of memory. No buffer remains borrowed across a socket write.
            struct BufferOwner {
                IAudioCaptureClient* capture; UINT32 frames; bool released = false;
                ~BufferOwner() { if (!released) capture->ReleaseBuffer(frames); }
            } owned{ capture.Get(), count };
            if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0) converter->Discontinuity();
            const bool converted = converter->Feed(bytes, count, (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0);
            const HRESULT released = capture->ReleaseBuffer(count);
            owned.released = true;
            if (!converted) return AUDCLNT_E_UNSUPPORTED_FORMAT;
            if (FAILED(released)) return released;
        }
        return S_OK;
    }
};
}

int32_t KN_MEDIA_CALL kn_audio_open(void** session) {
    if (!session) return KN_AUDIO_ARGUMENT;
    *session = nullptr;
    try {
        std::unique_ptr<AudioSession> value(new AudioSession());
        if (FAILED(value->Start())) return KN_AUDIO_UNAVAILABLE;
        *session = value.release(); return KN_AUDIO_SAMPLE;
    } catch (...) { return KN_AUDIO_ERROR; }
}
int32_t KN_MEDIA_CALL kn_audio_read(void* session, uint8_t* samples, uint32_t capacity,
    uint32_t* frames, uint64_t* first, uint32_t timeout) {
    if (frames) *frames = 0;
    if (first) *first = 0;
    if (!session || !samples || !frames || !first || capacity < 1 || capacity > 960 || timeout > 100)
        return KN_AUDIO_ARGUMENT;
    auto* value = static_cast<AudioSession*>(session);
    if (value->owner != GetCurrentThreadId()) return KN_AUDIO_ARGUMENT;
    try {
        const auto now = Clock::now();
        if (FAILED(value->CheckDefaultEndpoint(now))) return KN_AUDIO_UNAVAILABLE;
        if (now - value->lastRead > std::chrono::milliseconds(100)) value->converter->DiscardPending();
        value->lastRead = now;
        if (FAILED(value->Drain())) return KN_AUDIO_UNAVAILABLE;
        if (value->converter->PendingFrames() == 0 && timeout != 0) {
            const DWORD waited = WaitForSingleObject(value->event, timeout);
            if (waited != WAIT_OBJECT_0 && waited != WAIT_TIMEOUT) return KN_AUDIO_ERROR;
            if (FAILED(value->Drain())) return KN_AUDIO_UNAVAILABLE;
        }
        *frames = value->converter->Pop(samples, capacity, *first);
        if (*frames == 0) { *first = 0; return KN_AUDIO_AGAIN; }
        return KN_AUDIO_SAMPLE;
    } catch (...) { *frames = 0; *first = 0; return KN_AUDIO_ERROR; }
}
void KN_MEDIA_CALL kn_audio_close(void* session) {
    auto* value = static_cast<AudioSession*>(session);
    if (value && value->owner == GetCurrentThreadId()) delete value;
}
