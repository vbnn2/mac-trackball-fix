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

/// Keep every early wake-ramp report inside report one's responsive envelope.
/// Letting a live animator select the adaptive cap changed the response from
/// 80ms on report one to roughly 130ms on report two, which made the same
/// physical start feel inconsistent even though both outputs arrived on time.
static inline double MFScrollIdleWakeBaseDurationCap(
    double responsiveOpeningCap,
    double adaptiveOpeningCap
) {
    return responsiveOpeningCap < adaptiveOpeningCap
        ? responsiveOpeningCap
        : adaptiveOpeningCap;
}

/// macOS point deltas expose that a low-line-unit TB800 report is already in a
/// hardware acceleration ramp. Use that only as a binary response-shape signal:
/// never scale distance from it, and intervene only if either the line-derived
/// model or the point magnitude is rising while the response would otherwise
/// retarget live motion to a lower velocity. The point trend covers a captured
/// ramp whose longer packet gap made modeled speed fall even as point magnitude
/// rose from 6 to 14; a flat/falling point tail keeps ordinary deceleration.
static inline bool MFScrollShouldCapAcceleratingLowUnitRamp(
    bool overloadControlEnabled,
    bool hasMeasuredInterval,
    int64_t units,
    int64_t pointDelta,
    int64_t previousPointDelta,
    double modeledOutputSpeed,
    double previousModeledOutputSpeed,
    double slowCadenceSpeedMax,
    double animatorSpeed,
    double requestedTargetSpeed
) {
    const bool modeledSpeedIsRising = previousModeledOutputSpeed > 0.0
        && modeledOutputSpeed > previousModeledOutputSpeed;
    const bool pointMagnitudeIsRising = previousPointDelta > 0
        && pointDelta > previousPointDelta;

    return overloadControlEnabled
        && hasMeasuredInterval
        && units <= 2
        && pointDelta > units * 2
        && (modeledSpeedIsRising || pointMagnitudeIsRising)
        && modeledOutputSpeed < slowCadenceSpeedMax
        && animatorSpeed > 0.0
        && requestedTargetSpeed < animatorSpeed;
}

/// Slow-smoothing duration inflation exists only to overlap live motion across sparse
/// reports. Once the animator has stopped there is no motion left to preserve, so a small
/// slow report is a fresh visible opening and must stay inside the adaptive opening
/// envelope. This single rule replaces the previously scattered per-scenario stopped caps
/// (measured or remembered continuation, paused or unestablished reversal, sharp or
/// close-reversal tail): each was only a different classification path into the same
/// "stopped + small + slow" shape, and new report combinations kept slipping through.
/// Idle-wake, fast-tail, and expired-tail responses have their own tighter or separate
/// bounds and stay outside this rule via `tailPolicyActive`.
static inline bool MFScrollShouldCapStoppedSlowOpening(
    bool overloadControlEnabled,
    bool animatorRunning,
    bool slowSmoothingActive,
    bool tailPolicyActive,
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax
) {
    return overloadControlEnabled
        && !animatorRunning
        && slowSmoothingActive
        && !tailPolicyActive
        && units <= 2
        && modeledOutputSpeed > 0.0
        && modeledOutputSpeed < slowCadenceSpeedMax;
}

static inline double MFScrollStoppedSlowOpeningBaseDurationCap(
    double baseDuration,
    double adaptiveOpeningCap
) {
    return baseDuration < adaptiveOpeningCap
        ? baseDuration
        : adaptiveOpeningCap;
}

/// A one- or two-unit report can be the abrupt deceleration edge of faster motion rather
/// than evidence of deliberate sparse scrolling. Identify only a same-direction, measured
/// drop to at most the configured fraction of the immediately preceding modeled speed.
/// A collapse from amplified point magnitude back to the low-unit baseline is independent
/// evidence of the same tail edge when smoothing leaves the modeled ratio just above that
/// conservative threshold. The current report is always delivered; this classification
/// controls only whether it may seed a later sparse restart. Its stopped response envelope
/// is handled by the unified `MFScrollShouldCapStoppedSlowOpening` rule.
static inline bool MFScrollIsSharpDecelerationTailReport(
    bool overloadControlEnabled,
    bool hasMeasuredInterval,
    bool directionChanged,
    int64_t units,
    int64_t pointDelta,
    int64_t previousPointDelta,
    double modeledOutputSpeed,
    double previousModeledOutputSpeed,
    double slowCadenceSpeedMax,
    double currentToPreviousSpeedRatioMax
) {
    const bool modeledSpeedDroppedSharply =
        currentToPreviousSpeedRatioMax > 0.0
        && modeledOutputSpeed
            <= previousModeledOutputSpeed * currentToPreviousSpeedRatioMax;
    const bool amplifiedPointMagnitudeCollapsed =
        previousPointDelta > units * 2
        && pointDelta <= units * 2
        && pointDelta < previousPointDelta
        && modeledOutputSpeed < previousModeledOutputSpeed;

    return overloadControlEnabled
        && hasMeasuredInterval
        && !directionChanged
        && units <= 2
        && modeledOutputSpeed > 0.0
        && modeledOutputSpeed < slowCadenceSpeedMax
        && previousModeledOutputSpeed > 0.0
        && (modeledSpeedDroppedSharply || amplifiedPointMagnitudeCollapsed);
}

/// A report may seed sparse-cadence continuity only when the report itself looked like
/// deliberate careful motion. Mechanical-tail responses are deliberately excluded even
/// when their unit count and modeled speed happen to be low.
static inline bool MFScrollReportCanSeedSlowCadence(
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax,
    bool isFastTailResponse,
    bool isSettlingTailResponse,
    bool isSharpDecelerationTailResponse
) {
    return units <= 2
        && modeledOutputSpeed > 0.0
        && modeledOutputSpeed < slowCadenceSpeedMax
        && !isFastTailResponse
        && !isSettlingTailResponse
        && !isSharpDecelerationTailResponse;
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

/// A stale same-direction opening must not use its own preceding silence as an
/// animation-duration target when no cadence estimate existed before that
/// physical report. It may still select slow smoothing and publish the measured
/// gap for a future report. A direction change is different: its actual cross-
/// direction gap is the cadence signal used by the established close-reversal
/// policy, so preserve that bounded reference.
static inline double MFScrollSlowCadenceDurationReference(
    double priorEstimate,
    double updatedEstimate,
    double physicalInputGap,
    bool directionChanged,
    double gestureBoundary
) {
    double cadenceKnownBeforeReport = priorEstimate;
    if (cadenceKnownBeforeReport <= 0.0) {
        if (!directionChanged) {
            return 0.0;
        }
        cadenceKnownBeforeReport = physicalInputGap;
    }

    const double estimateBound = cadenceKnownBeforeReport < updatedEstimate
        ? cadenceKnownBeforeReport
        : updatedEstimate;
    return estimateBound < gestureBoundary ? estimateBound : gestureBoundary;
}

static inline double MFScrollSlowCadenceBaseDuration(
    double baseDuration,
    double durationReference,
    double durationRatio,
    double durationMax,
    double continuationBlend
) {
    const double scaledCadenceDuration = durationReference * durationRatio;
    const double cadenceDuration = scaledCadenceDuration < durationMax
        ? scaledCadenceDuration
        : durationMax;
    const double taperedCadenceDuration = baseDuration
        + continuationBlend * (cadenceDuration - baseDuration);
    return baseDuration > taperedCadenceDuration
        ? baseDuration
        : taperedCadenceDuration;
}

#endif /* ScrollCadencePolicy_h */
