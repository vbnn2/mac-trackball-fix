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

/// A close slow reversal deliberately keeps cadence continuity on its first
/// opposite-direction report. If that bounded response finishes before the
/// immediately following small same-direction report arrives, allowing maximum
/// slow smoothing to restart from rest can make the continuation markedly weaker
/// than the reversal that opened it. Reuse the adaptive opening cap for that one
/// stopped continuation only. Live retargets and established sparse motion keep
/// their ordinary cadence response.
static inline bool MFScrollShouldCapStoppedCloseReversalContinuation(
    bool overloadControlEnabled,
    bool previousCloseReversalResponseExpired,
    bool firstConsecutive,
    bool directionChanged,
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax
) {
    return overloadControlEnabled
        && previousCloseReversalResponseExpired
        && !firstConsecutive
        && !directionChanged
        && units <= 2
        && modeledOutputSpeed > 0.0
        && modeledOutputSpeed < slowCadenceSpeedMax;
}

static inline double MFScrollStoppedCloseReversalBaseDurationCap(
    double baseDuration,
    double adaptiveOpeningCap
) {
    return baseDuration < adaptiveOpeningCap
        ? baseDuration
        : adaptiveOpeningCap;
}

/// Maximum slow smoothing helps only while repeated reports overlap an active response.
/// Once that response has already stopped, a measured one- or two-unit continuation is
/// visibly another opening; spreading it across the full slow base makes the restart
/// weak without preserving any motion across the preceding silence. Reuse the adaptive
/// opening envelope for that stopped continuation. Live sparse motion remains unchanged.
static inline bool MFScrollShouldCapStoppedSlowContinuation(
    bool overloadControlEnabled,
    bool hasMeasuredInterval,
    bool animatorRunning,
    bool firstConsecutive,
    bool directionChanged,
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax
) {
    return overloadControlEnabled
        && hasMeasuredInterval
        && !animatorRunning
        && !firstConsecutive
        && !directionChanged
        && units <= 2
        && modeledOutputSpeed > 0.0
        && modeledOutputSpeed < slowCadenceSpeedMax;
}

static inline double MFScrollStoppedSlowContinuationBaseDurationCap(
    double baseDuration,
    double adaptiveOpeningCap
) {
    return baseDuration < adaptiveOpeningCap
        ? baseDuration
        : adaptiveOpeningCap;
}

/// An analyzer timeout can label a same-direction sparse report as a new gesture while
/// cadence memory still supplies a long response base. If the remembered response has
/// already stopped, that cadence can no longer bridge the silence; retain the cadence
/// estimate for later reports but bound this visible opening to the adaptive envelope.
/// Require an established duration reference so an unestablished second sparse report
/// keeps the separately accepted measured-response behavior.
static inline bool MFScrollShouldCapStoppedRememberedSlowOpening(
    bool overloadControlEnabled,
    bool animatorRunning,
    bool firstConsecutive,
    bool directionChanged,
    bool slowCadenceContinuation,
    double slowCadenceDurationReference,
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax,
    double physicalInputGap,
    double gestureBoundary
) {
    return overloadControlEnabled
        && !animatorRunning
        && firstConsecutive
        && !directionChanged
        && slowCadenceContinuation
        && slowCadenceDurationReference > 0.0
        && units <= 2
        && modeledOutputSpeed > 0.0
        && modeledOutputSpeed < slowCadenceSpeedMax
        && physicalInputGap >= gestureBoundary;
}

/// A reversal just beyond the fully continuous close-reversal window can be
/// mistaken for established sparse cadence even when no cadence estimate
/// existed before this report. If the old response has already stopped, using
/// that report's own cross-direction silence weakens a visible opening without
/// preserving any motion across the gap. Bound only this unestablished stopped
/// opening; established and live close reversals retain cadence continuity.
static inline bool MFScrollShouldCapStoppedUnestablishedReversalOpening(
    bool overloadControlEnabled,
    bool animatorRunning,
    bool firstConsecutive,
    bool directionChanged,
    bool slowCadenceContinuation,
    double priorCadenceEstimate,
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax,
    double physicalInputGap,
    double closeReversalFullBlendInterval,
    double gestureBoundary
) {
    return overloadControlEnabled
        && !animatorRunning
        && firstConsecutive
        && directionChanged
        && slowCadenceContinuation
        && priorCadenceEstimate <= 0.0
        && units <= 2
        && modeledOutputSpeed > 0.0
        && modeledOutputSpeed < slowCadenceSpeedMax
        && physicalInputGap > closeReversalFullBlendInterval
        && physicalInputGap < gestureBoundary;
}

/// A paused reversal whose preceding response has already stopped is visually a new
/// opening, even though retaining some cross-direction cadence remains useful. Preserve
/// the accepted response through `capBlendStartInterval`, then continuously introduce
/// the adaptive opening cap until it is fully applied at `capFullInterval`. Close and
/// live reversals retain their existing continuity.
static inline double MFScrollStoppedPausedReversalOpeningCapBlend(
    bool overloadControlEnabled,
    bool animatorRunning,
    bool firstConsecutive,
    bool directionChanged,
    bool slowCadenceContinuation,
    int64_t units,
    double modeledOutputSpeed,
    double slowCadenceSpeedMax,
    double physicalInputGap,
    double capBlendStartInterval,
    double capFullInterval,
    double gestureBoundary
) {
    if (!overloadControlEnabled
        || animatorRunning
        || !firstConsecutive
        || !directionChanged
        || !slowCadenceContinuation
        || units > 2
        || modeledOutputSpeed <= 0.0
        || modeledOutputSpeed >= slowCadenceSpeedMax
        || physicalInputGap <= capBlendStartInterval
        || physicalInputGap >= gestureBoundary
        || capFullInterval <= capBlendStartInterval) {
        return 0.0;
    }

    if (physicalInputGap >= capFullInterval) {
        return 1.0;
    }
    return (physicalInputGap - capBlendStartInterval)
        / (capFullInterval - capBlendStartInterval);
}

static inline double MFScrollStoppedPausedReversalBaseDuration(
    double baseDuration,
    double adaptiveOpeningCap,
    double openingCapBlend
) {
    double boundedBlend = openingCapBlend;
    if (boundedBlend < 0.0) boundedBlend = 0.0;
    if (boundedBlend > 1.0) boundedBlend = 1.0;
    const double cappedBaseDuration = baseDuration < adaptiveOpeningCap
        ? baseDuration
        : adaptiveOpeningCap;
    return baseDuration
        + boundedBlend * (cappedBaseDuration - baseDuration);
}

/// A one- or two-unit report can be the abrupt deceleration edge of faster motion rather
/// than evidence of deliberate sparse scrolling. Identify only a same-direction, measured
/// drop to at most the configured fraction of the immediately preceding modeled speed.
/// A collapse from amplified point magnitude back to the low-unit baseline is independent
/// evidence of the same tail edge when smoothing leaves the modeled ratio just above that
/// conservative threshold. The current report is always delivered; this classification
/// controls only its response envelope when motion has stopped and whether it may seed a
/// later sparse restart.
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

static inline bool MFScrollShouldCapStoppedSharpDecelerationTail(
    bool isSharpDecelerationTailReport,
    bool animatorRunning
) {
    return isSharpDecelerationTailReport && !animatorRunning;
}

static inline double MFScrollStoppedSharpDecelerationBaseDurationCap(
    double baseDuration,
    double adaptiveOpeningCap
) {
    return baseDuration < adaptiveOpeningCap
        ? baseDuration
        : adaptiveOpeningCap;
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
