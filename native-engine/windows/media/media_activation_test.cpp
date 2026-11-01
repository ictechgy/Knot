// Exact production activation ownership policy with fresh fake references.
// No Windows, COM, codec, desktop, files, capture, input, or UI APIs.
#include "media_activation.h"
#include <iostream>

namespace {
struct State {
    unsigned shutdowns = 0, releases = 0, destroys = 0, detaches = 0;
    bool active = false;
};
class FakeActivation {
public:
    explicit FakeActivation(State& state) : state_(state) {}
    bool Activate(bool configureSucceeds) {
        // A failed configuration can still have created a live transform.
        state_.active = true;
        return configureSucceeds;
    }
    int DetachObject() { ++state_.detaches; return -1; } // optional, unavailable
    void ShutdownObject() { ++state_.shutdowns; state_.active = false; }
    void Release() { ++state_.releases; delete this; }
    bool Usable() const { return state_.active; }
private:
    ~FakeActivation() { ++state_.destroys; }
    State& state_;
};

bool SelectionSurvivesEnumerationCleanup() {
    State failed, selected, unused;
    FakeActivation* entries[] = {new FakeActivation(failed), new FakeActivation(selected), new FakeActivation(unused)};
    knot::ActivationOwner<FakeActivation> owner;
    owner.Take(entries[0]);
    if (entries[0] != nullptr || owner.Get()->Activate(false)) return false;
    // The same transfer used by Encoder::Start cleans the previous failed
    // configuration before selecting the next activation.
    owner.Take(entries[1]);
    if (entries[1] != nullptr || !owner.Get()->Activate(true)) return false;
    if (failed.shutdowns != 1 || failed.releases != 1 || failed.destroys != 1 || failed.active) return false;
    for (auto*& entry : entries) knot::ReleaseUnactivated(entry);
    if (unused.shutdowns != 0 || unused.releases != 1 || unused.destroys != 1 ||
        selected.shutdowns != 0 || selected.releases != 0 || !owner.Get()->Usable()) return false;
    // Enumeration cleanup must not shut down the selected, configured object.
    // This remains true when DetachObject is unsupported because it is unused.
    if (failed.detaches != 0 || selected.detaches != 0 || unused.detaches != 0) return false;
    owner.Reset();
    owner.Reset();
    return owner.Get() == nullptr && selected.shutdowns == 1 && selected.releases == 1 &&
        selected.destroys == 1 && !selected.active && selected.detaches == 0;
}

bool FailedLastCandidateAndDestructor() {
    State failed;
    {
        knot::ActivationOwner<FakeActivation> owner;
        FakeActivation* entry = new FakeActivation(failed);
        owner.Take(entry);
        if (entry != nullptr || owner.Get()->Activate(false)) return false;
        owner.Reset();
    }
    if (failed.shutdowns != 1 || failed.releases != 1 || failed.destroys != 1 || failed.active) return false;
    State successful;
    {
        knot::ActivationOwner<FakeActivation> owner;
        FakeActivation* entry = new FakeActivation(successful);
        owner.Take(entry);
        if (!owner.Get()->Activate(true)) return false;
    }
    return successful.shutdowns == 1 && successful.releases == 1 &&
        successful.destroys == 1 && !successful.active && successful.detaches == 0;
}

bool UncreatedAndEmptyOwner() {
    State state;
    {
        knot::ActivationOwner<FakeActivation> empty;
        empty.Reset();
        FakeActivation* absent = nullptr;
        empty.Take(absent);
        if (empty.Get() != nullptr) return false;
        FakeActivation* entry = new FakeActivation(state);
        empty.Take(entry); // ActivateObject may fail before returning an object.
    }
    return state.shutdowns == 1 && state.releases == 1 && state.destroys == 1 &&
        state.detaches == 0 && !state.active;
}
} // namespace

int main() {
    if (!SelectionSurvivesEnumerationCleanup() || !FailedLastCandidateAndDestructor() || !UncreatedAndEmptyOwner()) {
        std::cerr << "Native activation ownership checks failed\n";
        return 1;
    }
    std::cout << "Native activation ownership checks passed (fresh fake activations; no Windows, codec, capture or input)\n";
    return 0;
}
