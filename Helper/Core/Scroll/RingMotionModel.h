//
// --------------------------------------------------------------------------
// RingMotionModel.h
// Pure deterministic motion core for the TB800 free-rotating ring.
// --------------------------------------------------------------------------
//

#ifndef RingMotionModel_h
#define RingMotionModel_h

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef struct MFRingMotionConfig {
    bool normalDistanceForStoppedOpenings;
    double referenceSpeedUnitsPerSecond;
    double pixelsPerUnitAtReferenceSpeed;
    double accelerationGamma;
    double distanceMultiplier;
    double initialSpeedUnitsPerSecond;
    double speedFloorUnitsPerSecond;
    double attackTimeConstantSeconds;
    double releaseTimeConstantSeconds;
    double startDecaySeconds;
    double normalDecaySeconds;
    double fastDecayMinimumSeconds;
    double fastDecayStartSpeedUnitsPerSecond;
    double fastDecayFullSpeedUnitsPerSecond;
    double visibilityWindowSeconds;
    double minimumVisibleOutputPixels;
    double minimumStoppedOpeningVisibleOutputPixels;
    double sparseDecayMinimumSeconds;
    double sparseDecayMaximumSeconds;
    double sparseCadenceOverlapRatio;
    double sparseBlendEndSpeedUnitsPerSecond;
    double cadenceEstimateAlpha;
    double cadenceMemorySeconds;
    double maximumInitialDistancePixels;
    double maximumOutputVelocityPixelsPerSecond;
    double maximumRemainingDistancePixels;
} MFRingMotionConfig;

/// Immutable UI/config snapshot used to construct explicit model units. This
/// keeps Swift/Objective-C configuration lookup outside the pure core.
typedef struct MFRingMotionUIParameters {
    double sensitivity;
    double acceleration;
    double adaptiveSmoothnessEndSpeedRatio;
    double glide;
    double distanceMultiplier;
    double attackTimeConstantSeconds;
    double releaseTimeConstantSeconds;
    double initialVelocityIntervalSeconds;
    double startDecaySeconds;
    double slowCadenceDurationRatio;
    double slowCadenceDurationMaximumSeconds;
    double cadenceEstimateAlpha;
    double cadenceMemorySeconds;
    double maximumSpeedSetting;
} MFRingMotionUIParameters;

typedef struct MFRingMotionState {
    uint64_t generation;
    bool hasAcceptedReport;
    double lastAcceptedReportTimestamp;
    int lastInputSign;
    double filteredSpeedUnitsPerSecond;
    double cadenceEstimateSeconds;
    double cadenceConfidence;
    double velocityPixelsPerSecond;
    double decaySeconds;
} MFRingMotionState;

typedef struct MFRingMotionReport {
    uint64_t generation;
    double timestamp;
    int64_t signedUnits;
} MFRingMotionReport;

typedef struct MFRingMotionUpdate {
    bool accepted;
    bool staleGeneration;
    bool invalidTimestamp;
    bool directionChanged;
    bool lowSpeedReversalFrequencyPreserved;
    bool hasMeasuredCadence;
    bool initialDistanceLimited;
    bool velocityLimited;
    bool remainingDistanceLimited;
    bool responsivenessDecayLimited;
    bool startsFromStoppedOutput;
    bool stoppedOpeningResponsivenessDecayLimited;
    bool stoppedOpeningVelocityDecayLimited;
    bool continuityOpeningDecayLimited;
    bool stoppedOpeningDistanceRaised;
    double reportIntervalSeconds;
    double rawSpeedUnitsPerSecond;
    double filteredSpeedUnitsPerSecond;
    double cadenceEstimateSeconds;
    double cadenceConfidence;
    double pixelsPerUnit;
    double decaySeconds;
    double velocityBeforePixelsPerSecond;
    double carriedVelocityPixelsPerSecond;
    double impulseVelocityPixelsPerSecond;
    double velocityAfterPixelsPerSecond;
    double remainingDistancePixels;
    double carryDroppedPixels;
} MFRingMotionUpdate;

typedef struct MFRingMotionFrame {
    bool accepted;
    bool invalidInterval;
    double distancePixels;
    double velocityAfterPixelsPerSecond;
    double remainingDistancePixels;
} MFRingMotionFrame;

