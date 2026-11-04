// Standalone timer measurement: never links capture, codec, input, or DLL entry.
#include "media_wait.h"
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

namespace {
constexpr uint32_t Iterations = 64;
struct Measurement {
    std::vector<uint64_t> micros;
    uint64_t total = 0;
    uint32_t overFrameBudget = 0;
};

bool Counter(LARGE_INTEGER& value) { return QueryPerformanceCounter(&value) != FALSE; }
uint64_t Micros(LONGLONG ticks, LONGLONG frequency) {
    const uint64_t value = static_cast<uint64_t>(ticks), scale = static_cast<uint64_t>(frequency);
    return value / scale * 1000000ULL + value % scale * 1000000ULL / scale;
}

template<class Wait>
bool Measure(LONGLONG frequency, Wait&& wait, Measurement& measurement) {
    for (uint32_t i = 0; i < Iterations; ++i) {
        LARGE_INTEGER begin{}, end{};
        if (!Counter(begin) || !wait() || !Counter(end) || end.QuadPart < begin.QuadPart) return false;
        const uint64_t elapsed = Micros(end.QuadPart - begin.QuadPart, frequency);
        measurement.micros.push_back(elapsed);
        measurement.total += elapsed;
        if (elapsed > 16667) ++measurement.overFrameBudget;
    }
    std::sort(measurement.micros.begin(), measurement.micros.end());
    return measurement.micros.size() == Iterations;
}

void WriteMeasurement(std::ostream& json, const Measurement& measured) {
    json << "{\"p50Micros\":" << measured.micros[Iterations / 2]
        << ",\"p95Micros\":" << measured.micros[(Iterations * 95 + 99) / 100 - 1]
        << ",\"maximumMicros\":" << measured.micros.back()
        << ",\"totalMicros\":" << measured.total
        << ",\"over16667Micros\":" << measured.overFrameBudget << '}';
}

bool WriteExclusive(const wchar_t* path, const std::string& bytes) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const bool ok = bytes.size() <= MAXDWORD && WriteFile(file, bytes.data(),
        static_cast<DWORD>(bytes.size()), &written, nullptr) && written == bytes.size();
    const bool closed = CloseHandle(file) != FALSE;
    return ok && closed;
}
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 3 || std::wstring(argv[1]) != L"--json") {
        std::cerr << "usage: KnotNativeWaitChecks.exe --json fresh-report.json\n"; return 2;
    }
    LARGE_INTEGER frequency{};
    DWORD before = 0, during = 0, after = 0;
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0 ||
        !GetProcessHandleCount(GetCurrentProcess(), &before)) return 1;
    Measurement baseline, timer;
    bool unstartedRejected = false, expiredSkipped = false, singleHandle = false;
    {
        knot::MediaPollWait wait;
        unstartedRejected = wait.WaitUntil(knot::MediaPollWait::Clock::now() +
            std::chrono::milliseconds(1)) == E_HANDLE;
        if (FAILED(wait.Start()) || !GetProcessHandleCount(GetCurrentProcess(), &during)) return 1;
        const DWORD oneTimer = during;
        if (FAILED(wait.Start()) || !GetProcessHandleCount(GetCurrentProcess(), &during)) return 1;
        singleHandle = oneTimer == before + 1 && during == oneTimer;
        expiredSkipped = wait.WaitUntil(knot::MediaPollWait::Clock::now() -
            std::chrono::milliseconds(1)) == S_FALSE;
        if (!unstartedRejected || !singleHandle || !expiredSkipped) return 1;
        if (!Measure(frequency.QuadPart, [] { Sleep(1); return true; }, baseline) ||
            !Measure(frequency.QuadPart, [&] {
                return wait.WaitUntil(knot::MediaPollWait::Clock::now() +
                    std::chrono::milliseconds(450)) == S_OK;
            }, timer)) return 1;
        // These contract checks follow the unchanged 64x default-1ms QPC
        // comparison. Exact arithmetic proves clamping without asserting that
        // an OS scheduler meets a synthetic elapsed-time threshold.
        const uint64_t largest = (std::numeric_limits<uint64_t>::max)();
        if (knot::MediaPollIntervalNanoseconds(450000000, 8000) != 8000000 ||
            knot::MediaPollIntervalNanoseconds(450000000, largest) != 450000000 ||
            knot::MediaPollIntervalNanoseconds(500000000, largest) != 450000000 ||
            knot::MediaPollIntervalNanoseconds(10000000, largest) != 10000000 ||
            knot::MediaPollIntervalNanoseconds(75, 1000) != 75 ||
            knot::MediaPollIntervalNanoseconds(0, largest) != 0 ||
            knot::MediaPollIntervalNanoseconds(-1, largest) != 0 ||
            knot::MediaPollIntervalNanoseconds(450000000, 0) != 0 ||
            wait.WaitUntil(knot::MediaPollWait::Clock::now() +
                std::chrono::milliseconds(450), 0) != E_INVALIDARG ||
            wait.WaitUntil(knot::MediaPollWait::Clock::now() -
                std::chrono::milliseconds(1), largest) != S_FALSE ||
            wait.WaitUntil(knot::MediaPollWait::Clock::now() +
                std::chrono::milliseconds(450), 8000) != S_OK ||
            FAILED(wait.WaitUntil(knot::MediaPollWait::Clock::now() +
                std::chrono::milliseconds(10), largest))) return 1;
    }
    if (!GetProcessHandleCount(GetCurrentProcess(), &after) || after != before) return 1;
    std::ostringstream report;
    report << "{\"schema\":1,\"status\":\"PASS\",\"freshSyntheticOnly\":true,"
        "\"captureInvoked\":false,\"inputInvoked\":false,\"codecInvoked\":false,"
        "\"clock\":\"QueryPerformanceCounter\",\"iterations\":" << Iterations
        << ",\"requestedMicros\":1000,\"baselineSleep1\":";
    WriteMeasurement(report, baseline);
    report << ",\"ownedHighResolutionTimer\":";
    WriteMeasurement(report, timer);
    report << ",\"unstartedRejected\":true,\"expiredBudgetSkipped\":true,"
        "\"idempotentStartSingleHandle\":true,\"handlesRestored\":true,"
        "\"scope\":\"Measured fresh timer waits only; no production GPU, network or 4K60 acceptance\"}\n";
    if (!WriteExclusive(argv[2], report.str())) return 1;
    std::cout << "PASS: owned unnamed high-resolution wait; " << Iterations
        << " QPC samples per method; adaptive 8ms request, zero rejection, expired/oversize deadline clamps; "
        "no capture/input/codec; measurements are not a hardware throughput guarantee\n";
    return 0;
}
