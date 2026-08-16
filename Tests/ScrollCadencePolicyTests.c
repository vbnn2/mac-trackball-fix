//
// --------------------------------------------------------------------------
// ScrollCadencePolicyTests.c
// Standalone deterministic regression checks. Run with:
//   clang -std=c11 Tests/ScrollCadencePolicyTests.c -o /tmp/scroll-cadence-tests
//   /tmp/scroll-cadence-tests
// --------------------------------------------------------------------------
//

#include <assert.h>
#include <stdio.h>

#include "../Helper/Core/Scroll/ScrollCadencePolicy.h"

static void testLongIdleWakeRampKeepsOpeningCapThroughMeasuredRamp(void) {
    const double blend = MFScrollIdleWakeOpeningCapBlend(
        true,
        false,
        108.520,
        0.182,
        20.0,
        0.750,
        0.750,
        1,
        118.5,
        500.0
    );

    assert(blend == 1.0);

    const double laterBlend = MFScrollIdleWakeOpeningCapBlend(
        true,
        false,
        108.520,
        0.558,
        20.0,
        0.750,
        0.750,
        1,
        134.7,
        500.0
    );
    assert(laterBlend == 1.0);
}

static void testLongIdleWakeCapFadesContinuouslyAfterMeasuredRamp(void) {
    const double holdBoundaryBlend = MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 0.750, 20.0, 0.750, 0.750, 1, 118.5, 500.0
    );
    const double halfwayBlend = MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 1.125, 20.0, 0.750, 0.750, 1, 118.5, 500.0
    );
    const double expiryBlend = MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 1.500, 20.0, 0.750, 0.750, 1, 118.5, 500.0
    );

    assert(holdBoundaryBlend == 1.0);
    assert(halfwayBlend == 0.5);
    assert(expiryBlend == 0.0);
}

static void testLateSecondWakeReportDoesNotConsumeProtectionDuringSilence(void) {
    /// Fresh physical captures supplied their second one-unit reports 328ms and 449ms
    /// after the opening report. Both must retain the complete opening cap; treating
    /// those silent intervals as fade progress left 193–215ms base responses.
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 262.341, 0.328, 20.0, 0.750, 0.750, 1, 91.6, 500.0
    ) == 1.0);
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 207.105, 0.449, 20.0, 0.750, 0.750, 1, 64.3, 500.0
    ) == 1.0);
}

static void testRecentAndCompletedStartsDoNotGetWakeCompensation(void) {
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 4.876, 0.182, 20.0, 0.750, 0.750, 1, 118.5, 500.0
    ) == 0.0);
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 1.500, 20.0, 0.750, 0.750, 1, 118.5, 500.0
    ) == 0.0);
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, true, 108.520, 0.182, 20.0, 0.750, 0.750, 1, 118.5, 500.0
    ) == 0.0);
}

static void testFastOrSubstantialInputEndsWakeShapingImmediately(void) {
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 0.182, 20.0, 0.750, 0.750, 3, 118.5, 500.0
    ) == 0.0);
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 0.182, 20.0, 0.750, 0.750, 1, 500.0, 500.0
    ) == 0.0);
}

static void testWakeRampUsesResponsiveOpeningCap(void) {
    const double responsiveOpeningCap = 0.080;
    const double adaptiveOpeningCap = 0.1327;

    assert(MFScrollIdleWakeBaseDurationCap(
        responsiveOpeningCap, adaptiveOpeningCap
    ) == responsiveOpeningCap);
}

