//
// --------------------------------------------------------------------------
// RingHIDSource.m
// Passive raw-HID observation for the TB800 ring rewrite.
// --------------------------------------------------------------------------
//

#import "RingHIDSource.h"

#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <os/lock.h>
#import <stdatomic.h>

#import "Logging.h"
#import "SharedUtility.h"

static const NSInteger kMFRingTB800VendorID = 1149;
static const NSInteger kMFRingTB800ProductID = 33129;
static const double kMFRingCorrelationWindowSeconds = 30.0 / 1000.0;
static const double kMFRingMaximumFutureSkewSeconds = 2.0 / 1000.0;
static const uint64_t kMFRingInputTelemetryVersion = 1;

static IOHIDManagerRef _ringHIDManager;
static os_unfair_lock _ringBufferLock = OS_UNFAIR_LOCK_INIT;
static MFRingInputBuffer _ringInputBuffer;
static uint64_t _ringRawSequence;
static uint64_t _ringCGSequence;
static uint64_t _ringGeneration;
static atomic_int _ringAttachedTargetCount;

static uint64_t ringRegistryID(IOHIDDeviceRef device) {
    if (device == NULL) return 0;

    io_service_t service = IOHIDDeviceGetService(device);
    uint64_t registryID = 0;
    if (service == IO_OBJECT_NULL
        || IORegistryEntryGetRegistryEntryID(service, &registryID)
            != kIOReturnSuccess) {
        return 0;
    }
    return registryID;
}

static BOOL ringIsTargetDevice(IOHIDDeviceRef device) {
    if (device == NULL) return NO;

    NSNumber *vendorID = (__bridge NSNumber *)IOHIDDeviceGetProperty(
        device, CFSTR(kIOHIDVendorIDKey));
    NSNumber *productID = (__bridge NSNumber *)IOHIDDeviceGetProperty(
        device, CFSTR(kIOHIDProductIDKey));
    return vendorID.integerValue == kMFRingTB800VendorID
        && productID.integerValue == kMFRingTB800ProductID;
}

static NSString *ringAxisName(MFRingAxis axis) {
    switch (axis) {
        case kMFRingAxisVertical: return @"vertical";
        case kMFRingAxisHorizontal: return @"horizontal";
        case kMFRingAxisNone: return @"none";
    }
    return @"none";
}

static void ringHandleDeviceMatching(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDDeviceRef device
) {
    (void)context;
    (void)sender;
    if (!ringIsTargetDevice(device)) return;

    atomic_fetch_add_explicit(
        &_ringAttachedTargetCount, 1, memory_order_release);

    uint64_t registryID = ringRegistryID(device);
    os_unfair_lock_lock(&_ringBufferLock);
    _ringGeneration += 1;
    uint64_t generation = _ringGeneration;
    os_unfair_lock_unlock(&_ringBufferLock);

    NSString *product = (__bridge NSString *)IOHIDDeviceGetProperty(
        device, CFSTR(kIOHIDProductKey));
    DDLogInfo("MFSCROLL_RING_HID: version=%llu action=attach generation=%llu device=%llu vendor=%ld productID=%ld product=%{public}@ result=%d",
              kMFRingInputTelemetryVersion,
              generation,
              registryID,
              (long)kMFRingTB800VendorID,
              (long)kMFRingTB800ProductID,
              product ?: @"",
              result);
}

static void ringHandleDeviceRemoval(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDDeviceRef device
) {
    (void)context;
    (void)sender;
    if (!ringIsTargetDevice(device)) return;

    int previousAttachedCount = atomic_load_explicit(
        &_ringAttachedTargetCount, memory_order_acquire);
    if (previousAttachedCount > 0) {
        atomic_fetch_sub_explicit(
            &_ringAttachedTargetCount, 1, memory_order_release);
    }

    uint64_t registryID = ringRegistryID(device);
    os_unfair_lock_lock(&_ringBufferLock);
    MFRingInputBufferRemoveDevice(&_ringInputBuffer, registryID);
    _ringGeneration += 1;
    uint64_t generation = _ringGeneration;
    os_unfair_lock_unlock(&_ringBufferLock);

    DDLogInfo("MFSCROLL_RING_HID: version=%llu action=detach generation=%llu device=%llu result=%d",
              kMFRingInputTelemetryVersion,
              generation,
              registryID,
              result);
}

