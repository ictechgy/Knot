#pragma once

namespace knot {
// Enumeration still owns only candidates that have never been activated.
template<class Activation>
void ReleaseUnactivated(Activation*& source) {
    Activation* owned = source;
    source = nullptr;
    if (owned) owned->Release();
}

// Own the activation and its created object for the same lifetime. DetachObject
// is optional for IMFActivate, so ownership never depends on its implementation.
// Take transfers the caller's existing reference; no extra reference is made.
template<class Activation>
class ActivationOwner {
public:
    ActivationOwner() = default;
    ActivationOwner(const ActivationOwner&) = delete;
    ActivationOwner& operator=(const ActivationOwner&) = delete;
    ~ActivationOwner() { Reset(); }

    void Take(Activation*& source) {
        Reset();
        value_ = source;
        source = nullptr;
    }
    Activation* Get() const { return value_; }
    void Reset() {
        Activation* owned = value_;
        value_ = nullptr;
        if (owned) {
            owned->ShutdownObject();
            owned->Release();
        }
    }
private:
    Activation* value_ = nullptr;
};
} // namespace knot
