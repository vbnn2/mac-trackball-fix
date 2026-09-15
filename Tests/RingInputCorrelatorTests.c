//
// --------------------------------------------------------------------------
// RingInputCorrelatorTests.c
// Standalone deterministic regression checks.
// --------------------------------------------------------------------------
//

#include <assert.h>
#include <math.h>
#include <stdio.h>

#include "../Helper/Core/Scroll/RingInputCorrelator.h"

static MFRingRawSample sample(
    uint64_t sequence,
    uint64_t device,
    double timestamp,
    MFRingAxis axis,
    int64_t units
) {
    return (MFRingRawSample) {
        .sequence = sequence,
        .generation = 7,
        .deviceRegistryID = device,
        .timestamp = timestamp,
        .axis = axis,
        .signedUnits = units,
        .reportID = 1,
    };
}

static void testTB800AxisPolarityNormalization(void) {
    assert(MFRingNormalizeTB800Units(kMFRingAxisVertical, -1) == 1);
    assert(MFRingNormalizeTB800Units(kMFRingAxisVertical, 7) == -7);
    assert(MFRingNormalizeTB800Units(kMFRingAxisHorizontal, -3) == -3);
    assert(MFRingNormalizeTB800Units(kMFRingAxisHorizontal, 4) == 4);
}

static void testNearestCompatibleSampleWins(void) {
    MFRingInputBuffer buffer;
    MFRingInputBufferInitialize(&buffer);
    MFRingInputBufferPush(&buffer, sample(1, 42, 10.000, kMFRingAxisVertical, 1));
    MFRingInputBufferPush(&buffer, sample(2, 42, 10.006, kMFRingAxisVertical, 1));

    MFRingCorrelationResult result = MFRingInputBufferCorrelate(
        &buffer, 10.008, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);

    assert(result.source == kMFRingInputSourceHID);
    assert(result.rawSequence == 2);
    assert(result.rawGeneration == 7);
    assert(result.signedUnits == 1);
    assert(result.reportID == 1);
    assert(fabs(result.hidToCGSeconds - 0.002) < 0.000001);
    assert(result.magnitudeMatchesCGLine);
}

static void testWrongDeviceAxisAndSignCannotPair(void) {
    MFRingInputBuffer buffer;
    MFRingInputBufferInitialize(&buffer);
    MFRingInputBufferPush(&buffer, sample(1, 41, 20.000, kMFRingAxisVertical, 1));
    MFRingInputBufferPush(&buffer, sample(2, 42, 20.000, kMFRingAxisHorizontal, 1));
    MFRingInputBufferPush(&buffer, sample(3, 42, 20.000, kMFRingAxisVertical, -1));

    MFRingCorrelationResult result = MFRingInputBufferCorrelate(
        &buffer, 20.004, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);

    assert(result.source == kMFRingInputSourceCGLineFallback);
    assert(result.signedUnits == 1);
    assert(isnan(result.hidToCGSeconds));
}

static void testConsumedSampleCannotPairTwice(void) {
    MFRingInputBuffer buffer;
    MFRingInputBufferInitialize(&buffer);
    MFRingInputBufferPush(&buffer, sample(1, 42, 30.000, kMFRingAxisVertical, 1));

    MFRingCorrelationResult first = MFRingInputBufferCorrelate(
        &buffer, 30.002, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);
    MFRingCorrelationResult second = MFRingInputBufferCorrelate(
        &buffer, 30.003, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);

    assert(first.source == kMFRingInputSourceHID);
    assert(second.source == kMFRingInputSourceCGLineFallback);
}