static void ringHandleInputValue(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDValueRef value
) {
    (void)context;
    (void)sender;
    if (result != kIOReturnSuccess || value == NULL) return;

    IOHIDElementRef element = IOHIDValueGetElement(value);
    IOHIDDeviceRef device = IOHIDElementGetDevice(element);
    if (!ringIsTargetDevice(device)) return;

    uint32_t usagePage = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    MFRingAxis axis = kMFRingAxisNone;
    if (usagePage == kHIDPage_GenericDesktop
        && usage == kHIDUsage_GD_Wheel) {
        axis = kMFRingAxisVertical;
    } else if (usagePage == kHIDPage_Consumer
               && usage == kHIDUsage_Csmr_ACPan) {
        axis = kMFRingAxisHorizontal;
    } else {
        return;
    }

    int64_t rawSignedUnits = IOHIDValueGetIntegerValue(value);
    if (rawSignedUnits == 0) return;
    int64_t signedUnits = MFRingNormalizeTB800Units(axis, rawSignedUnits);

    MFRingRawSample sample = {
        .generation = 0,
        .deviceRegistryID = ringRegistryID(device),
        .timestamp = machTimeToSeconds(IOHIDValueGetTimeStamp(value)),
        .axis = axis,
        .signedUnits = signedUnits,
        .reportID = IOHIDElementGetReportID(element),
    };

    os_unfair_lock_lock(&_ringBufferLock);
    sample.sequence = ++_ringRawSequence;
    sample.generation = _ringGeneration;
    bool overflowed = MFRingInputBufferPush(&_ringInputBuffer, sample);
    uint64_t overflowCount = _ringInputBuffer.overflowCount;
    os_unfair_lock_unlock(&_ringBufferLock);

    DDLogInfo("MFSCROLL_RING_HID: version=%llu action=sample rawSequence=%llu generation=%llu device=%llu axis=%{public}@ rawUnits=%lld units=%lld reportID=%u timestamp=%.9f overflow=%d overflowCount=%llu",
              kMFRingInputTelemetryVersion,
              sample.sequence,
              sample.generation,
              sample.deviceRegistryID,
              ringAxisName(sample.axis),
              rawSignedUnits,
              sample.signedUnits,
              sample.reportID,
              sample.timestamp,
              overflowed,
              overflowCount);
}

@implementation RingHIDSource

