//
// --------------------------------------------------------------------------
// ScrollOutputPolicyTests.c
// Standalone deterministic regression checks.
// --------------------------------------------------------------------------
//

#include <assert.h>
#include <math.h>
#include <stdio.h>

#include "../Helper/Core/Scroll/ScrollOutputPolicy.h"

static void testSpeedAndInputModesRemainMonotonic(void) {
    const double velocity = 50.0;
    const double pxAtRef = 24.0;
    const double refSpeed = 50.0;
    const double gamma = 1.2;

    const double low = MFScrollPixelsPerUnit(velocity, pxAtRef, refSpeed, gamma, 0.65);
    const double medium = MFScrollPixelsPerUnit(velocity, pxAtRef, refSpeed, gamma, 1.0);
    const double high = MFScrollPixelsPerUnit(velocity, pxAtRef, refSpeed, gamma, 1.5);
    const double precise = MFScrollPixelsPerUnit(velocity, pxAtRef, refSpeed, gamma, 0.15);
    const double quick = MFScrollPixelsPerUnit(velocity, pxAtRef, refSpeed, gamma, 20.0);

    assert(low < medium);
    assert(medium < high);
    assert(precise < medium);
    assert(medium < quick);
}

static void testTimeBasedLimitIsCadenceIndependent(void) {
    const double maxSpeed = 18000.0;
    const double firstLimit = MFScrollOutputDistanceLimit(
        false, 0.0, 0.001, maxSpeed, 360.0);
    const double limitAt50Hz = MFScrollOutputDistanceLimit(
        true, 0.020, 0.001, maxSpeed, 360.0);
    const double limitAt100Hz = MFScrollOutputDistanceLimit(
        true, 0.010, 0.001, maxSpeed, 360.0);

    assert(fabs(firstLimit - 360.0) < 0.001);
    assert(fabs(limitAt50Hz - 360.0) < 0.001);
    assert(fabs(limitAt100Hz - 180.0) < 0.001);
    assert(fabs((limitAt50Hz / 0.020) - (limitAt100Hz / 0.010)) < 0.001);
}

int main(void) {
    testSpeedAndInputModesRemainMonotonic();
    testTimeBasedLimitIsCadenceIndependent();

    puts("ScrollOutputPolicyTests: PASS");
    return 0;
}
