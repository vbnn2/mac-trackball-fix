//
// --------------------------------------------------------------------------
// DisplayLinkLifecyclePolicy.h
// Pure generation policy for deferred CVDisplayLink starts.
// --------------------------------------------------------------------------
//

#ifndef DisplayLinkLifecyclePolicy_h
#define DisplayLinkLifecyclePolicy_h

#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>

static inline uint64_t MFDisplayLinkNextGeneration(uint64_t generation) {
    generation += 1;
    return generation == 0 ? 1 : generation;
}

static inline bool MFDisplayLinkShouldResumeDeferredStart(
    bool startIsPending,
    bool requestedRunning,
    uint64_t currentGeneration,
    uint64_t deferredStartGeneration
) {
    return startIsPending
        && requestedRunning
        && deferredStartGeneration != 0
        && deferredStartGeneration == currentGeneration;
}

/// Admit at most one queued callback. The queue clears this bit as it begins
/// delivery, allowing one following frame to wait without permitting an
/// unbounded display-rate backlog.
static inline bool MFDisplayLinkTryQueueCallback(atomic_bool *callbackQueued) {
    return !atomic_exchange_explicit(
        callbackQueued,
        true,
        memory_order_acq_rel);
}

static inline void MFDisplayLinkDidBeginQueuedCallback(
    atomic_bool *callbackQueued
) {
    atomic_store_explicit(
        callbackQueued,
        false,
        memory_order_release);
}

#endif /* DisplayLinkLifecyclePolicy_h */