static void testAcceleratingLowUnitRampOnlyCapsVelocityNotch(void) {
    assert(MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 8, 1, 900.0, 160.0, 2250.0, 287.7, 250.0
    ));

    /// Captured at 12:52:43.041: point magnitude rose from 6 to 14 during the
    /// opening, but a longer packet gap made line-derived modeled speed fall.
    /// Do not let that contradictory packet decelerate 342px/s live motion to
    /// the old 228px/s request.
    assert(MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 14, 6, 430.0, 624.5, 2250.0, 342.3, 227.5
    ));

    /// A genuine careful point report has no amplified point delta.
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 1, 1, 180.0, 160.0, 2250.0, 287.7, 250.0
    ));
    /// Falling modeled speed with flat/falling point magnitude is genuine
    /// deceleration, not opening-ramp evidence.
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 13, 15, 225.0, 624.5, 2250.0, 601.5, 270.3
    ));
    /// Do not make an already-accelerating retarget more aggressive.
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 8, 1, 900.0, 160.0, 2250.0, 287.7, 440.0
    ));
    /// Substantial or fast input keeps the ordinary bounded path.
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 3, 32, 8, 1800.0, 900.0, 2250.0, 287.7, 250.0
    ));
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 8, 1, 2250.0, 160.0, 2250.0, 287.7, 250.0
    ));
}

static void testStoppedCloseReversalContinuationKeepsOpeningEnvelope(void) {
    /// Captured 2026-08-07 path: the close reversal response had ended before a
    /// one-unit, same-direction continuation arrived 216ms later. That report
    /// must not restart from rest with the full maximum-slow duration.
    assert(MFScrollShouldCapStoppedCloseReversalContinuation(
        true, true, false, false, 1, 146.7, 2250.0
    ));
    assert(MFScrollStoppedCloseReversalBaseDurationCap(
        0.2701, 0.1327
    ) == 0.1327);
    assert(MFScrollStoppedCloseReversalBaseDurationCap(
        0.1000, 0.1327
    ) == 0.1000);

    /// A live reversal response, a new analyzer gesture, another reversal,
    /// substantial input, or input outside the slow band keeps its ordinary path.
    assert(!MFScrollShouldCapStoppedCloseReversalContinuation(
        true, false, false, false, 1, 146.7, 2250.0
    ));
    assert(!MFScrollShouldCapStoppedCloseReversalContinuation(
        true, true, true, false, 1, 146.7, 2250.0
    ));
    assert(!MFScrollShouldCapStoppedCloseReversalContinuation(
        true, true, false, true, 1, 146.7, 2250.0
    ));
    assert(!MFScrollShouldCapStoppedCloseReversalContinuation(
        true, true, false, false, 3, 146.7, 2250.0
    ));
    assert(!MFScrollShouldCapStoppedCloseReversalContinuation(
        true, true, false, false, 1, 2250.0, 2250.0
    ));
}

static void testStoppedMeasuredSlowContinuationRegainsOpeningEnvelope(void) {
    const double slowSpeedMax = 2250.0;

    /// Captured at 15:03:51.137 and 15:03:51.874: measured same-direction
    /// one-unit reports restarted after motion had ended at only 111 and 107px/s.
    assert(MFScrollShouldCapStoppedSlowContinuation(
        true, true, false, false, false, 1, 82.5, slowSpeedMax
    ));
    assert(MFScrollShouldCapStoppedSlowContinuation(
        true, true, false, false, false, 1, 62.3, slowSpeedMax
    ));
    assert(MFScrollStoppedSlowContinuationBaseDurationCap(
        0.2704, 0.1329
    ) == 0.1329);
    assert(MFScrollStoppedSlowContinuationBaseDurationCap(
        0.1000, 0.1329
    ) == 0.1000);

    /// Live overlapping sparse motion, an analyzer opening, a reversal,
    /// substantial/fast input, and disabled adaptive control remain unchanged.
    assert(!MFScrollShouldCapStoppedSlowContinuation(
        true, true, true, false, false, 1, 82.5, slowSpeedMax
    ));
    assert(!MFScrollShouldCapStoppedSlowContinuation(
        true, true, false, true, false, 1, 82.5, slowSpeedMax
    ));
    assert(!MFScrollShouldCapStoppedSlowContinuation(
        true, true, false, false, true, 1, 82.5, slowSpeedMax
    ));
    assert(!MFScrollShouldCapStoppedSlowContinuation(
        true, true, false, false, false, 3, 82.5, slowSpeedMax
    ));
    assert(!MFScrollShouldCapStoppedSlowContinuation(
        true, true, false, false, false, 1, slowSpeedMax, slowSpeedMax
    ));
    assert(!MFScrollShouldCapStoppedSlowContinuation(
        false, true, false, false, false, 1, 82.5, slowSpeedMax
    ));
    assert(!MFScrollShouldCapStoppedSlowContinuation(
        true, false, false, false, false, 1, 82.5, slowSpeedMax
    ));
}

