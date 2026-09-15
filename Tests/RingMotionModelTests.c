//
// --------------------------------------------------------------------------
// RingMotionModelTests.c
// Deterministic and property checks for the pure ring motion core.
// --------------------------------------------------------------------------
//

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "../Helper/Core/Scroll/RingMotionPlane.h"

static MFRingMotionReport report(uint64_t generation, double time, int64_t units) {
    return (MFRingMotionReport) {
        .generation = generation,
        .timestamp = time,
        .signedUnits = units,
    };
}

static void assertFiniteAndBounded(
    const MFRingMotionConfig *config,
    const MFRingMotionState *state
) {
    assert(isfinite(state->velocityPixelsPerSecond));
    assert(isfinite(state->decaySeconds));
    assert(fabs(state->velocityPixelsPerSecond)
           <= config->maximumOutputVelocityPixelsPerSecond + 1e-9);
    assert(MFRingMotionRemainingDistance(state)
           <= config->maximumRemainingDistancePixels + 1e-9);
}

static void testFirstReportIsImmediateNormalAndBounded(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);

    MFRingMotionUpdate update = MFRingMotionApplyReport(
        &config, &state, report(1, 1000.0, 1));
    assert(update.accepted);
    assert(!update.hasMeasuredCadence);
    assert(update.decaySeconds == config.startDecaySeconds);
    assert(update.remainingDistancePixels > 0.0);
    assert(update.remainingDistancePixels <= config.maximumInitialDistancePixels);

    MFRingMotionFrame firstFrame = MFRingMotionAdvance(&state, 1.0 / 120.0);
    assert(firstFrame.accepted);
    assert(firstFrame.distancePixels > 0.0);
}

static void testCurrentUIParameterMapping(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    assert(fabs(config.referenceSpeedUnitsPerSecond - 5.0) < 1e-12);
    assert(fabs(config.pixelsPerUnitAtReferenceSpeed - 20.0) < 1e-12);
    assert(fabs(config.accelerationGamma - 2.0) < 1e-12);
    assert(fabs(config.normalDecaySeconds - (1.0 / 13.75)) < 1e-12);
    assert(fabs(config.fastDecayMinimumSeconds - 0.035) < 1e-12);
    assert(fabs(config.fastDecayStartSpeedUnitsPerSecond - 20.0) < 1e-12);
    assert(fabs(config.fastDecayFullSpeedUnitsPerSecond - 50.0) < 1e-12);
    assert(fabs(config.visibilityWindowSeconds - (2.0 / 144.0)) < 1e-12);
    assert(fabs(config.minimumVisibleOutputPixels - 1.0) < 1e-12);
    assert(fabs(config.minimumStoppedOpeningVisibleOutputPixels - 3.0) < 1e-12);
    assert(fabs(config.sparseDecayMaximumSeconds - 0.675) < 1e-12);
    assert(fabs(config.maximumInitialDistancePixels - 300.0) < 1e-12);
    assert(fabs(config.maximumOutputVelocityPixelsPerSecond - 15000.0) < 1e-9);
    assert(fabs(config.maximumRemainingDistancePixels - 525.0) < 1e-9);
    assert(config.sparseBlendEndSpeedUnitsPerSecond > config.referenceSpeedUnitsPerSecond);
    assert(MFRingMotionConfigIsValid(&config));
}

static void testSecondSparseReportEstablishesOverlapImmediately(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    assert(MFRingMotionApplyReport(
        &config, &state, report(1, 0.0, 1)).accepted);

    MFRingMotionUpdate second = MFRingMotionApplyReport(
        &config, &state, report(1, 0.300, 1));
    assert(second.accepted);
    assert(second.hasMeasuredCadence);
    assert(!second.startsFromStoppedOutput);
    assert(!second.stoppedOpeningResponsivenessDecayLimited);
    assert(!second.stoppedOpeningVelocityDecayLimited);
    assert(fabs(second.cadenceEstimateSeconds - 0.300) < 1e-12);
    assert(second.decaySeconds > config.normalDecaySeconds);
}