+ (void)startObserving {
    if (_ringHIDManager != NULL) return;

    MFRingInputBufferInitialize(&_ringInputBuffer);
    _ringRawSequence = 0;
    _ringCGSequence = 0;
    _ringGeneration = 0;
    atomic_store_explicit(
        &_ringAttachedTargetCount, 0, memory_order_release);

    _ringHIDManager = IOHIDManagerCreate(
        kCFAllocatorDefault, kIOHIDManagerOptionNone);
    if (_ringHIDManager == NULL) {
        DDLogError("MFSCROLL_RING_HID: version=%llu action=start result=create-failed role=observer outputAuthority=0",
                   kMFRingInputTelemetryVersion);
        return;
    }

    NSDictionary *deviceMatch = @{
        @(kIOHIDVendorIDKey): @(kMFRingTB800VendorID),
        @(kIOHIDProductIDKey): @(kMFRingTB800ProductID),
        @(kIOHIDDeviceUsagePageKey): @(kHIDPage_GenericDesktop),
        @(kIOHIDDeviceUsageKey): @(kHIDUsage_GD_Mouse),
    };
    NSArray *elementMatches = @[
        @{
            @(kIOHIDElementUsagePageKey): @(kHIDPage_GenericDesktop),
            @(kIOHIDElementUsageKey): @(kHIDUsage_GD_Wheel),
        },
        @{
            @(kIOHIDElementUsagePageKey): @(kHIDPage_Consumer),
            @(kIOHIDElementUsageKey): @(kHIDUsage_Csmr_ACPan),
        },
    ];

    IOHIDManagerSetDeviceMatching(
        _ringHIDManager, (__bridge CFDictionaryRef)deviceMatch);
    IOHIDManagerSetInputValueMatchingMultiple(
        _ringHIDManager, (__bridge CFArrayRef)elementMatches);
    IOHIDManagerRegisterDeviceMatchingCallback(
        _ringHIDManager, ringHandleDeviceMatching, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(
        _ringHIDManager, ringHandleDeviceRemoval, NULL);
    IOHIDManagerRegisterInputValueCallback(
        _ringHIDManager, ringHandleInputValue, NULL);
    IOHIDManagerScheduleWithRunLoop(
        _ringHIDManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);

    /// This is explicitly non-seizing. The native driver, ball, and buttons
    /// remain available to WindowServer and every other client.
    IOReturn openResult = IOHIDManagerOpen(
        _ringHIDManager, kIOHIDOptionsTypeNone);
    DDLogInfo("MFSCROLL_RING_HID: version=%llu action=start option=non-seizing correlationWindowMs=%.1f result=%d role=observer outputAuthority=0",
              kMFRingInputTelemetryVersion,
              kMFRingCorrelationWindowSeconds * 1000.0,
              openResult);

    if (openResult != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(
            _ringHIDManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(_ringHIDManager);
        _ringHIDManager = NULL;
    }
}

+ (void)stopObserving {
    if (_ringHIDManager == NULL) return;

    IOHIDManagerUnscheduleFromRunLoop(
        _ringHIDManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn closeResult = IOHIDManagerClose(
        _ringHIDManager, kIOHIDOptionsTypeNone);
    CFRelease(_ringHIDManager);
    _ringHIDManager = NULL;
    atomic_store_explicit(
        &_ringAttachedTargetCount, 0, memory_order_release);

    os_unfair_lock_lock(&_ringBufferLock);
    MFRingInputBufferInitialize(&_ringInputBuffer);
    _ringGeneration += 1;
    uint64_t generation = _ringGeneration;
    os_unfair_lock_unlock(&_ringBufferLock);

    DDLogInfo("MFSCROLL_RING_HID: version=%llu action=stop generation=%llu result=%d role=observer outputAuthority=0",
              kMFRingInputTelemetryVersion,
              generation,
              closeResult);
}

+ (BOOL)hasAttachedTarget {
    return atomic_load_explicit(
        &_ringAttachedTargetCount, memory_order_acquire) > 0;
}

+ (MFRingCGObservation)observeCGEventAtTimestamp:(CFTimeInterval)timestamp
                                    sendingDevice:(IOHIDDeviceRef)sendingDevice
                                             axis:(MFRingAxis)axis
                                      cgLineUnits:(int64_t)cgLineUnits
                                  cgFallbackUnits:(int64_t)cgFallbackUnits {
    MFRingCGObservation observation = { 0 };
    if (!ringIsTargetDevice(sendingDevice)) {
        return observation;
    }

    uint64_t registryID = ringRegistryID(sendingDevice);
    observation.isTargetDevice = true;

    os_unfair_lock_lock(&_ringBufferLock);
    observation.sequence = ++_ringCGSequence;
    observation.generation = _ringGeneration;
    observation.correlation = MFRingInputBufferCorrelate(
        &_ringInputBuffer,
        timestamp,
        registryID,
        axis,
        cgLineUnits,
        cgFallbackUnits,
        kMFRingCorrelationWindowSeconds,
        kMFRingMaximumFutureSkewSeconds);
    os_unfair_lock_unlock(&_ringBufferLock);
    return observation;
}

@end