static void testStoppedRememberedSlowOpeningRegainsOpeningEnvelope(void) {
    const double slowSpeedMax = 2250.0;
    const double gestureBoundary = 0.500;

    /// Captured at 23:01:58.286 and 23:03:26.347: after 711ms and 616ms gaps,
    /// the analyzer opened a new gesture but an already-stopped response reused
    /// established 372ms and 275ms cadence references, producing 246ms and
    /// 197ms bases. These visible openings regain the adaptive envelope.
    assert(MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, true, false, true, 0.3718,
        1, 160.0, slowSpeedMax, 0.711, gestureBoundary
    ));
    assert(MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, true, false, true, 0.2749,
        1, 160.0, slowSpeedMax, 0.616, gestureBoundary
    ));
    assert(MFScrollStoppedSlowContinuationBaseDurationCap(
        0.2457, 0.1329
    ) == 0.1329);
    assert(MFScrollStoppedSlowContinuationBaseDurationCap(
        0.1969, 0.1329
    ) == 0.1329);

    /// Live overlap, measured in-gesture continuation, reversal, unestablished
    /// cadence, substantial/fast input, and a sub-boundary gap stay unchanged.
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        true, true, true, false, true, 0.3718,
        1, 160.0, slowSpeedMax, 0.711, gestureBoundary
    ));
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, false, false, true, 0.3718,
        1, 160.0, slowSpeedMax, 0.711, gestureBoundary
    ));
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, true, true, true, 0.3718,
        1, 160.0, slowSpeedMax, 0.711, gestureBoundary
    ));
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, true, false, true, 0.0,
        1, 160.0, slowSpeedMax, 0.711, gestureBoundary
    ));
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, true, false, true, 0.3718,
        3, 160.0, slowSpeedMax, 0.711, gestureBoundary
    ));
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, true, false, true, 0.3718,
        1, slowSpeedMax, slowSpeedMax, 0.711, gestureBoundary
    ));
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, true, false, true, 0.3718,
        1, 160.0, slowSpeedMax, 0.499, gestureBoundary
    ));
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        true, false, true, false, false, 0.3718,
        1, 160.0, slowSpeedMax, 0.711, gestureBoundary
    ));
    assert(!MFScrollShouldCapStoppedRememberedSlowOpening(
        false, false, true, false, true, 0.3718,
        1, 160.0, slowSpeedMax, 0.711, gestureBoundary
    ));
}