static inline double MFRingMotionClamp(
    double value,
    double minimum,
    double maximum
) {
    return fmin(maximum, fmax(minimum, value));
}

static inline double MFRingMotionSmoothstep(double edge0, double edge1, double x) {
    if (edge0 == edge1) return x < edge0 ? 0.0 : 1.0;
    double t = MFRingMotionClamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - (2.0 * t));
}

static inline MFRingMotionConfig MFRingMotionConfigFromUI(
    MFRingMotionUIParameters ui
) {
    /// Raw TB800 reports are signed one-count impulses. The old 50 u/s pivot
    /// came from accelerated CG line deltas and is not the same unit domain.
    /// The first Phase 3 capture places careful raw motion near 5 reports/s and
    /// sustained free-spin delivery near 50 reports/s.
    double referenceSpeed = 5.0;
    double outputCalibrationSpeed = 50.0;
    double pixelsPerUnit = 10.0 + (ui.sensitivity * 100.0);
    double gamma = 1.0 + ui.acceleration;
    double maximumOutputVelocity = pixelsPerUnit * outputCalibrationSpeed
        * (30.0 * fmax(0.1, ui.maximumSpeedSetting));
    double referenceOutputVelocity = pixelsPerUnit * referenceSpeed
        * ui.distanceMultiplier;
    double adaptiveOutputVelocity = maximumOutputVelocity
        * ui.adaptiveSmoothnessEndSpeedRatio;
    double adaptiveInputSpeed = referenceSpeed;
    if (referenceOutputVelocity > 0.0 && gamma > 0.0) {
        adaptiveInputSpeed = referenceSpeed * pow(
            fmax(adaptiveOutputVelocity / referenceOutputVelocity, DBL_MIN),
            1.0 / gamma);
    }
    double dragCoefficient = 40.0 - (ui.glide * 35.0);
    double normalDecay = 1.0 / fmax(dragCoefficient, DBL_MIN);

    return (MFRingMotionConfig) {
        .normalDistanceForStoppedOpenings = true,
        .referenceSpeedUnitsPerSecond = referenceSpeed,
        .pixelsPerUnitAtReferenceSpeed = pixelsPerUnit,
        .accelerationGamma = gamma,
        .distanceMultiplier = ui.distanceMultiplier,
        .initialSpeedUnitsPerSecond = 1.0 / ui.initialVelocityIntervalSeconds,
        .speedFloorUnitsPerSecond = 1.0,
        .attackTimeConstantSeconds = ui.attackTimeConstantSeconds,
        .releaseTimeConstantSeconds = ui.releaseTimeConstantSeconds,
        .startDecaySeconds = ui.startDecaySeconds,
        .normalDecaySeconds = normalDecay,
        /// At free-spin speed, the remaining-area budget must not become a
        /// lower accidental speed ceiling than maximumOutputVelocity. Raise
        /// friction instead of retaining a longer post-stop tail.
        .fastDecayMinimumSeconds = maximumOutputVelocity > 0.0
            ? (pixelsPerUnit * outputCalibrationSpeed * 0.525)
                / maximumOutputVelocity
            : normalDecay,
        .fastDecayStartSpeedUnitsPerSecond = 20.0,
        .fastDecayFullSpeedUnitsPerSecond = outputCalibrationSpeed,
        /// Ensure a low-energy accepted report can cross one integer pixel
        /// within two callbacks even on the fastest tested 144 Hz schedule.
        .visibilityWindowSeconds = 2.0 / 144.0,
        .minimumVisibleOutputPixels = 1.0,
        /// A stopped axis has no visible motion left for sparse decay to
        /// preserve. Three pixels in the two-callback window is the smallest
        /// physical setting that avoided the captured two-pixel start notch.
        .minimumStoppedOpeningVisibleOutputPixels = 3.0,
        .sparseDecayMinimumSeconds = fmax(ui.startDecaySeconds, normalDecay),
        .sparseDecayMaximumSeconds = ui.slowCadenceDurationMaximumSeconds
            * ui.slowCadenceDurationRatio,
        .sparseCadenceOverlapRatio = ui.slowCadenceDurationRatio,
        .sparseBlendEndSpeedUnitsPerSecond = adaptiveInputSpeed,
        .cadenceEstimateAlpha = ui.cadenceEstimateAlpha,
        .cadenceMemorySeconds = ui.cadenceMemorySeconds,
        .maximumInitialDistancePixels = pixelsPerUnit * 15.0,
        .maximumOutputVelocityPixelsPerSecond = maximumOutputVelocity,
        .maximumRemainingDistancePixels = pixelsPerUnit
            * outputCalibrationSpeed * 0.525,
    };
}

