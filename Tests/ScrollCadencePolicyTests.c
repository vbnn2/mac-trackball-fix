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

static void testLongIdleWakeRampGetsContinuouslyTaperedOpeningCap(void) {
    const double blend = MFScrollIdleWakeOpeningCapBlend(
        true,
        false,
        108.520,
        0.182,
        20.0,
        0.750,
        1,
        118.5,
        500.0
    );

    assert(blend > 0.75 && blend < 0.76);

    const double laterBlend = MFScrollIdleWakeOpeningCapBlend(
        true,
        false,
        108.520,
        0.558,
        20.0,
        0.750,
        1,
        134.7,
        500.0
    );
    assert(laterBlend > 0.25 && laterBlend < 0.26);
    assert(laterBlend < blend);
}

static void testRecentAndCompletedStartsDoNotGetWakeCompensation(void) {
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 4.876, 0.182, 20.0, 0.750, 1, 118.5, 500.0
    ) == 0.0);
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 0.750, 20.0, 0.750, 1, 118.5, 500.0
    ) == 0.0);
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, true, 108.520, 0.182, 20.0, 0.750, 1, 118.5, 500.0
    ) == 0.0);
}

static void testFastOrSubstantialInputEndsWakeShapingImmediately(void) {
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 0.182, 20.0, 0.750, 3, 118.5, 500.0
    ) == 0.0);
    assert(MFScrollIdleWakeOpeningCapBlend(
        true, false, 108.520, 0.182, 20.0, 0.750, 1, 500.0, 500.0
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
    testLongIdleWakeRampGetsContinuouslyTaperedOpeningCap();
    testRecentAndCompletedStartsDoNotGetWakeCompensation();
    testFastOrSubstantialInputEndsWakeShapingImmediately();
    testPostFastMultiUnitReportCannotBootstrapAStickyRestart();
    testSecondGenuineSparseReportStillUsesMeasuredCadence();
    testTailAndAccelerationReportsNeverSeedCadence();
    testResetAndMemoryHorizonCannotReuseCadence();

    puts("ScrollCadencePolicyTests: PASS");
    return 0;
}