static void testLowSpeedFrequencyIgnoresDirection(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState steady, alternating;
    MFRingMotionInitialize(&steady, 1);
    MFRingMotionInitialize(&alternating, 1);
    const double times[] = { 0.0, 0.2, 0.5, 0.75, 0.9, 1.2 };
    for (unsigned i = 0; i < sizeof(times) / sizeof(times[0]); ++i) {
        if (i > 0) {
            MFRingMotionAdvance(&steady, times[i] - times[i - 1]);
            MFRingMotionAdvance(&alternating, times[i] - times[i - 1]);
        }
        int sign = i % 2 == 0 ? 1 : -1;
        MFRingMotionUpdate a = MFRingMotionApplyReport(
            &config, &steady, report(1, times[i], 1));
        MFRingMotionUpdate b = MFRingMotionApplyReport(
            &config, &alternating, report(1, times[i], sign));
        assert(a.accepted && b.accepted);
        assert(b.lowSpeedReversalFrequencyPreserved == (i > 0));
        assert(b.hasMeasuredCadence == (i > 0));
        assert(a.rawSpeedUnitsPerSecond == b.rawSpeedUnitsPerSecond);
        assert(a.filteredSpeedUnitsPerSecond == b.filteredSpeedUnitsPerSecond);
        assert(a.cadenceEstimateSeconds == b.cadenceEstimateSeconds);
        assert(a.cadenceConfidence == b.cadenceConfidence);
        assert(b.carriedVelocityPixelsPerSecond == 0.0);
        assert(b.velocityAfterPixelsPerSecond * sign > 0.0);
        // Keeping cadence must not restore the old weak reversed opening.
        assert(fabs(b.impulseVelocityPixelsPerSecond)
               >= config.pixelsPerUnitAtReferenceSpeed / config.startDecaySeconds - 1e-9);
        MFRingMotionState preview = alternating;
        assert(MFRingMotionAdvance(&preview, 1.0 / 144.0).distancePixels * sign > 0.0);
        assertFiniteAndBounded(&config, &alternating);
    }
}

static void testReversalFrequencyDoesNotRetainFastOrStaleHistory(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    double limit = fmin(config.sparseBlendEndSpeedUnitsPerSecond,
                       config.fastDecayStartSpeedUnitsPerSecond);
    // Below the boundary retains frequency; either speed at/above it does not.
    const double previousSpeeds[] = { 5.0, limit, 50.0, 5.0, 5.0 };
    const double currentSpeeds[] = { 5.0, 5.0, 5.0, limit, 50.0 };
    for (unsigned i = 0; i < 5; ++i) {
        MFRingMotionState state;
        MFRingMotionInitialize(&state, 1);
        MFRingMotionApplyReport(&config, &state, report(1, 0.0, 1));
        state.filteredSpeedUnitsPerSecond = previousSpeeds[i];
        state.cadenceEstimateSeconds = 0.25;
        MFRingMotionUpdate update = MFRingMotionApplyReport(
            &config, &state, report(1, 1.0 / currentSpeeds[i], -1));
        assert(update.accepted && update.directionChanged);
        assert(update.lowSpeedReversalFrequencyPreserved == (i == 0));
        assert(update.carriedVelocityPixelsPerSecond == 0.0);
        if (i != 0) {
            assert(update.filteredSpeedUnitsPerSecond == update.rawSpeedUnitsPerSecond);
            assert(!update.hasMeasuredCadence);
            assert(update.cadenceEstimateSeconds == 0.0);
        }
    }
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    MFRingMotionApplyReport(&config, &state, report(1, 0.0, 1));
    MFRingMotionApplyReport(&config, &state, report(1, 0.2, -1));
    MFRingMotionUpdate stale = MFRingMotionApplyReport(
        &config, &state, report(1, 0.2 + config.cadenceMemorySeconds + 0.01, 1));
    assert(stale.accepted && !stale.lowSpeedReversalFrequencyPreserved);
    assert(!stale.hasMeasuredCadence && stale.cadenceEstimateSeconds == 0.0);
    MFRingMotionReset(&state, 2);
    MFRingMotionUpdate fresh = MFRingMotionApplyReport(
        &config, &state, report(2, 10.0, -1));
    assert(fresh.accepted && !fresh.lowSpeedReversalFrequencyPreserved);
    assert(!fresh.hasMeasuredCadence);
    assert(fresh.decaySeconds == config.startDecaySeconds);
}

static void testCapturedStoppedSparseOpeningRaisesRateWithoutAddingDistance(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.normalDistanceForStoppedOpenings = false; // Historical timing-only policy.
    /// Match the response scale in captured sequence 2020. The behavior under
    /// test is independent of the user's sensitivity value.
    config.pixelsPerUnitAtReferenceSpeed = 39.36;

    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    state.hasAcceptedReport = true;
    state.lastAcceptedReportTimestamp = 0.0;
    state.lastInputSign = 1;
    state.filteredSpeedUnitsPerSecond = 3.311;
    state.cadenceEstimateSeconds = 0.178509;
    state.cadenceConfidence = 0.799;
    state.velocityPixelsPerSecond = 0.982;
    state.decaySeconds = 0.118568;

    double retainedBefore = MFRingMotionRemainingDistance(&state);
    MFRingMotionUpdate opening = MFRingMotionApplyReport(
        &config, &state, report(1, 0.694026, 1));
    assert(opening.accepted);
    assert(opening.startsFromStoppedOutput);
    assert(opening.responsivenessDecayLimited);
    assert(opening.stoppedOpeningResponsivenessDecayLimited);
    assert(opening.decaySeconds < config.normalDecaySeconds);
    assert(fabs(opening.remainingDistancePixels
                - (retainedBefore + opening.pixelsPerUnit)) < 1e-9);
    assert(opening.carryDroppedPixels == 0.0);

    MFRingMotionFrame openingWindow = MFRingMotionAdvance(
        &state, config.visibilityWindowSeconds);
    assert(openingWindow.accepted);
    assert(fabs(openingWindow.distancePixels)
           >= config.minimumStoppedOpeningVisibleOutputPixels - 1e-9);
}