/// Phase 2 baseline mapping for the current default UI values. It is suitable
/// for replay/shadow diagnostics; physical A/B tuning remains a later gate.
static inline MFRingMotionConfig MFRingMotionConfigDefault(void) {
    return MFRingMotionConfigFromUI((MFRingMotionUIParameters) {
        .sensitivity = 0.10,
        .acceleration = 1.0,
        .adaptiveSmoothnessEndSpeedRatio = 0.125,
        .glide = 0.75,
        .distanceMultiplier = 1.0,
        .attackTimeConstantSeconds = 0.016,
        .releaseTimeConstantSeconds = 0.020,
        .initialVelocityIntervalSeconds = 0.200,
        .startDecaySeconds = 0.080,
        .slowCadenceDurationRatio = 0.75,
        .slowCadenceDurationMaximumSeconds = 0.900,
        .cadenceEstimateAlpha = 0.5,
        .cadenceMemorySeconds = 1.5,
        .maximumSpeedSetting = 0.5,
    });
}

static inline bool MFRingMotionConfigIsValid(const MFRingMotionConfig *config) {
    return config != NULL
        && isfinite(config->referenceSpeedUnitsPerSecond)
        && config->referenceSpeedUnitsPerSecond > 0.0
        && isfinite(config->pixelsPerUnitAtReferenceSpeed)
        && config->pixelsPerUnitAtReferenceSpeed >= 0.0
        && isfinite(config->accelerationGamma)
        && config->accelerationGamma > 0.0
        && isfinite(config->distanceMultiplier)
        && config->distanceMultiplier >= 0.0
        && isfinite(config->initialSpeedUnitsPerSecond)
        && config->initialSpeedUnitsPerSecond > 0.0
        && isfinite(config->speedFloorUnitsPerSecond)
        && config->speedFloorUnitsPerSecond > 0.0
        && isfinite(config->attackTimeConstantSeconds)
        && config->attackTimeConstantSeconds > 0.0
        && isfinite(config->releaseTimeConstantSeconds)
        && config->releaseTimeConstantSeconds > 0.0
        && isfinite(config->startDecaySeconds)
        && config->startDecaySeconds > 0.0
        && isfinite(config->normalDecaySeconds)
        && config->normalDecaySeconds > 0.0
        && isfinite(config->fastDecayMinimumSeconds)
        && config->fastDecayMinimumSeconds > 0.0
        && config->fastDecayMinimumSeconds <= config->normalDecaySeconds
        && isfinite(config->fastDecayStartSpeedUnitsPerSecond)
        && config->fastDecayStartSpeedUnitsPerSecond > 0.0
        && isfinite(config->fastDecayFullSpeedUnitsPerSecond)
        && config->fastDecayFullSpeedUnitsPerSecond
            > config->fastDecayStartSpeedUnitsPerSecond
        && isfinite(config->visibilityWindowSeconds)
        && config->visibilityWindowSeconds > 0.0
        && isfinite(config->minimumVisibleOutputPixels)
        && config->minimumVisibleOutputPixels > 0.0
        && isfinite(config->minimumStoppedOpeningVisibleOutputPixels)
        && config->minimumStoppedOpeningVisibleOutputPixels
            >= config->minimumVisibleOutputPixels
        && isfinite(config->sparseDecayMinimumSeconds)
        && config->sparseDecayMinimumSeconds > 0.0
        && isfinite(config->sparseDecayMaximumSeconds)
        && config->sparseDecayMaximumSeconds >= config->sparseDecayMinimumSeconds
        && isfinite(config->sparseCadenceOverlapRatio)
        && config->sparseCadenceOverlapRatio >= 0.0
        && isfinite(config->sparseBlendEndSpeedUnitsPerSecond)
        && config->sparseBlendEndSpeedUnitsPerSecond > 0.0
        && isfinite(config->cadenceEstimateAlpha)
        && config->cadenceEstimateAlpha >= 0.0
        && config->cadenceEstimateAlpha <= 1.0
        && isfinite(config->cadenceMemorySeconds)
        && config->cadenceMemorySeconds > 0.0
        && isfinite(config->maximumInitialDistancePixels)
        && config->maximumInitialDistancePixels >= 0.0
        && isfinite(config->maximumOutputVelocityPixelsPerSecond)
        && config->maximumOutputVelocityPixelsPerSecond > 0.0
        && isfinite(config->maximumRemainingDistancePixels)
        && config->maximumRemainingDistancePixels >= 0.0;
}