static void testTimestampWindowAllowsTinySkewAndRejectsDistantSamples(void) {
    MFRingInputBuffer buffer;
    MFRingInputBufferInitialize(&buffer);
    MFRingInputBufferPush(&buffer, sample(1, 42, 40.002, kMFRingAxisVertical, 1));
    MFRingInputBufferPush(&buffer, sample(2, 42, 39.950, kMFRingAxisVertical, 1));

    MFRingCorrelationResult smallFutureSkew = MFRingInputBufferCorrelate(
        &buffer, 40.000, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);
    MFRingCorrelationResult stale = MFRingInputBufferCorrelate(
        &buffer, 40.000, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);

    assert(smallFutureSkew.source == kMFRingInputSourceHID);
    assert(smallFutureSkew.rawSequence == 1);
    assert(fabs(smallFutureSkew.hidToCGSeconds + 0.002) < 0.000001);
    assert(stale.source == kMFRingInputSourceCGLineFallback);

    MFRingInputBufferPush(&buffer, sample(3, 42, 40.003, kMFRingAxisVertical, 1));
    MFRingCorrelationResult excessiveFutureSkew = MFRingInputBufferCorrelate(
        &buffer, 40.000, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);
    assert(excessiveFutureSkew.source == kMFRingInputSourceCGLineFallback);
}

static void testMagnitudeMismatchRemainsObservable(void) {
    MFRingInputBuffer buffer;
    MFRingInputBufferInitialize(&buffer);
    MFRingInputBufferPush(&buffer, sample(1, 42, 50.000, kMFRingAxisVertical, 3));

    MFRingCorrelationResult result = MFRingInputBufferCorrelate(
        &buffer, 50.002, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);

    assert(result.source == kMFRingInputSourceHID);
    assert(result.signedUnits == 3);
    assert(!result.magnitudeMatchesCGLine);
}

static void testRemovalClearsOnlyThatDevice(void) {
    MFRingInputBuffer buffer;
    MFRingInputBufferInitialize(&buffer);
    MFRingInputBufferPush(&buffer, sample(1, 41, 60.000, kMFRingAxisVertical, 1));
    MFRingInputBufferPush(&buffer, sample(2, 42, 60.000, kMFRingAxisVertical, 1));
    MFRingInputBufferRemoveDevice(&buffer, 42);

    MFRingCorrelationResult removed = MFRingInputBufferCorrelate(
        &buffer, 60.002, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);
    MFRingCorrelationResult retained = MFRingInputBufferCorrelate(
        &buffer, 60.002, 41, kMFRingAxisVertical, 1, 1, 0.030, 0.002);

    assert(removed.source == kMFRingInputSourceCGLineFallback);
    assert(retained.source == kMFRingInputSourceHID);
}

static void testOverflowIsBoundedAndExplicit(void) {
    MFRingInputBuffer buffer;
    MFRingInputBufferInitialize(&buffer);

    for (size_t index = 0; index < MF_RING_INPUT_BUFFER_CAPACITY; index++) {
        assert(!MFRingInputBufferPush(
            &buffer,
            sample(index + 1, 42, 70.000 + (double)index, kMFRingAxisVertical, 1)));
    }

    assert(MFRingInputBufferPush(
        &buffer, sample(100, 42, 200.000, kMFRingAxisVertical, 1)));
    assert(buffer.overflowCount == 1);

    MFRingCorrelationResult newest = MFRingInputBufferCorrelate(
        &buffer, 200.001, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);
    assert(newest.source == kMFRingInputSourceHID);
    assert(newest.rawSequence == 100);
}

static void testExpiredSamplesAreReclaimed(void) {
    MFRingInputBuffer buffer;
    MFRingInputBufferInitialize(&buffer);
    MFRingInputBufferPush(&buffer, sample(1, 42, 10.000, kMFRingAxisVertical, -1));

    MFRingCorrelationResult fallback = MFRingInputBufferCorrelate(
        &buffer, 11.000, 42, kMFRingAxisVertical, 1, 1, 0.030, 0.002);
    assert(fallback.source == kMFRingInputSourceCGLineFallback);
    assert(!buffer.samples[0].occupied);
    assert(buffer.samples[0].consumed);
}

int main(void) {
    testTB800AxisPolarityNormalization();
    testNearestCompatibleSampleWins();
    testWrongDeviceAxisAndSignCannotPair();
    testConsumedSampleCannotPairTwice();
    testTimestampWindowAllowsTinySkewAndRejectsDistantSamples();
    testMagnitudeMismatchRemainsObservable();
    testRemovalClearsOnlyThatDevice();
    testOverflowIsBoundedAndExplicit();
    testExpiredSamplesAreReclaimed();

    puts("RingInputCorrelatorTests: PASS");
    return 0;
}