static void testStoppedPausedReversalContinuouslyRegainsOpeningEnvelope(void) {
    const double slowSpeedMax = 2250.0;

    /// The accepted 292ms reversal remains untouched. The reported 382ms
    /// stopped reversal receives the full adaptive opening cap, while the
    /// interval between them changes continuously.
    assert(MFScrollStoppedPausedReversalOpeningCapBlend(
        true, false, true, true, true, 1, 160.0, slowSpeedMax,
        0.292, 0.300, 0.380, 0.500
    ) == 0.0);
    const double middleBlend = MFScrollStoppedPausedReversalOpeningCapBlend(
        true, false, true, true, true, 1, 160.0, slowSpeedMax,
        0.340, 0.300, 0.380, 0.500
    );
    assert(middleBlend > 0.499 && middleBlend < 0.501);
    assert(MFScrollStoppedPausedReversalOpeningCapBlend(
        true, false, true, true, true, 1, 160.0, slowSpeedMax,
        0.382, 0.300, 0.380, 0.500
    ) == 1.0);

    assert(MFScrollStoppedPausedReversalBaseDuration(
        0.1738, 0.1012, 1.0
    ) == 0.1012);
    const double middleBase = MFScrollStoppedPausedReversalBaseDuration(
        0.1738, 0.1012, middleBlend
    );
    assert(middleBase > 0.1374 && middleBase < 0.1376);

    /// Live motion, a close reversal, ordinary same-direction sparse motion,
    /// substantial input, fast input, and a fresh >=500ms reversal do not match.
    assert(MFScrollStoppedPausedReversalOpeningCapBlend(
        true, true, true, true, true, 1, 160.0, slowSpeedMax,
        0.382, 0.300, 0.380, 0.500
    ) == 0.0);
    assert(MFScrollStoppedPausedReversalOpeningCapBlend(
        true, false, true, true, true, 1, 160.0, slowSpeedMax,
        0.200, 0.300, 0.380, 0.500
    ) == 0.0);
    assert(MFScrollStoppedPausedReversalOpeningCapBlend(
        true, false, true, false, true, 1, 160.0, slowSpeedMax,
        0.382, 0.300, 0.380, 0.500
    ) == 0.0);
    assert(MFScrollStoppedPausedReversalOpeningCapBlend(
        true, false, true, true, true, 3, 160.0, slowSpeedMax,
        0.382, 0.300, 0.380, 0.500
    ) == 0.0);
    assert(MFScrollStoppedPausedReversalOpeningCapBlend(
        true, false, true, true, true, 1, slowSpeedMax, slowSpeedMax,
        0.382, 0.300, 0.380, 0.500
    ) == 0.0);
    assert(MFScrollStoppedPausedReversalOpeningCapBlend(
        true, false, true, true, true, 1, 160.0, slowSpeedMax,
        0.500, 0.300, 0.380, 0.500
    ) == 0.0);
}

static void testStoppedUnestablishedReversalRegainsOpeningEnvelope(void) {
    const double slowSpeedMax = 2250.0;

    /// Captured at 14:33:23.782: a stopped one-unit reversal arrived after
    /// 209ms with no cadence estimate known before the report. Its own pause
    /// expanded the base to 156ms and opened at only 205px/s.
    assert(MFScrollShouldCapStoppedUnestablishedReversalOpening(
        true, false, true, true, true, 0.0,
        1, 160.0, slowSpeedMax, 0.209, 0.200, 0.500
    ));
    assert(MFScrollStoppedSlowContinuationBaseDurationCap(
        0.1560, 0.1329
    ) == 0.1329);

    /// Established cadence, live overlap, the accepted fully continuous
    /// <=200ms window, same-direction input, and a fresh >=500ms reversal do
    /// not enter this narrowly scoped opening cap.
    assert(!MFScrollShouldCapStoppedUnestablishedReversalOpening(
        true, false, true, true, true, 0.180,
        1, 160.0, slowSpeedMax, 0.254, 0.200, 0.500
    ));
    assert(!MFScrollShouldCapStoppedUnestablishedReversalOpening(
        true, true, true, true, true, 0.0,
        1, 160.0, slowSpeedMax, 0.209, 0.200, 0.500
    ));
    assert(!MFScrollShouldCapStoppedUnestablishedReversalOpening(
        true, false, true, true, true, 0.0,
        1, 160.0, slowSpeedMax, 0.200, 0.200, 0.500
    ));
    assert(!MFScrollShouldCapStoppedUnestablishedReversalOpening(
        true, false, true, false, true, 0.0,
        1, 160.0, slowSpeedMax, 0.209, 0.200, 0.500
    ));
    assert(!MFScrollShouldCapStoppedUnestablishedReversalOpening(
        true, false, true, true, true, 0.0,
        1, 160.0, slowSpeedMax, 0.500, 0.200, 0.500
    ));
    assert(!MFScrollShouldCapStoppedUnestablishedReversalOpening(
        true, false, true, true, true, 0.0,
        3, 160.0, slowSpeedMax, 0.209, 0.200, 0.500
    ));
    assert(!MFScrollShouldCapStoppedUnestablishedReversalOpening(
        true, false, true, true, true, 0.0,
        1, slowSpeedMax, slowSpeedMax, 0.209, 0.200, 0.500
    ));
}