static void testCapturedNearlyExhaustedTailCountsAsStoppedOutput(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.normalDistanceForStoppedOpenings = false;
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);

    /// Match the pre-report shape of captured sequence 4766: less than one
    /// pixel remained, but its short tau still represented that invisible
    /// area as 8.831 px/s and defeated the former velocity conjunction.
    state.hasAcceptedReport = true;
    state.lastAcceptedReportTimestamp = 0.0;
    state.lastInputSign = 1;
    state.filteredSpeedUnitsPerSecond = 15.518;
    state.cadenceEstimateSeconds = 0.059249;
    state.velocityPixelsPerSecond = 8.831;
    state.decaySeconds = 0.073349;
    assert(MFRingMotionRemainingDistance(&state)
           < config.minimumVisibleOutputPixels);
    assert(fabs(state.velocityPixelsPerSecond)
           > MFRingMotionStopVelocityPixelsPerSecond());

    double retainedBefore = MFRingMotionRemainingDistance(&state);
    MFRingMotionUpdate opening = MFRingMotionApplyReport(
        &config, &state, report(1, 0.411004, 1));
    assert(opening.accepted);
    assert(opening.startsFromStoppedOutput);
    assert(opening.responsivenessDecayLimited);
    assert(opening.stoppedOpeningResponsivenessDecayLimited);
    assert(fabs(opening.remainingDistancePixels
                - (retainedBefore + opening.pixelsPerUnit)) < 1e-9);
    assert(opening.carryDroppedPixels == 0.0);

    MFRingMotionFrame openingWindow = MFRingMotionAdvance(
        &state, config.visibilityWindowSeconds);
    assert(openingWindow.accepted);
    assert(openingWindow.distancePixels
           >= config.minimumStoppedOpeningVisibleOutputPixels - 1e-9);
}

static void testCapturedThreePixelStoppedOpeningGetsDecisiveRate(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.normalDistanceForStoppedOpenings = false;
    /// At the default quadratic mapping, this produces the captured 8.142 px
    /// distance for a one-unit report at the raw 1 report/s floor.
    config.pixelsPerUnitAtReferenceSpeed = 40.71;

    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    state.hasAcceptedReport = true;
    state.lastAcceptedReportTimestamp = 0.0;
    state.lastInputSign = 1;
    state.filteredSpeedUnitsPerSecond = 13.003;
    state.velocityPixelsPerSecond = 0.987;
    state.decaySeconds = 0.074634;

    MFRingMotionUpdate opening = MFRingMotionApplyReport(
        &config, &state, report(1, 4.800065, -1));
    assert(opening.accepted);
    assert(opening.directionChanged);
    assert(opening.startsFromStoppedOutput);
    assert(opening.stoppedOpeningResponsivenessDecayLimited);
    assert(opening.stoppedOpeningVelocityDecayLimited);
    assert(fabs(opening.pixelsPerUnit - 8.142) < 1e-9);
    assert(opening.decaySeconds < 0.031);
    assert(fabs(opening.remainingDistancePixels - 8.142) < 1e-9);
    assert(opening.carryDroppedPixels == 0.0);

    MFRingMotionFrame openingWindow = MFRingMotionAdvance(
        &state, config.visibilityWindowSeconds);
    assert(openingWindow.accepted);
    assert(fabs(openingWindow.distancePixels)
           >= config.minimumStoppedOpeningVisibleOutputPixels - 1e-9);
}

static void testCapturedStoppedOpeningMatchesNormalOpeningVelocity(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.normalDistanceForStoppedOpenings = false;
    /// Match recent sequence 1329. Its 17.719 px stopped reversal naturally
    /// crossed the old three-pixel visibility threshold, yet opened near
    /// 250 px/s versus 439 px/s for a reset opening at the same UI settings.
    config.pixelsPerUnitAtReferenceSpeed = 35.153;
    config.accelerationGamma = 1.908799647984;

    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    state.hasAcceptedReport = true;
    state.lastAcceptedReportTimestamp = 0.0;
    state.lastInputSign = -1;
    state.filteredSpeedUnitsPerSecond = 16.390;
    state.velocityPixelsPerSecond = -9.330;
    state.decaySeconds = 0.070885;
    assert(MFRingMotionRemainingDistance(&state)
           < config.minimumVisibleOutputPixels);

    double oldVisibilityWindowOutput = 17.719
        * (1.0 - exp(-config.visibilityWindowSeconds
                     / config.normalDecaySeconds));
    assert(oldVisibilityWindowOutput
           >= config.minimumStoppedOpeningVisibleOutputPixels);

    MFRingMotionUpdate opening = MFRingMotionApplyReport(
        &config, &state, report(1, 0.425021, 1));
    double normalOpeningVelocity = config.pixelsPerUnitAtReferenceSpeed
        / config.startDecaySeconds;

    assert(opening.accepted);
    assert(opening.directionChanged);
    assert(opening.startsFromStoppedOutput);
    assert(opening.stoppedOpeningResponsivenessDecayLimited);
    assert(opening.stoppedOpeningVelocityDecayLimited);
    assert(fabs(opening.pixelsPerUnit - 17.719) < 0.001);
    assert(fabs(opening.remainingDistancePixels
                - opening.pixelsPerUnit) < 1e-9);
    assert(fabs(opening.impulseVelocityPixelsPerSecond
                - normalOpeningVelocity) < 1e-9);
    assert(opening.decaySeconds < config.normalDecaySeconds);
    assert(opening.carryDroppedPixels == 0.0);

    MFRingMotionFrame openingWindow = MFRingMotionAdvance(
        &state, config.visibilityWindowSeconds);
    assert(openingWindow.accepted);
    assert(openingWindow.distancePixels
           >= config.minimumStoppedOpeningVisibleOutputPixels - 1e-9);
}

