//
// --------------------------------------------------------------------------
// RingMotionPlane.h
// Two independent TB800 ring axes under one generation and frame clock.
// --------------------------------------------------------------------------
//

#ifndef RingMotionPlane_h
#define RingMotionPlane_h

#include "RingInputCorrelator.h"
#include "RingMotionModel.h"

typedef struct MFRingMotionPlane {
    uint64_t generation;
    MFRingMotionState vertical;
    MFRingMotionState horizontal;
} MFRingMotionPlane;

typedef struct MFRingMotionPlaneFrame {
    bool accepted;
    bool invalidInterval;
    MFRingMotionFrame vertical;
    MFRingMotionFrame horizontal;
} MFRingMotionPlaneFrame;

static inline MFRingMotionConfig MFRingMotionConfigForAxis(
    MFRingMotionConfig config,
    MFRingAxis axis
) {
    if (axis == kMFRingAxisHorizontal) {
        config.accelerationGamma = 1.0 + (config.accelerationGamma - 1.0) * 0.25;
    }
    return config;
}

static inline void MFRingMotionPlaneInitialize(
    MFRingMotionPlane *plane,
    uint64_t generation
) {
    memset(plane, 0, sizeof(*plane));
    plane->generation = generation;
    MFRingMotionInitialize(&plane->vertical, generation);
    MFRingMotionInitialize(&plane->horizontal, generation);
}

static inline void MFRingMotionPlaneReset(
    MFRingMotionPlane *plane,
    uint64_t generation
) {
    MFRingMotionPlaneInitialize(plane, generation);
}

static inline MFRingMotionState *MFRingMotionPlaneStateForAxis(
    MFRingMotionPlane *plane,
    MFRingAxis axis
) {
    if (plane == NULL) return NULL;
    if (axis == kMFRingAxisVertical) return &plane->vertical;
    if (axis == kMFRingAxisHorizontal) return &plane->horizontal;
    return NULL;
}

static inline const MFRingMotionState *MFRingMotionPlaneConstStateForAxis(
    const MFRingMotionPlane *plane,
    MFRingAxis axis
) {
    if (plane == NULL) return NULL;
    if (axis == kMFRingAxisVertical) return &plane->vertical;
    if (axis == kMFRingAxisHorizontal) return &plane->horizontal;
    return NULL;
}

static inline MFRingMotionUpdate MFRingMotionPlaneApplyReport(
    const MFRingMotionConfig *config,
    MFRingMotionPlane *plane,
    MFRingAxis axis,
    MFRingMotionReport report
) {
    MFRingMotionState *state = MFRingMotionPlaneStateForAxis(plane, axis);
    if (state == NULL || plane->generation != report.generation) {
        MFRingMotionUpdate update = { 0 };
        update.staleGeneration = plane != NULL
            && plane->generation != report.generation;
        return update;
    }
    report.preserveLowSpeedReversalFrequency = axis == kMFRingAxisVertical;
    MFRingMotionConfig axisConfig = MFRingMotionConfigForAxis(*config, axis);
    return MFRingMotionApplyReport(&axisConfig, state, report);
}

static inline MFRingMotionFrame MFRingMotionPlaneAdvanceAxis(
    MFRingMotionState *state,
    double intervalSeconds
) {
    if (state != NULL && state->hasAcceptedReport) {
        return MFRingMotionAdvance(state, intervalSeconds);
    }
    MFRingMotionFrame frame = { 0 };
    frame.accepted = isfinite(intervalSeconds) && intervalSeconds > 0.0;
    frame.invalidInterval = !frame.accepted;
    return frame;
}

static inline MFRingMotionPlaneFrame MFRingMotionPlaneAdvance(
    MFRingMotionPlane *plane,
    double intervalSeconds
) {
    MFRingMotionPlaneFrame frame = { 0 };
    if (plane == NULL || !isfinite(intervalSeconds) || intervalSeconds <= 0.0) {
        frame.invalidInterval = true;
        return frame;
    }
    frame.vertical = MFRingMotionPlaneAdvanceAxis(
        &plane->vertical, intervalSeconds);
    frame.horizontal = MFRingMotionPlaneAdvanceAxis(
        &plane->horizontal, intervalSeconds);
    frame.accepted = frame.vertical.accepted && frame.horizontal.accepted;
    frame.invalidInterval = !frame.accepted;
    return frame;
}

static inline double MFRingMotionPlaneRemainingDistance(
    const MFRingMotionPlane *plane
) {
    if (plane == NULL) return 0.0;
    return MFRingMotionRemainingDistance(&plane->vertical)
        + MFRingMotionRemainingDistance(&plane->horizontal);
}

#endif /* RingMotionPlane_h */