static inline void MFRingMotionInitialize(
    MFRingMotionState *state,
    uint64_t generation
) {
    memset(state, 0, sizeof(*state));
    state->generation = generation;
}

static inline void MFRingMotionReset(
    MFRingMotionState *state,
    uint64_t generation
) {
    MFRingMotionInitialize(state, generation);
}

static inline double MFRingMotionRemainingDistance(
    const MFRingMotionState *state
) {
    return fabs(state->velocityPixelsPerSecond) * state->decaySeconds;
}

static inline double MFRingMotionStopVelocityPixelsPerSecond(void) {
    return 1.0;
}

static inline MFRingMotionUpdate MFRingMotionApplyReport(
    const MFRingMotionConfig *config,
    MFRingMotionState *state,
    MFRingMotionReport report
) {
    MFRingMotionUpdate update = { 0 };
    if (!MFRingMotionConfigIsValid(config)
        || state == NULL
        || !isfinite(report.timestamp)
        || report.signedUnits == 0) {
        update.invalidTimestamp = !isfinite(report.timestamp);
        return update;
    }
    if (report.generation != state->generation) {
        update.staleGeneration = true;
        return update;
    }

    bool isFirstReport = !state->hasAcceptedReport;
    double previousRemainingDistance = isFirstReport
        ? 0.0 : MFRingMotionRemainingDistance(state);
    double interval = NAN;
    if (!isFirstReport) {
        interval = report.timestamp - state->lastAcceptedReportTimestamp;
        if (!isfinite(interval) || interval <= 0.0) {
            update.invalidTimestamp = true;
            return update;
        }
    }

    int inputSign = (report.signedUnits > 0) - (report.signedUnits < 0);
    bool directionChanged = !isFirstReport
        && state->lastInputSign != 0
        && inputSign != state->lastInputSign;
    /// Integer output is visually exhausted once at most one pixel remains,
    /// even if a short decay still represents that area as more than the
    /// renderer's 1 px/s analytic stop velocity. A direction change is also
    /// necessarily a fresh opening in its requested direction: the atomic
    /// reversal below discards every pixel of the old sign, so that discarded
    /// area cannot justify a weaker new-sign response. Requiring the old-sign
    /// area to cross the one-pixel boundary first misclassified captured
    /// sequence 2842 with 1.026 px remaining and a 288 px/s opening.
    bool startsFromStoppedOutput = isFirstReport
        || directionChanged
        || previousRemainingDistance <= config->minimumVisibleOutputPixels;
    double rawSpeed = isFirstReport
        ? config->initialSpeedUnitsPerSecond
        : fabs((double)report.signedUnits) / interval;
    rawSpeed = fmax(config->speedFloorUnitsPerSecond, rawSpeed);

    // Frequency is unsigned activity on this physical axis. A slow reversal
    // changes output direction, but supplies another valid cadence measurement.
    // Do not carry a fast spin's speed through a reversal, or revive stale
    // history after the existing memory horizon. Use the established slow band,
    // bounded by the start of fast friction, rather than another tuning threshold.
    double lowSpeedLimit = fmin(config->sparseBlendEndSpeedUnitsPerSecond,
                               config->fastDecayStartSpeedUnitsPerSecond);
    bool preserveReversalFrequency = directionChanged
        && interval <= config->cadenceMemorySeconds
        && rawSpeed < lowSpeedLimit
        && state->filteredSpeedUnitsPerSecond < lowSpeedLimit;
    bool resetFrequencyForDirection = directionChanged
        && !preserveReversalFrequency;

    double filteredSpeed;
    if (isFirstReport || resetFrequencyForDirection) {
        filteredSpeed = rawSpeed;
    } else {
        double timeConstant = rawSpeed >= state->filteredSpeedUnitsPerSecond
            ? config->attackTimeConstantSeconds
            : config->releaseTimeConstantSeconds;
        double alpha = 1.0 - exp(-interval / timeConstant);
        filteredSpeed = state->filteredSpeedUnitsPerSecond
            + alpha * (rawSpeed - state->filteredSpeedUnitsPerSecond);
    }
    filteredSpeed = fmax(config->speedFloorUnitsPerSecond, filteredSpeed);
    double responseSpeed = rawSpeed >= filteredSpeed ? rawSpeed : filteredSpeed;

    bool hasMeasuredCadence = !isFirstReport
        && !resetFrequencyForDirection
        && interval <= config->cadenceMemorySeconds;
    double cadenceEstimate = state->cadenceEstimateSeconds;
    double cadenceConfidence = 0.0;
    if (hasMeasuredCadence) {
        cadenceEstimate = cadenceEstimate > 0.0
            ? cadenceEstimate
                + config->cadenceEstimateAlpha * (interval - cadenceEstimate)
            : interval;
        cadenceConfidence = MFRingMotionClamp(
            1.0 - (interval / config->cadenceMemorySeconds), 0.0, 1.0);
    } else if (resetFrequencyForDirection || (!isFirstReport
                                   && interval > config->cadenceMemorySeconds)) {
        cadenceEstimate = 0.0;
    }

    double speedRatio = responseSpeed
        / config->referenceSpeedUnitsPerSecond;
    double pixelsPerUnit = config->pixelsPerUnitAtReferenceSpeed
        * pow(fmax(speedRatio, DBL_MIN), config->accelerationGamma - 1.0)
        * config->distanceMultiplier;
    bool initialDistanceLimited = false;
    bool stoppedOpeningDistanceRaised = false;
    if (config->normalDistanceForStoppedOpenings && startsFromStoppedOutput) {
        // A pause is not a measurement of the new gesture's intended speed.
        // Use the same bounded distance as a normal reset opening. The user
        // explicitly prefers this even for indistinguishable hardware rebound.
        double openingSpeed = fmax(config->speedFloorUnitsPerSecond,
                                  config->initialSpeedUnitsPerSecond);
        double openingPixelsPerUnit = config->pixelsPerUnitAtReferenceSpeed
            * pow(openingSpeed / config->referenceSpeedUnitsPerSecond,
                  config->accelerationGamma - 1.0)
            * config->distanceMultiplier;
        openingPixelsPerUnit = fmin(openingPixelsPerUnit,
            config->maximumInitialDistancePixels / fabs((double)report.signedUnits));
        if (pixelsPerUnit < openingPixelsPerUnit) {
            pixelsPerUnit = openingPixelsPerUnit;
            stoppedOpeningDistanceRaised = true;
        }
    }
    if (isFirstReport) {
        double requestedDistance = pixelsPerUnit * fabs((double)report.signedUnits);
        if (requestedDistance > config->maximumInitialDistancePixels) {
            pixelsPerUnit = config->maximumInitialDistancePixels
                / fabs((double)report.signedUnits);
            initialDistanceLimited = true;
        }
    }

    double decay = config->startDecaySeconds;
    if (!isFirstReport) {
        double sparseDecay = hasMeasuredCadence
            ? MFRingMotionClamp(
                cadenceEstimate * config->sparseCadenceOverlapRatio,
                config->sparseDecayMinimumSeconds,
                config->sparseDecayMaximumSeconds)
            : config->normalDecaySeconds;
        double slowBlend = MFRingMotionSmoothstep(
            config->sparseBlendEndSpeedUnitsPerSecond, 0.0, responseSpeed);
        double sparseWeight = slowBlend * cadenceConfidence;
        decay = config->normalDecaySeconds
            + (sparseDecay - config->normalDecaySeconds) * sparseWeight;

        /// A fast physical ring already supplies dense continued input. Reduce
        /// software tail time as speed rises so the explicit velocity ceiling
        /// can be reached without increasing the post-stop area budget.
        double fastBlend = MFRingMotionSmoothstep(
            config->fastDecayStartSpeedUnitsPerSecond,
            config->fastDecayFullSpeedUnitsPerSecond,
            responseSpeed);
        decay += (config->fastDecayMinimumSeconds - decay) * fastBlend;
    }
    decay = fmax(decay, DBL_MIN);

    /// Sparse cadence may ask for a long interpolation tau while acceleration
    /// deliberately makes a very slow one-count impulse small. Bound only the
    /// response time—not its total area—so integer output cannot remain at zero
    /// beyond the two-callback responsiveness gate. Once the prior response is
    /// effectively stopped, require three pixels in that same window. Live
    /// sparse motion keeps the original one-pixel rule and its longer overlap.
    double impulseDistance = pixelsPerUnit * fabs((double)report.signedUnits);
    bool responsivenessDecayLimited = false;
    bool stoppedOpeningResponsivenessDecayLimited = false;
    double minimumResponsiveOutput = startsFromStoppedOutput
        ? config->minimumStoppedOpeningVisibleOutputPixels
        : config->minimumVisibleOutputPixels;
    if (impulseDistance > minimumResponsiveOutput) {
        double maximumResponsiveDecay = -config->visibilityWindowSeconds
            / log1p(-minimumResponsiveOutput / impulseDistance);
        if (decay > maximumResponsiveDecay) {
            decay = maximumResponsiveDecay;
            responsivenessDecayLimited = true;
            stoppedOpeningResponsivenessDecayLimited = startsFromStoppedOutput;
        }
    }

    /// Every visually fresh response should open at least as decisively as the
    /// model's accepted first-report envelope. Cadence-derived distance stays
    /// untouched; only its exponential representation is shortened. This
    /// removes the low-speed threshold discontinuities which repeatedly left
    /// stopped reports near 240–255 px/s while a reset opening began near
    /// 440 px/s in the same physical capture.
    bool stoppedOpeningVelocityDecayLimited = false;
    bool continuityOpeningDecayLimited = false;
    if (!isFirstReport && impulseDistance > 0.0) {
        double initialSpeedRatio = config->initialSpeedUnitsPerSecond
            / config->referenceSpeedUnitsPerSecond;
        double normalOpeningDistancePerUnit =
            config->pixelsPerUnitAtReferenceSpeed
            * pow(fmax(initialSpeedRatio, DBL_MIN),
                  config->accelerationGamma - 1.0)
            * config->distanceMultiplier;
        double minimumOpeningVelocity = normalOpeningDistancePerUnit
            / config->startDecaySeconds;
        if (!startsFromStoppedOutput) {
            /// Continuity is a contribution, not a binary permission to weaken
            /// the next report. Fade the opening envelope by the fraction of
            /// visible retained area in the combined response. At the stopped
            /// boundary this joins the existing impulse-velocity rule exactly;
            /// dominant old motion preserves increasingly more sparse overlap.
            /// Never shorten a response already above the opening envelope.
            double visibleCarry = fmax(0.0, previousRemainingDistance
                - config->minimumVisibleOutputPixels);
            double openingWeight = impulseDistance
                / (impulseDistance + visibleCarry);
            double naturalVelocity = (visibleCarry + impulseDistance)
                / decay;
            minimumOpeningVelocity = naturalVelocity + openingWeight
                * fmax(0.0, minimumOpeningVelocity - naturalVelocity);
        }
        if (minimumOpeningVelocity > 0.0) {
            double responseArea = impulseDistance
                + (startsFromStoppedOutput ? 0.0 : fmax(0.0,
                    previousRemainingDistance - config->minimumVisibleOutputPixels));
            double maximumOpeningDecay = responseArea
                / minimumOpeningVelocity;
            if (decay > maximumOpeningDecay) {
                decay = maximumOpeningDecay;
                responsivenessDecayLimited = true;
                stoppedOpeningResponsivenessDecayLimited = startsFromStoppedOutput;
                stoppedOpeningVelocityDecayLimited = startsFromStoppedOutput;
                continuityOpeningDecayLimited = !startsFromStoppedOutput;
            }
        }
    }

    double velocityBefore = state->velocityPixelsPerSecond;
    double carriedVelocity = 0.0;
    if (directionChanged) {
        state->velocityPixelsPerSecond = 0.0;
    } else if (state->decaySeconds > 0.0) {
        /// Changing tau changes the velocity representation of retained area.
        /// Preserve that area exactly; otherwise adaptive friction silently
        /// creates or deletes distance before the new physical impulse.
        carriedVelocity = state->velocityPixelsPerSecond
            * state->decaySeconds / decay;
        state->velocityPixelsPerSecond = carriedVelocity;
    }
    double impulseVelocity = (double)report.signedUnits * pixelsPerUnit / decay;
    double velocityAfter = state->velocityPixelsPerSecond + impulseVelocity;
    bool velocityLimited = fabs(velocityAfter)
        > config->maximumOutputVelocityPixelsPerSecond;
    if (velocityLimited) {
        velocityAfter = copysign(
            config->maximumOutputVelocityPixelsPerSecond, velocityAfter);
    }

    double uncappedRemaining = fabs(velocityAfter) * decay;
    bool remainingLimited = uncappedRemaining
        > config->maximumRemainingDistancePixels;
    double carryDropped = 0.0;
    if (remainingLimited) {
        carryDropped = uncappedRemaining
            - config->maximumRemainingDistancePixels;
        velocityAfter = copysign(
            config->maximumRemainingDistancePixels / decay, velocityAfter);
    }

    state->hasAcceptedReport = true;
    state->lastAcceptedReportTimestamp = report.timestamp;
    state->lastInputSign = inputSign;
    state->filteredSpeedUnitsPerSecond = filteredSpeed;
    state->cadenceEstimateSeconds = cadenceEstimate;
    state->cadenceConfidence = cadenceConfidence;
    state->velocityPixelsPerSecond = velocityAfter;
    state->decaySeconds = decay;

    update.accepted = true;
    update.directionChanged = directionChanged;
    update.lowSpeedReversalFrequencyPreserved = preserveReversalFrequency;
    update.hasMeasuredCadence = hasMeasuredCadence;
    update.initialDistanceLimited = initialDistanceLimited;
    update.velocityLimited = velocityLimited;
    update.remainingDistanceLimited = remainingLimited;
    update.responsivenessDecayLimited = responsivenessDecayLimited;
    update.startsFromStoppedOutput = startsFromStoppedOutput;
    update.stoppedOpeningResponsivenessDecayLimited =
        stoppedOpeningResponsivenessDecayLimited;
    update.stoppedOpeningVelocityDecayLimited =
        stoppedOpeningVelocityDecayLimited;
    update.continuityOpeningDecayLimited = continuityOpeningDecayLimited;
    update.stoppedOpeningDistanceRaised = stoppedOpeningDistanceRaised;
    update.reportIntervalSeconds = interval;
    update.rawSpeedUnitsPerSecond = rawSpeed;
    update.filteredSpeedUnitsPerSecond = filteredSpeed;
    update.cadenceEstimateSeconds = cadenceEstimate;
    update.cadenceConfidence = cadenceConfidence;
    update.pixelsPerUnit = pixelsPerUnit;
    update.decaySeconds = decay;
    update.velocityBeforePixelsPerSecond = velocityBefore;
    update.carriedVelocityPixelsPerSecond = carriedVelocity;
    update.impulseVelocityPixelsPerSecond = impulseVelocity;
    update.velocityAfterPixelsPerSecond = velocityAfter;
    update.remainingDistancePixels = fabs(velocityAfter) * decay;
    update.carryDroppedPixels = carryDropped;
    return update;
}

/// Analytically integrates the exponential velocity over a real frame interval.
/// No frame-rate-specific approximation or target-distance reservoir is used.
static inline MFRingMotionFrame MFRingMotionAdvance(
    MFRingMotionState *state,
    double intervalSeconds
) {
    MFRingMotionFrame frame = { 0 };
    if (state == NULL
        || !isfinite(intervalSeconds)
        || intervalSeconds <= 0.0
        || !isfinite(state->decaySeconds)
        || state->decaySeconds <= 0.0
        || !isfinite(state->velocityPixelsPerSecond)) {
        frame.invalidInterval = true;
        return frame;
    }

    double decayFactor = exp(-intervalSeconds / state->decaySeconds);
    frame.distancePixels = state->velocityPixelsPerSecond
        * state->decaySeconds * (1.0 - decayFactor);
    state->velocityPixelsPerSecond *= decayFactor;
    frame.accepted = true;
    frame.velocityAfterPixelsPerSecond = state->velocityPixelsPerSecond;
    frame.remainingDistancePixels = MFRingMotionRemainingDistance(state);
    return frame;
}

#endif /* RingMotionModel_h */