static void testCapturedReversalTreatsDiscardedOldAreaAsStoppedOutput(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.normalDistanceForStoppedOpenings = false;
    /// Match sequence 2842: the old-sign response still represented just over
    /// one pixel, but reversal discarded it atomically and opened the new sign
    /// at only 287.8 px/s before this direction-aware invariant.
    config.pixelsPerUnitAtReferenceSpeed = 35.153;
    config.accelerationGamma = 1.908799647984;

    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    state.hasAcceptedReport = true;
    state.lastAcceptedReportTimestamp = 0.0;
    state.lastInputSign = -1;
    state.filteredSpeedUnitsPerSecond = 4.651;
    state.velocityPixelsPerSecond = -10.720;
    state.decaySeconds = 0.095680;
    assert(MFRingMotionRemainingDistance(&state)
           > config.minimumVisibleOutputPixels);

    MFRingMotionUpdate opening = MFRingMotionApplyReport(
        &config, &state, report(1, 0.363983, 1));
    double normalOpeningVelocity = config.pixelsPerUnitAtReferenceSpeed
        / config.startDecaySeconds;

    assert(opening.accepted);
    assert(opening.directionChanged);
    assert(opening.startsFromStoppedOutput);
    assert(opening.stoppedOpeningResponsivenessDecayLimited);
    assert(opening.stoppedOpeningVelocityDecayLimited);
    assert(fabs(opening.pixelsPerUnit - 20.400) < 0.001);
    assert(opening.carriedVelocityPixelsPerSecond == 0.0);
    assert(fabs(opening.remainingDistancePixels
                - opening.pixelsPerUnit) < 1e-9);
    assert(fabs(opening.impulseVelocityPixelsPerSecond
                - normalOpeningVelocity) < 1e-9);
    assert(opening.carryDroppedPixels == 0.0);
}

static void testCapturedWeakContinuityAndBoundarySweep(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.normalDistanceForStoppedOpenings = false;
    config.pixelsPerUnitAtReferenceSpeed = 35.153;
    config.accelerationGamma = 1.908799647984;
    config.normalDecaySeconds = 0.070885;
    double previousDecay = 0.0;
    for (int i = 0; i <= 10000; i++) {
        // Sweep through the former one-pixel cliff and well into live overlap.
        double area = i * 0.001;
        MFRingMotionState state;
        MFRingMotionInitialize(&state, 1);
        state.hasAcceptedReport = true;
        state.lastInputSign = -1;
        state.filteredSpeedUnitsPerSecond = 3.876;
        state.cadenceEstimateSeconds = 0.164270;
        state.decaySeconds = 0.111155;
        state.velocityPixelsPerSecond = -area / state.decaySeconds;
        MFRingMotionUpdate update = MFRingMotionApplyReport(
            &config, &state, report(1, 0.340009, -1));
        assert(update.accepted && !update.directionChanged);
        assert(fabs(update.pixelsPerUnit - 21.703) < 0.001);
        assert(fabs(update.remainingDistancePixels
                    - area - update.pixelsPerUnit) < 1e-9);
        assert(update.carryDroppedPixels == 0.0);
        // More retained continuity may smoothly lengthen the response, but
        // crossing one pixel must not suddenly restore maximum sparse decay.
        if (i > 0) {
            assert(update.decaySeconds >= previousDecay - 1e-12);
            assert(update.decaySeconds - previousDecay < 0.00002);
        }
        previousDecay = update.decaySeconds;
        if (i == 1513) {
            assert(update.continuityOpeningDecayLimited);
            assert(!update.startsFromStoppedOutput);
            assert(fabs(update.velocityAfterPixelsPerSecond) > 430.0);
            assert(update.decaySeconds < 0.055);
            printf("Captured 1878: distance=%.3f retained=%.3f tauMs=%.3f velocity=%.3f\n",
                   update.pixelsPerUnit, area, update.decaySeconds * 1000.0,
                   fabs(update.velocityAfterPixelsPerSecond));
        }
    }
}

