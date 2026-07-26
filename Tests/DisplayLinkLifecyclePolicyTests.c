//
// --------------------------------------------------------------------------
// DisplayLinkLifecyclePolicyTests.c
// Standalone deterministic regression checks.
// --------------------------------------------------------------------------
//

#include <assert.h>
#include <stdio.h>

#include "../Shared/Animation/DisplayLinkLifecyclePolicy.h"

static void testCancelInvalidatesDeferredStart(void) {
    uint64_t generation = MFDisplayLinkNextGeneration(0);
    const uint64_t deferredStartGeneration = generation;

    generation = MFDisplayLinkNextGeneration(generation);

    assert(!MFDisplayLinkShouldResumeDeferredStart(
        true,
        false,
        generation,
        deferredStartGeneration
    ));
}

static void testNewStartAfterCancelMayResume(void) {
    uint64_t generation = MFDisplayLinkNextGeneration(0);
    generation = MFDisplayLinkNextGeneration(generation);
    generation = MFDisplayLinkNextGeneration(generation);
    const uint64_t deferredStartGeneration = generation;

    assert(MFDisplayLinkShouldResumeDeferredStart(
        true,
        true,
        generation,
        deferredStartGeneration
    ));
}

static void testStaleGenerationNeverResumes(void) {
    assert(!MFDisplayLinkShouldResumeDeferredStart(true, true, 8, 7));
    assert(!MFDisplayLinkShouldResumeDeferredStart(false, true, 8, 8));
}

static void testCallbackAdmissionBoundsQueueDepth(void) {
    atomic_bool callbackQueued;
    atomic_init(&callbackQueued, false);

    assert(MFDisplayLinkTryQueueCallback(&callbackQueued));
    assert(!MFDisplayLinkTryQueueCallback(&callbackQueued));

    MFDisplayLinkDidBeginQueuedCallback(&callbackQueued);
    assert(MFDisplayLinkTryQueueCallback(&callbackQueued));
    MFDisplayLinkDidBeginQueuedCallback(&callbackQueued);
}

int main(void) {
    testCancelInvalidatesDeferredStart();
    testNewStartAfterCancelMayResume();
    testStaleGenerationNeverResumes();
    testCallbackAdmissionBoundsQueueDepth();

    puts("DisplayLinkLifecyclePolicyTests: PASS");
    return 0;
}