static void testPostFastMultiUnitReportCannotBootstrapAStickyRestart(void) {
    const double slowSpeedMax = 500.0;
    const bool previousWasEligible = MFScrollReportCanSeedSlowCadence(
        7,
        329.4,
        slowSpeedMax,
        false,
        false,
        false
    );

    assert(!previousWasEligible);
    assert(!MFScrollShouldContinueSlowCadence(
        true,
        true,
        previousWasEligible,
        1,
        false,
        0.681,
        0.500,
        1.500
    ));
}

static void testSecondGenuineSparseReportStillUsesMeasuredCadence(void) {
    const double slowSpeedMax = 500.0;
    const bool previousWasEligible = MFScrollReportCanSeedSlowCadence(
        1,
        120.0,
        slowSpeedMax,
        false,
        false,
        false
    );

    assert(previousWasEligible);
    assert(MFScrollShouldContinueSlowCadence(
        true,
        true,
        previousWasEligible,
        1,
        false,
        0.681,
        0.500,
        1.500
    ));

    /// Captured 2026-08-09 path: the second one-unit report arrived after
    /// 732ms with no cadence estimate established before it. It still qualifies
    /// as possible sparse motion, but its own silence cannot become a 500ms
    /// duration reference and weaken this stopped restart to roughly 101px/s.
    assert(MFScrollSlowCadenceDurationReference(
        0.0, 0.732, 0.732, false, 0.500
    ) == 0.0);
    const double oldSelfLengthenedBase = MFScrollSlowCadenceBaseDuration(
        0.120, 0.500, 0.750, 0.900, 0.768
    );
    const double boundedCurrentReportBase = MFScrollSlowCadenceBaseDuration(
        0.120, 0.0, 0.750, 0.900, 0.768
    );
    assert(oldSelfLengthenedBase > 0.315 && oldSelfLengthenedBase < 0.317);
    assert(boundedCurrentReportBase == 0.120);

    /// The measured gap is available to a later report, while close reversal
    /// keeps its existing actual cross-direction cadence reference.
    assert(MFScrollSlowCadenceDurationReference(
        0.145, 0.4385, 0.732, false, 0.500
    ) == 0.145);
    assert(MFScrollSlowCadenceDurationReference(
        0.0, 0.061, 0.061, true, 0.500
    ) == 0.061);
}

static void testTailAndAccelerationReportsNeverSeedCadence(void) {
    const double slowSpeedMax = 500.0;

    assert(!MFScrollReportCanSeedSlowCadence(1, 120.0, slowSpeedMax, true, false, false));
    assert(!MFScrollReportCanSeedSlowCadence(1, 120.0, slowSpeedMax, false, true, false));
    assert(!MFScrollReportCanSeedSlowCadence(1, 120.0, slowSpeedMax, false, false, true));
    assert(!MFScrollReportCanSeedSlowCadence(3, 120.0, slowSpeedMax, false, false, false));
    assert(!MFScrollReportCanSeedSlowCadence(1, 500.0, slowSpeedMax, false, false, false));
}