static void testSparseImpulseCrossesOnePixelWithinTwoFastCallbacks(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    assert(MFRingMotionApplyReport(
        &config, &state, report(1, 0.0, 1)).accepted);
    assert(MFRingMotionAdvance(&state, 0.928).accepted);

    MFRingMotionUpdate sparse = MFRingMotionApplyReport(
        &config, &state, report(1, 0.928, 1));
    assert(sparse.accepted);
    assert(sparse.responsivenessDecayLimited);
    MFRingMotionFrame firstTwoCallbacks = MFRingMotionAdvance(
        &state, config.visibilityWindowSeconds);
    assert(firstTwoCallbacks.accepted);
    assert(firstTwoCallbacks.distancePixels
           >= config.minimumVisibleOutputPixels - 1e-9);
}

static void testAccelerationUsesCurrentReport(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    assert(MFRingMotionApplyReport(
        &config, &state, report(1, 0.0, 1)).accepted);
    MFRingMotionUpdate slow = MFRingMotionApplyReport(
        &config, &state, report(1, 0.300, 1));
    MFRingMotionUpdate fast = MFRingMotionApplyReport(
        &config, &state, report(1, 0.310, 3));
    assert(fabs(fast.rawSpeedUnitsPerSecond - 300.0) < 1e-9);
    assert(fast.pixelsPerUnit > slow.pixelsPerUnit);
    assert(fast.decaySeconds <= slow.decaySeconds);
}

static void testSameDirectionAddsAndReversalCancels(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 7);
    MFRingMotionUpdate first = MFRingMotionApplyReport(
        &config, &state, report(7, 0.0, 1));
    MFRingMotionUpdate same = MFRingMotionApplyReport(
        &config, &state, report(7, 0.020, 1));
    assert(same.velocityBeforePixelsPerSecond
           == first.velocityAfterPixelsPerSecond);
    assert(same.velocityAfterPixelsPerSecond
           > same.velocityBeforePixelsPerSecond);

    MFRingMotionUpdate reverse = MFRingMotionApplyReport(
        &config, &state, report(7, 0.040, -1));
    assert(reverse.accepted);
    assert(reverse.directionChanged);
    assert(reverse.velocityBeforePixelsPerSecond > 0.0);
    assert(reverse.velocityAfterPixelsPerSecond < 0.0);
}

static void testIndependentPhysicalAxesShareOneFrameClock(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionPlane plane;
    MFRingMotionPlaneInitialize(&plane, 9);

    MFRingMotionUpdate vertical = MFRingMotionPlaneApplyReport(
        &config, &plane, kMFRingAxisVertical, report(9, 1.000, 1));
    assert(vertical.accepted);
    assert(plane.vertical.velocityPixelsPerSecond > 0.0);
    assert(!plane.horizontal.hasAcceptedReport);

    MFRingMotionUpdate horizontal = MFRingMotionPlaneApplyReport(
        &config, &plane, kMFRingAxisHorizontal, report(9, 1.020, -1));
    assert(horizontal.accepted);
    assert(plane.vertical.velocityPixelsPerSecond
           == vertical.velocityAfterPixelsPerSecond);
    assert(plane.horizontal.velocityPixelsPerSecond < 0.0);

    MFRingMotionPlaneFrame frame = MFRingMotionPlaneAdvance(
        &plane, 1.0 / 120.0);
    assert(frame.accepted);
    assert(frame.vertical.distancePixels > 0.0);
    assert(frame.horizontal.distancePixels < 0.0);

    MFRingMotionState horizontalBeforeTrailingVertical = plane.horizontal;
    MFRingMotionUpdate trailingVertical = MFRingMotionPlaneApplyReport(
        &config, &plane, kMFRingAxisVertical, report(9, 1.040, 1));
    assert(trailingVertical.accepted);
    assert(trailingVertical.hasMeasuredCadence);
    assert(plane.horizontal.lastAcceptedReportTimestamp
           == horizontalBeforeTrailingVertical.lastAcceptedReportTimestamp);
    assert(plane.horizontal.velocityPixelsPerSecond
           == horizontalBeforeTrailingVertical.velocityPixelsPerSecond);

    MFRingMotionState horizontalBeforeVerticalReversal = plane.horizontal;
    MFRingMotionUpdate verticalReversal = MFRingMotionPlaneApplyReport(
        &config, &plane, kMFRingAxisVertical, report(9, 1.060, -1));
    assert(verticalReversal.accepted);
    assert(verticalReversal.directionChanged);
    assert(plane.vertical.velocityPixelsPerSecond < 0.0);
    assert(plane.horizontal.velocityPixelsPerSecond
           == horizontalBeforeVerticalReversal.velocityPixelsPerSecond);

    MFRingMotionPlaneReset(&plane, 10);
    assert(plane.generation == 10);
    assert(!plane.vertical.hasAcceptedReport);
    assert(!plane.horizontal.hasAcceptedReport);
    assert(MFRingMotionPlaneRemainingDistance(&plane) == 0.0);
    MFRingMotionUpdate stale = MFRingMotionPlaneApplyReport(
        &config, &plane, kMFRingAxisHorizontal, report(9, 2.000, 1));
    assert(!stale.accepted);
    assert(stale.staleGeneration);
}

