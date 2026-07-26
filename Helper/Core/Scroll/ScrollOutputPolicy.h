//
// --------------------------------------------------------------------------
// ScrollOutputPolicy.h
// Pure true-velocity mapping and time-based output bounds.
// --------------------------------------------------------------------------
//

#ifndef ScrollOutputPolicy_h
#define ScrollOutputPolicy_h

#include <math.h>
#include <stdbool.h>

static inline double MFScrollPixelsPerUnit(
    double inputVelocity,
    double pxAtRefSpeed,
    double refSpeed,
    double gamma,
    double distanceMultiplier
) {
    return pxAtRefSpeed
        * pow(inputVelocity / refSpeed, gamma - 1.0)
        * distanceMultiplier;
}

static inline double MFScrollModeledOutputSpeed(
    double inputVelocity,
    double pxAtRefSpeed,
    double refSpeed,
    double gamma,
    double distanceMultiplier
) {
    return pxAtRefSpeed
        * refSpeed
        * pow(inputVelocity / refSpeed, gamma)
        * distanceMultiplier;
}

static inline double MFScrollOutputDistanceLimit(
    bool hasMeasuredInterval,
    double measuredInterval,
    double minimumInterval,
    double maximumOutputSpeed,
    double maximumInitialDistance
) {
    return hasMeasuredInterval
        ? maximumOutputSpeed * fmax(measuredInterval, minimumInterval)
        : maximumInitialDistance;
}

#endif /* ScrollOutputPolicy_h */
