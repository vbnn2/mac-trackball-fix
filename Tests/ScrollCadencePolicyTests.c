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

static void testPostFastMultiUnitReportCannotBootstrapAStickyRestart(void) {
    const double slowSpeedMax = 500.0;
    const bool previousWasEligible = MFScrollReportCanSeedSlowCadence(
        7,
        329.4,
        slowSpeedMax,
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
}

static void testTailAndAccelerationReportsNeverSeedCadence(void) {
    const double slowSpeedMax = 500.0;

    assert(!MFScrollReportCanSeedSlowCadence(1, 120.0, slowSpeedMax, true, false));
    assert(!MFScrollReportCanSeedSlowCadence(1, 120.0, slowSpeedMax, false, true));
    assert(!MFScrollReportCanSeedSlowCadence(3, 120.0, slowSpeedMax, false, false));
    assert(!MFScrollReportCanSeedSlowCadence(1, 500.0, slowSpeedMax, false, false));
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
    testPostFastMultiUnitReportCannotBootstrapAStickyRestart();
    testSecondGenuineSparseReportStillUsesMeasuredCadence();
    testTailAndAccelerationReportsNeverSeedCadence();
    testResetAndMemoryHorizonCannotReuseCadence();

    puts("ScrollCadencePolicyTests: PASS");
    return 0;
}