static double integratedResponseAtHz(double refreshHz) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    MFRingMotionUpdate update = MFRingMotionApplyReport(
        &config, &state, report(1, 0.0, 1));
    assert(update.accepted);
    double total = 0.0;
    double frameInterval = 1.0 / refreshHz;
    for (int frame = 0; frame < (int)(refreshHz * 2.0); frame++) {
        total += MFRingMotionAdvance(&state, frameInterval).distancePixels;
    }
    return total + copysign(MFRingMotionRemainingDistance(&state),
                            state.velocityPixelsPerSecond);
}

static void testExactIntegrationIsRefreshIndependent(void) {
    double at60 = integratedResponseAtHz(60.0);
    double at120 = integratedResponseAtHz(120.0);
    double at144 = integratedResponseAtHz(144.0);
    assert(fabs(at60 - at120) < 1e-9);
    assert(fabs(at120 - at144) < 1e-9);
}

static void testVariableRefreshIntegrationIsEquivalent(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    MFRingMotionUpdate update = MFRingMotionApplyReport(
        &config, &state, report(1, 0.0, 1));
    assert(update.accepted);

    const double intervals[] = { 1.0 / 60.0, 1.0 / 144.0, 1.0 / 90.0 };
    double elapsed = 0.0;
    double total = 0.0;
    size_t index = 0;
    while (elapsed < 2.0) {
        double interval = intervals[index % 3];
        if (elapsed + interval > 2.0) interval = 2.0 - elapsed;
        total += MFRingMotionAdvance(&state, interval).distancePixels;
        elapsed += interval;
        index += 1;
    }
    total += copysign(MFRingMotionRemainingDistance(&state),
                      state.velocityPixelsPerSecond);
    assert(fabs(total - integratedResponseAtHz(120.0)) < 1e-9);
}

static double packetizedResponse(bool aggregated) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.accelerationGamma = 1.0;
    config.startDecaySeconds = 0.080;
    config.normalDecaySeconds = 0.080;
    config.sparseDecayMinimumSeconds = 0.080;
    config.sparseDecayMaximumSeconds = 0.080;
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    double total = 0.0;

    if (aggregated) {
        assert(MFRingMotionApplyReport(
            &config, &state, report(1, 0.0, 3)).accepted);
    } else {
        assert(MFRingMotionApplyReport(
            &config, &state, report(1, 0.0, 1)).accepted);
        total += MFRingMotionAdvance(&state, 0.010).distancePixels;
        assert(MFRingMotionApplyReport(
            &config, &state, report(1, 0.010, 1)).accepted);
        total += MFRingMotionAdvance(&state, 0.010).distancePixels;
        assert(MFRingMotionApplyReport(
            &config, &state, report(1, 0.020, 1)).accepted);
    }
    total += copysign(MFRingMotionRemainingDistance(&state),
                      state.velocityPixelsPerSecond);
    return total;
}

static void testLinearTransferIsPacketizationIndependent(void) {
    assert(fabs(packetizedResponse(true) - packetizedResponse(false)) < 1e-9);
}

static void testIndependentCapsAndResetGeneration(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    /// This test isolates the three distance/velocity caps. Give its synthetic
    /// four-pixel opening a wide visibility window so responsiveness does not
    /// intentionally shorten decay before the remaining-area assertion.
    config.visibilityWindowSeconds = 1.0;
    config.maximumInitialDistancePixels = 4.0;
    config.maximumOutputVelocityPixelsPerSecond = 25.0;
    config.maximumRemainingDistancePixels = 1.0;
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 10);

    MFRingMotionUpdate update = MFRingMotionApplyReport(
        &config, &state, report(10, 0.0, INT64_C(1000000)));
    assert(update.accepted);
    assert(update.initialDistanceLimited);
    assert(update.velocityLimited);
    assert(update.remainingDistanceLimited);
    assertFiniteAndBounded(&config, &state);

    MFRingMotionReset(&state, 11);
    assert(state.velocityPixelsPerSecond == 0.0);
    assert(state.cadenceEstimateSeconds == 0.0);
    assert(state.lastInputSign == 0);
    MFRingMotionUpdate stale = MFRingMotionApplyReport(
        &config, &state, report(10, 1.0, 1));
    assert(!stale.accepted);
    assert(stale.staleGeneration);
}