static void testSharpDecelerationTailCannotWeakenStoppedOrLaterRestart(void) {
    const double slowSpeedMax = 2250.0;
    const double sharpRatioMax = 0.25;

    /// Captured 2026-08-11 paths dropped from roughly 1021 -> 70px/s and
    /// 897 -> 111px/s. Both are deceleration edges, not established slow cadence.
    const bool stoppedTail = MFScrollIsSharpDecelerationTailReport(
        true, true, false, 1, 1, 1,
        69.8, 1021.0, slowSpeedMax, sharpRatioMax
    );
    const bool liveTail = MFScrollIsSharpDecelerationTailReport(
        true, true, false, 1, 1, 1,
        110.5, 897.0, slowSpeedMax, sharpRatioMax
    );
    assert(stoppedTail);
    assert(liveTail);
    assert(MFScrollShouldCapStoppedSharpDecelerationTail(stoppedTail, false));
    assert(!MFScrollShouldCapStoppedSharpDecelerationTail(liveTail, true));
    assert(MFScrollStoppedSharpDecelerationBaseDurationCap(
        0.2704, 0.1329
    ) == 0.1329);
    assert(MFScrollStoppedSharpDecelerationBaseDurationCap(
        0.1000, 0.1329
    ) == 0.1000);
    const bool liveTailCanSeedCadence = MFScrollReportCanSeedSlowCadence(
        1, 110.5, slowSpeedMax, false, false, liveTail
    );
    assert(!liveTailCanSeedCadence);
    assert(!MFScrollShouldContinueSlowCadence(
        true, true, liveTailCanSeedCadence, 1, false, 0.7121, 0.500, 1.500
    ));

    /// Captured 2026-08-16 recurrence: modeled speed fell only to about one
    /// third, but point magnitude collapsed from an amplified 19 to the
    /// one-point baseline. This tail must not seed the stopped reversal 323ms
    /// later with slow cadence.
    const bool pointCollapseTail = MFScrollIsSharpDecelerationTailReport(
        true, true, false, 1, 1, 19,
        179.2, 552.4, slowSpeedMax, sharpRatioMax
    );
    assert(pointCollapseTail);
    assert(!MFScrollReportCanSeedSlowCadence(
        1, 179.2, slowSpeedMax, false, false, pointCollapseTail
    ));

    /// Gradual careful deceleration, a still-amplified falling point report,
    /// an unchanged one-point report, a reversal, substantial input, or an
    /// unmeasured opening keeps the established policy.
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, true, false, 1, 4, 5,
        300.0, 900.0, slowSpeedMax, sharpRatioMax
    ));
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, true, false, 1, 13, 15,
        225.0, 624.5, slowSpeedMax, sharpRatioMax
    ));
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, true, false, 1, 1, 1,
        300.0, 900.0, slowSpeedMax, sharpRatioMax
    ));
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, true, true, 1, 1, 19,
        179.2, 552.4, slowSpeedMax, sharpRatioMax
    ));
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, true, false, 3, 1, 19,
        179.2, 552.4, slowSpeedMax, sharpRatioMax
    ));
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, false, false, 1, 1, 19,
        179.2, 552.4, slowSpeedMax, sharpRatioMax
    ));
    assert(MFScrollReportCanSeedSlowCadence(
        1, 300.0, slowSpeedMax, false, false, false
    ));
}

static void testResetAndMemoryHorizonCannotReuseCadence(void) {
    assert(!MFScrollShouldContinueSlowCadence(
        true,
        true,
        false,
        1,
        false,
        0.681,
        0.500,
        1.500
    ));
    assert(!MFScrollShouldContinueSlowCadence(
        true,
        true,
        true,
        1,
        false,
        1.501,
        0.500,
        1.500
    ));
}

int main(void) {
    testLongIdleWakeRampKeepsOpeningCapThroughMeasuredRamp();
    testLongIdleWakeCapFadesContinuouslyAfterMeasuredRamp();
    testLateSecondWakeReportDoesNotConsumeProtectionDuringSilence();
    testRecentAndCompletedStartsDoNotGetWakeCompensation();
    testFastOrSubstantialInputEndsWakeShapingImmediately();
    testWakeRampUsesResponsiveOpeningCap();
    testAcceleratingLowUnitRampOnlyCapsVelocityNotch();
    testStoppedCloseReversalContinuationKeepsOpeningEnvelope();
    testStoppedMeasuredSlowContinuationRegainsOpeningEnvelope();
    testStoppedRememberedSlowOpeningRegainsOpeningEnvelope();
    testStoppedPausedReversalContinuouslyRegainsOpeningEnvelope();
    testStoppedUnestablishedReversalRegainsOpeningEnvelope();
    testPostFastMultiUnitReportCannotBootstrapAStickyRestart();
    testSecondGenuineSparseReportStillUsesMeasuredCadence();
    testTailAndAccelerationReportsNeverSeedCadence();
    testSharpDecelerationTailCannotWeakenStoppedOrLaterRestart();
    testResetAndMemoryHorizonCannotReuseCadence();

    puts("ScrollCadencePolicyTests: PASS");
    return 0;
}
