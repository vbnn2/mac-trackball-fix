//
// --------------------------------------------------------------------------
// ScrollCadencePolicy.h
// Pure policy helpers for sparse-scroll cadence continuity.
// --------------------------------------------------------------------------
//

#ifndef ScrollCadencePolicy_h
#define ScrollCadencePolicy_h

#include <stdbool.h>
#include <stdint.h>

/// Some TB800 starts after a long wheel-idle interval arrive as a short ramp of
/// one-unit reports before the hardware reaches the cadence implied by the physical
/// spin. The first report already receives the bounded opening response. Keep that
/// bound through the measured hardware-ramp interval, then continuously fade it out
/// instead of interpreting silence before report two as completed wake progress.
///
/// This is a response-shape decision on the current report. It never waits for,
/// confirms, or replays input, and a substantial/fast report bypasses it immediately.
static inline double MFScrollIdleWakeOpeningCapBlend(
    bool overloadControlEnabled,
    bool firstConsecutive,
    double idleBeforeOpening,
    double elapsedSinceOpening,
    double idleThreshold,
    double responseHoldDuration,
    double responseFadeDuration,
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax
) {
    if (!overloadControlEnabled
        || firstConsecutive
        || idleBeforeOpening < idleThreshold
        || elapsedSinceOpening <= 0.0
        || responseHoldDuration < 0.0
        || responseFadeDuration <= 0.0
        || units > 2
        || modeledOutputSpeed <= 0.0
        || modeledOutputSpeed >= slowCadenceSpeedMax) {
        return 0.0;
    }

    const double fadeElapsed = elapsedSinceOpening - responseHoldDuration;
    if (fadeElapsed <= 0.0) {
        return 1.0;
    }
    if (fadeElapsed >= responseFadeDuration) {
        return 0.0;
    }

    return 1.0 - fadeElapsed / responseFadeDuration;
}

/// A wake-ramp report that arrives after the preceding bounded response has
/// stopped is another visible opening. Keep its base-duration cap identical to
/// report one's responsive cap. A live animator already supplies continuity,
/// so its retarget may preserve the adaptive slow-smoothness duration cap.
static inline double MFScrollIdleWakeBaseDurationCap(
    bool animatorRunning,
    double responsiveOpeningCap,
    double adaptiveOpeningCap
) {
    return animatorRunning ? adaptiveOpeningCap : responsiveOpeningCap;
}

/// macOS point deltas expose that a low-line-unit TB800 report is already in a
/// hardware acceleration ramp. Use that only as a binary response-shape signal:
/// never scale distance from it, and intervene only if rising modeled speed
/// would otherwise retarget a live opening to a lower velocity.
static inline bool MFScrollShouldCapAcceleratingLowUnitRamp(
    bool overloadControlEnabled,
    bool hasMeasuredInterval,
    int64_t units,
    int64_t pointDelta,
    double modeledOutputSpeed,
    double previousModeledOutputSpeed,
    double slowCadenceSpeedMax,
    double animatorSpeed,
    double requestedTargetSpeed
) {
    return overloadControlEnabled
        && hasMeasuredInterval
        && units <= 2
        && pointDelta > units * 2
        && previousModeledOutputSpeed > 0.0
        && modeledOutputSpeed > previousModeledOutputSpeed
        && modeledOutputSpeed < slowCadenceSpeedMax
        && animatorSpeed > 0.0
        && requestedTargetSpeed < animatorSpeed;
}

/// A report may seed sparse-cadence continuity only when the report itself looked like
/// deliberate careful motion. Mechanical-tail responses are deliberately excluded even
/// when their unit count and modeled speed happen to be low.
static inline bool MFScrollReportCanSeedSlowCadence(
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax,
    bool isFastTailResponse,
    bool isSettlingTailResponse
) {
    return units <= 2
        && modeledOutputSpeed > 0.0
        && modeledOutputSpeed < slowCadenceSpeedMax
        && !isFastTailResponse
        && !isSettlingTailResponse;
}

/// Decide whether a first analyzer report may reuse sparse cadence.
///
/// `previousReportCanSeedSlowCadence` is intentionally stronger than checking the
/// previous modeled speed alone. A decelerated multi-unit report can have a low modeled
/// speed while still being the end of a fast gesture; it must not make a later opening
/// report use that opening report's own long gap as animation duration.
static inline bool MFScrollShouldContinueSlowCadence(
    bool overloadControlEnabled,
    bool firstConsecutive,
    bool previousReportCanSeedSlowCadence,
    int64_t units,
    bool directionChanged,
    double physicalInputGap,
    double consecutiveIntervalMax,
    double memoryMaxInterval
) {
    return overloadControlEnabled
        && firstConsecutive
        && previousReportCanSeedSlowCadence
        && units <= 2
        && (directionChanged || physicalInputGap > consecutiveIntervalMax)
        && physicalInputGap <= memoryMaxInterval;
}

#endif /* ScrollCadencePolicy_h */