static void testInvalidTimeAndLongFrameAreBounded(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    assert(MFRingMotionApplyReport(
        &config, &state, report(1, 5.0, 1)).accepted);
    MFRingMotionUpdate backwards = MFRingMotionApplyReport(
        &config, &state, report(1, 4.0, 1));
    assert(!backwards.accepted);
    assert(backwards.invalidTimestamp);

    double before = MFRingMotionRemainingDistance(&state);
    MFRingMotionFrame parked = MFRingMotionAdvance(&state, 10.0);
    assert(parked.accepted);
    assert(fabs(parked.distancePixels) <= before + 1e-9);
    assert(parked.remainingDistancePixels <= before + 1e-9);
}

static uint64_t randomState = UINT64_C(0x4d4652494e475445);

static uint32_t nextRandom(void) {
    randomState = randomState * UINT64_C(6364136223846793005) + 1;
    return (uint32_t)(randomState >> 32);
}

static void testRandomSequencesRemainFiniteAndBounded(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    MFRingMotionState state;
    MFRingMotionInitialize(&state, 1);
    double timestamp = 0.0;

    for (int iteration = 0; iteration < 20000; iteration++) {
        timestamp += 0.001 + (double)(nextRandom() % 1500) / 1000.0;
        int64_t units = (int64_t)(1 + nextRandom() % 127);
        if ((nextRandom() & 1U) != 0) units = -units;
        MFRingMotionUpdate update = MFRingMotionApplyReport(
            &config, &state, report(1, timestamp, units));
        assert(update.accepted);
        assertFiniteAndBounded(&config, &state);
        assert((state.velocityPixelsPerSecond > 0.0) == (units > 0));

        double frameInterval = 0.001
            + (double)(nextRandom() % 100) / 1000.0;
        MFRingMotionFrame frame = MFRingMotionAdvance(&state, frameInterval);
        assert(frame.accepted);
        assert(isfinite(frame.distancePixels));
        assertFiniteAndBounded(&config, &state);
    }
}

static void testNormalDistanceForResumedOpenings(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.pixelsPerUnitAtReferenceSpeed = 35.153;
    config.accelerationGamma = 1.908799647984;
    assert(config.normalDistanceForStoppedOpenings);
    for (int sign = -1; sign <= 1; sign += 2) {
        MFRingMotionState state;
        MFRingMotionInitialize(&state, 1);
        MFRingMotionUpdate first = MFRingMotionApplyReport(
            &config, &state, report(1, 0, 1));
        MFRingMotionAdvance(&state, 70.749617);
        MFRingMotionState baseline = state;
        MFRingMotionConfig oldConfig = config;
        oldConfig.normalDistanceForStoppedOpenings = false;
        MFRingMotionUpdate old = MFRingMotionApplyReport(
            &oldConfig, &baseline, report(1, 70.749617, sign));
        MFRingMotionUpdate resumed = MFRingMotionApplyReport(
            &config, &state, report(1, 70.749617, sign));
        assert(fabs(old.pixelsPerUnit - 8.142) < 0.001);
        assert(resumed.stoppedOpeningDistanceRaised);
        assert(fabs(resumed.pixelsPerUnit - first.pixelsPerUnit) < 1e-9);
        assert(resumed.rawSpeedUnitsPerSecond == old.rawSpeedUnitsPerSecond);
        assert(resumed.filteredSpeedUnitsPerSecond == old.filteredSpeedUnitsPerSecond);
        assert(resumed.carryDroppedPixels == 0);
        assert((resumed.velocityAfterPixelsPerSecond > 0) == (sign > 0));
        MFRingMotionAdvance(&state, 0.034968);
        MFRingMotionUpdate fast = MFRingMotionApplyReport(
            &config, &state, report(1, 70.784585, sign));
        assert(!fast.stoppedOpeningDistanceRaised);
        assert(fast.pixelsPerUnit > resumed.pixelsPerUnit);
        assertFiniteAndBounded(&config, &state);
    }
}

