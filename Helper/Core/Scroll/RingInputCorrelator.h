//
// --------------------------------------------------------------------------
// RingInputCorrelator.h
// Deterministic raw-HID/CGEvent pairing for the TB800 ring rewrite.
// --------------------------------------------------------------------------
//

#ifndef RingInputCorrelator_h
#define RingInputCorrelator_h

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/// The source is intentionally bounded. Correlation is telemetry-only in Phase 1,
/// so overflowing a slot is recorded and never allowed to stall physical input.
#define MF_RING_INPUT_BUFFER_CAPACITY 64

typedef enum MFRingAxis {
    kMFRingAxisNone = 0,
    kMFRingAxisVertical = 1,
    kMFRingAxisHorizontal = 2,
} MFRingAxis;

typedef enum MFRingInputSource {
    kMFRingInputSourceCGLineFallback = 0,
    kMFRingInputSourceHID = 1,
} MFRingInputSource;

typedef struct MFRingRawSample {
    bool occupied;
    bool consumed;
    uint64_t sequence;
    uint64_t generation;
    uint64_t deviceRegistryID;
    double timestamp;
    MFRingAxis axis;
    int64_t signedUnits;
    uint32_t reportID;
} MFRingRawSample;

typedef struct MFRingInputBuffer {
    MFRingRawSample samples[MF_RING_INPUT_BUFFER_CAPACITY];
    size_t nextInsertionIndex;
    uint64_t overflowCount;
} MFRingInputBuffer;

typedef struct MFRingCorrelationResult {
    MFRingInputSource source;
    int64_t signedUnits;
    uint64_t rawSequence;
    uint64_t rawGeneration;
    uint64_t deviceRegistryID;
    uint32_t reportID;
    double hidToCGSeconds;
    bool magnitudeMatchesCGLine;
} MFRingCorrelationResult;

/// CG line magnitudes already include WindowServer acceleration. They remain
/// immediately usable by legacy, but must never enter the raw-count speed map.
static inline bool MFRingCorrelationHasRawMotionUnits(MFRingCorrelationResult result) {
    return result.source == kMFRingInputSourceHID && result.signedUnits != 0;
}

static inline int MFRingSign(int64_t value) {
    return (value > 0) - (value < 0);
}

/// Normalize the locally observed TB800 HID element polarity into the same
/// coordinate convention used by CGEvent scroll deltas. The receiver's Wheel
/// element is inverted; its Consumer Pan element is not.
static inline int64_t MFRingNormalizeTB800Units(
    MFRingAxis axis,
    int64_t rawSignedUnits
) {
    return axis == kMFRingAxisVertical
        ? -rawSignedUnits
        : rawSignedUnits;
}

static inline void MFRingInputBufferInitialize(MFRingInputBuffer *buffer) {
    memset(buffer, 0, sizeof(*buffer));
}

/// Returns true when an unconsumed sample had to be overwritten. The newest
/// physical sample always wins; callers expose the loss through telemetry.
static inline bool MFRingInputBufferPush(
    MFRingInputBuffer *buffer,
    MFRingRawSample sample
) {
    if (sample.axis == kMFRingAxisNone || sample.signedUnits == 0) {
        return false;
    }

    size_t index = buffer->nextInsertionIndex;
    bool overflowed = buffer->samples[index].occupied
        && !buffer->samples[index].consumed;
    if (overflowed) {
        buffer->overflowCount += 1;
    }

    sample.occupied = true;
    sample.consumed = false;
    buffer->samples[index] = sample;
    buffer->nextInsertionIndex =
        (index + 1) % MF_RING_INPUT_BUFFER_CAPACITY;
    return overflowed;
}

static inline void MFRingInputBufferRemoveDevice(
    MFRingInputBuffer *buffer,
    uint64_t deviceRegistryID
) {
    for (size_t index = 0; index < MF_RING_INPUT_BUFFER_CAPACITY; index++) {
        MFRingRawSample *sample = &buffer->samples[index];
        if (sample->occupied
            && sample->deviceRegistryID == deviceRegistryID) {
            sample->occupied = false;
            sample->consumed = true;
        }
    }
}

/// Pair the closest compatible raw report without waiting. Device, axis, sign,
/// and a bounded timestamp distance must all agree. A miss immediately returns
/// the CG line fallback and leaves incompatible raw samples available for their
/// actual events.
static inline MFRingCorrelationResult MFRingInputBufferCorrelate(
    MFRingInputBuffer *buffer,
    double cgTimestamp,
    uint64_t deviceRegistryID,
    MFRingAxis axis,
    int64_t cgLineUnits,
    int64_t cgFallbackUnits,
    double maximumHIDAge,
    double maximumHIDFutureSkew
) {
    MFRingCorrelationResult result = {
        .source = kMFRingInputSourceCGLineFallback,
        .signedUnits = cgFallbackUnits,
        .deviceRegistryID = deviceRegistryID,
        .hidToCGSeconds = NAN,
        .magnitudeMatchesCGLine = false,
    };

    if (axis == kMFRingAxisNone
        || cgFallbackUnits == 0
        || maximumHIDAge < 0.0
        || maximumHIDFutureSkew < 0.0) {
        return result;
    }

    MFRingRawSample *best = NULL;
    double bestAbsoluteDelta = INFINITY;
    int expectedSign = MFRingSign(cgLineUnits != 0
        ? cgLineUnits
        : cgFallbackUnits);

    for (size_t index = 0; index < MF_RING_INPUT_BUFFER_CAPACITY; index++) {
        MFRingRawSample *candidate = &buffer->samples[index];
        if (candidate->occupied
            && !candidate->consumed
            && cgTimestamp - candidate->timestamp > maximumHIDAge) {
            candidate->occupied = false;
            candidate->consumed = true;
            continue;
        }
        if (!candidate->occupied
            || candidate->consumed
            || candidate->deviceRegistryID != deviceRegistryID
            || candidate->axis != axis
            || MFRingSign(candidate->signedUnits) != expectedSign) {
            continue;
        }

        double hidToCGDelta = cgTimestamp - candidate->timestamp;
        double absoluteDelta = fabs(hidToCGDelta);
        if (hidToCGDelta <= maximumHIDAge
            && hidToCGDelta >= -maximumHIDFutureSkew - 1e-9
            && absoluteDelta < bestAbsoluteDelta) {
            best = candidate;
            bestAbsoluteDelta = absoluteDelta;
        }
    }

    if (best == NULL) {
        return result;
    }

    best->consumed = true;
    result.source = kMFRingInputSourceHID;
    result.signedUnits = best->signedUnits;
    result.rawSequence = best->sequence;
    result.rawGeneration = best->generation;
    result.deviceRegistryID = best->deviceRegistryID;
    result.reportID = best->reportID;
    result.hidToCGSeconds = cgTimestamp - best->timestamp;
    result.magnitudeMatchesCGLine = cgLineUnits != 0
        && best->signedUnits == cgLineUnits;
    return result;
}

#endif /* RingInputCorrelator_h */
