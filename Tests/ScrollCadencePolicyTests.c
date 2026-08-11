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
        true, true, 1, 8, 900.0, 160.0, 2250.0, 287.7, 250.0
    ));

    /// A genuine careful point report has no amplified point delta.
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 1, 180.0, 160.0, 2250.0, 287.7, 250.0
    ));
    /// Do not make an already-accelerating retarget more aggressive.
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 8, 900.0, 160.0, 2250.0, 287.7, 440.0
    ));
    /// Substantial or fast input keeps the ordinary bounded path.
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 3, 32, 1800.0, 900.0, 2250.0, 287.7, 250.0
    ));
    assert(!MFScrollShouldCapAcceleratingLowUnitRamp(
        true, true, 1, 8, 2250.0, 160.0, 2250.0, 287.7, 250.0
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
        true, true, false, 1, 69.8, 1021.0, slowSpeedMax, sharpRatioMax
    );
    const bool liveTail = MFScrollIsSharpDecelerationTailReport(
        true, true, false, 1, 110.5, 897.0, slowSpeedMax, sharpRatioMax
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

    /// Gradual careful deceleration, a reversal, substantial input, or an
    /// unmeasured opening keeps the established policy.
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, true, false, 1, 300.0, 900.0, slowSpeedMax, sharpRatioMax
    ));
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, true, true, 1, 110.5, 897.0, slowSpeedMax, sharpRatioMax
    ));
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, true, false, 3, 110.5, 897.0, slowSpeedMax, sharpRatioMax
    ));
    assert(!MFScrollIsSharpDecelerationTailReport(
        true, false, false, 1, 110.5, 897.0, slowSpeedMax, sharpRatioMax
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
    testPostFastMultiUnitReportCannotBootstrapAStickyRestart();
    testSecondGenuineSparseReportStillUsesMeasuredCadence();
    testTailAndAccelerationReportsNeverSeedCadence();
    testSharpDecelerationTailCannotWeakenStoppedOrLaterRestart();
    testResetAndMemoryHorizonCannotReuseCadence();

    puts("ScrollCadencePolicyTests: PASS");
    return 0;
}
