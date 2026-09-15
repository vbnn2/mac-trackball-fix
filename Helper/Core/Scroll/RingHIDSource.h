//
// --------------------------------------------------------------------------
// RingHIDSource.h
// Passive raw-HID observation for the TB800 ring rewrite.
// --------------------------------------------------------------------------
//

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDDevice.h>

#import "RingInputCorrelator.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct MFRingCGObservation {
    bool isTargetDevice;
    uint64_t sequence;
    uint64_t generation;
    MFRingCorrelationResult correlation;
} MFRingCGObservation;

@interface RingHIDSource : NSObject

/// Starts an independent, non-seizing IOHIDManager sidecar matched only to the
/// locally observed Kensington Expert Mouse TB800 receiver collection.
+ (void)startObserving;
+ (void)stopObserving;
+ (BOOL)hasAttachedTarget;

/// Correlates immediately against samples which already reached the HID
/// callback. A miss returns CG-line fallback; this method never waits.
+ (MFRingCGObservation)observeCGEventAtTimestamp:(CFTimeInterval)timestamp
                                    sendingDevice:(nullable IOHIDDeviceRef)sendingDevice
                                             axis:(MFRingAxis)axis
                                      cgLineUnits:(int64_t)cgLineUnits
                                  cgFallbackUnits:(int64_t)cgFallbackUnits;

@end

NS_ASSUME_NONNULL_END