static void testCapturedCGFallbackCannotPoisonRawMotion(void) {
    MFRingMotionConfig config = MFRingMotionConfigDefault();
    config.pixelsPerUnitAtReferenceSpeed = 35.153;
    config.accelerationGamma = 1.908799647984;
    config.attackTimeConstantSeconds = -0.028013
        / log((107.095 - 95.284) / (107.095 - 27.966));
    for (int axis = kMFRingAxisVertical; axis <= kMFRingAxisHorizontal; axis++) {
        for (int sign = -1; sign <= 1; sign += 2) {
            MFRingMotionPlane plane;
            MFRingMotionPlaneInitialize(&plane, 1570);
            MFRingMotionState *state = MFRingMotionPlaneStateForAxis(&plane, axis);
            // Sequence 3847's captured filter and next packet interval.
            MFRingMotionPlaneApplyReport(&config, &plane, axis,
                report(1570, 100.0, sign));
            state->filteredSpeedUnitsPerSecond = 27.966;
            MFRingInputBuffer buffer;
            MFRingInputBufferInitialize(&buffer);
            MFRingCorrelationResult miss = MFRingInputBufferCorrelate(
                &buffer, 100.028013, 42, axis, sign * 3, sign * 3, 0.030, 0.002);
            assert(!MFRingCorrelationHasRawMotionUnits(miss));
            assert(miss.signedUnits == sign * 3); // Legacy gets the full report.
            MFRingMotionState poisoned = *state;
            MFRingMotionUpdate old = MFRingMotionApplyReport(&config, &poisoned,
                report(1570, 100.028013, miss.signedUnits));
            assert(old.rawSpeedUnitsPerSecond > 107.0);
            assert(old.filteredSpeedUnitsPerSecond > 95.0);
            assert(old.velocityLimited);

            // Existing compatibility handoff clears both independently moving axes.
            MFRingAxis other = axis == kMFRingAxisVertical
                ? kMFRingAxisHorizontal : kMFRingAxisVertical;
            MFRingMotionPlaneApplyReport(&config, &plane, other,
                report(1570, 100.0, -sign));
            MFRingMotionPlaneReset(&plane, 1571);
            assert(MFRingMotionPlaneRemainingDistance(&plane) == 0.0);
            for (int i = 0; i < 3; i++) {
                MFRingCorrelationResult repeated = MFRingInputBufferCorrelate(
                    &buffer, 100.03 + i * 0.001, 42, axis, sign * (i + 1),
                    sign * (i + 1), 0.030, 0.002);
                assert(!MFRingCorrelationHasRawMotionUnits(repeated));
                assert(repeated.signedUnits == sign * (i + 1));
            }
            MFRingMotionUpdate stale = MFRingMotionPlaneApplyReport(
                &config, &plane, axis, report(1570, 100.04, sign));
            assert(!stale.accepted && stale.staleGeneration);
            MFRingInputBufferPush(&buffer, (MFRingRawSample) {
                .sequence = 3849, .generation = 1, .deviceRegistryID = 42,
                .timestamp = 100.053, .axis = axis, .signedUnits = sign,
            });
            MFRingCorrelationResult paired = MFRingInputBufferCorrelate(
                &buffer, 100.053, 42, axis, sign * 4, 1, 0.030, 0.002);
            assert(MFRingCorrelationHasRawMotionUnits(paired));
            assert(paired.signedUnits == sign);
            MFRingMotionUpdate clean = MFRingMotionPlaneApplyReport(
                &config, &plane, axis, report(1571, 100.053, paired.signedUnits));
            assert(clean.accepted && !clean.hasMeasuredCadence);
            assert(clean.rawSpeedUnitsPerSecond == config.initialSpeedUnitsPerSecond);
            assert(clean.filteredSpeedUnitsPerSecond == config.initialSpeedUnitsPerSecond);
            assert(clean.carriedVelocityPixelsPerSecond == 0.0);
            MFRingMotionPlaneFrame frame = MFRingMotionPlaneAdvance(&plane, 1.0 / 120.0);
            double output = axis == kMFRingAxisVertical
                ? frame.vertical.distancePixels : frame.horizontal.distancePixels;
            assert(output * sign > 0.0);
            MFRingMotionUpdate fast = MFRingMotionPlaneApplyReport(
                &config, &plane, axis, report(1571, 100.080995, sign));
            assert(fast.accepted && fast.rawSpeedUnitsPerSecond > 35.0);
            assert(fast.pixelsPerUnit > clean.pixelsPerUnit);
            assertFiniteAndBounded(&config, state);
        }
    }
}

int main(void) {
    testCapturedCGFallbackCannotPoisonRawMotion();
    testNormalDistanceForResumedOpenings();
    testCurrentUIParameterMapping();
    testFirstReportIsImmediateNormalAndBounded();
    testSecondSparseReportEstablishesOverlapImmediately();
    testLowSpeedFrequencyIgnoresDirection();
    testReversalFrequencyDoesNotRetainFastOrStaleHistory();
    testCapturedStoppedSparseOpeningRaisesRateWithoutAddingDistance();
    testCapturedNearlyExhaustedTailCountsAsStoppedOutput();
    testCapturedThreePixelStoppedOpeningGetsDecisiveRate();
    testCapturedStoppedOpeningMatchesNormalOpeningVelocity();
    testCapturedReversalTreatsDiscardedOldAreaAsStoppedOutput();
    testCapturedWeakContinuityAndBoundarySweep();
    testSparseImpulseCrossesOnePixelWithinTwoFastCallbacks();
    testAccelerationUsesCurrentReport();
    testSameDirectionAddsAndReversalCancels();
    testIndependentPhysicalAxesShareOneFrameClock();
    testExactIntegrationIsRefreshIndependent();
    testVariableRefreshIntegrationIsEquivalent();
    testLinearTransferIsPacketizationIndependent();
    testIndependentCapsAndResetGeneration();
    testInvalidTimeAndLongFrameAreBounded();
    testRandomSequencesRemainFiniteAndBounded();

    puts("RingMotionModelTests: PASS");
    return 0;
}
