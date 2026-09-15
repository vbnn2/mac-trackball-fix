//
// --------------------------------------------------------------------------
// RingScrollRenderer.m
// Display-paced output owner for the TB800 free-rotating scroll ring.
// --------------------------------------------------------------------------
//

#import "RingScrollRenderer.h"

#import "SubPixelator.h"
#import "Logging.h"

#import <stdatomic.h>

static const CFTimeInterval kMFRingColdStartWatchdogDelay = 0.110;
static const NSUInteger kMFRingColdStartWatchdogMaxAttempts = 3;
static const CFTimeInterval kMFRingMaximumLiveFrameGap = 0.100;
static const NSUInteger kMFRingPendingLatencyCapacity = 64;

typedef struct {
    uint64_t sequence;
    MFRingAxis axis;
    CFTimeInterval inputTimestamp;
    double inputQueueDelayMs;
} MFRingPendingLatency;

@implementation RingScrollRenderer {
    DisplayLink *_displayLink;
    SubPixelator *_verticalPixelator;
    SubPixelator *_horizontalPixelator;
    MFRingMotionPlane _plane;
    BOOL _stateInitialized;
    atomic_uint_fast64_t _requestedGeneration;

    MFRingScrollRendererOutput _output;
    CGDirectDisplayID _displayID;
    CFTimeInterval _lastFrameTimestamp;
    BOOL _awaitingFirstCallback;
    BOOL _hasPostedOutput;
    MFRingAxis _pendingOutputSubpixelResetAxes;
    uint64_t _watchdogGeneration;

    MFRingPendingLatency _pendingLatency[kMFRingPendingLatencyCapacity];
    NSUInteger _pendingLatencyCount;

    CFTimeInterval _frameWindowStart;
    CFTimeInterval _frameWindowLastTimestamp;
    NSUInteger _frameWindowCallbackCount;
    NSUInteger _frameWindowNonzeroEventCount;
    double _frameWindowIntervalSum;
    double _frameWindowMaximumGap;
    int64_t _frameWindowSignedOutputPixels;
    int64_t _frameWindowAbsoluteOutputPixels;
    double _frameWindowPeakVelocity;
    int64_t _frameWindowVerticalOutputPixels;
    int64_t _frameWindowHorizontalOutputPixels;
    NSUInteger _frameWindowVerticalEventCount;
    NSUInteger _frameWindowHorizontalEventCount;
}

- (instancetype)initWithDisplayLink:(DisplayLink *)displayLink {
    self = [super init];
    if (self) {
        _displayLink = displayLink;
        _verticalPixelator = [SubPixelator biasedPixelator];
        _horizontalPixelator = [SubPixelator biasedPixelator];
        atomic_init(&_requestedGeneration, 1);
        MFRingMotionPlaneInitialize(&_plane, 1);
        _stateInitialized = YES;
    }
    return self;
}

- (void)clearFrameWindow_Unsafe {
    _frameWindowStart = 0;
    _frameWindowLastTimestamp = 0;
    _frameWindowCallbackCount = 0;
    _frameWindowNonzeroEventCount = 0;
    _frameWindowIntervalSum = 0;
    _frameWindowMaximumGap = 0;
    _frameWindowSignedOutputPixels = 0;
    _frameWindowAbsoluteOutputPixels = 0;
    _frameWindowPeakVelocity = 0;
    _frameWindowVerticalOutputPixels = 0;
    _frameWindowHorizontalOutputPixels = 0;
    _frameWindowVerticalEventCount = 0;
    _frameWindowHorizontalEventCount = 0;
}

- (void)flushFrameWindow_UnsafeWithAction:(NSString *)action {
    if (_frameWindowCallbackCount == 0) return;

    double frameHz = _frameWindowIntervalSum > 0
        ? (double)(_frameWindowCallbackCount - 1) / _frameWindowIntervalSum
        : 0;
    double nonzeroEventHz = _frameWindowIntervalSum > 0
        ? (double)_frameWindowNonzeroEventCount / _frameWindowIntervalSum
        : 0;
    NSString *axisName = _frameWindowVerticalEventCount > 0
        && _frameWindowHorizontalEventCount > 0
        ? @"mixed"
        : _frameWindowHorizontalEventCount > 0
        ? @"horizontal"
        : @"vertical";
    DDLogInfo("MFSCROLL_RING_FRAME: engineVersion=1 engine=ring-live action=%{public}@ generation=%llu axis=%{public}@ display=%u frameHz=%.3f maxFrameGapMs=%.3f nonzeroEventHz=%.3f callbacks=%lu events=%lu verticalEvents=%lu horizontalEvents=%lu signedOutputPx=%lld absoluteOutputPx=%lld verticalOutputPx=%lld horizontalOutputPx=%lld peakVelocity=%.3f remainingPxAtEnd=%.3f verticalRemainingPx=%.3f horizontalRemainingPx=%.3f legacyAuthoritative=0",
              action,
              _plane.generation,
              axisName,
              _displayID,
              frameHz,
              _frameWindowMaximumGap * 1000.0,
              nonzeroEventHz,
              (unsigned long)_frameWindowCallbackCount,
              (unsigned long)_frameWindowNonzeroEventCount,
              (unsigned long)_frameWindowVerticalEventCount,
              (unsigned long)_frameWindowHorizontalEventCount,
              _frameWindowSignedOutputPixels,
              _frameWindowAbsoluteOutputPixels,
              _frameWindowVerticalOutputPixels,
              _frameWindowHorizontalOutputPixels,
              _frameWindowPeakVelocity,
              MFRingMotionPlaneRemainingDistance(&_plane),
              MFRingMotionRemainingDistance(&_plane.vertical),
              MFRingMotionRemainingDistance(&_plane.horizontal));
    [self clearFrameWindow_Unsafe];
}

- (void)clearMotion_UnsafeForGeneration:(uint64_t)generation {
    MFRingMotionPlaneReset(&_plane, generation);
    _stateInitialized = YES;
    [_verticalPixelator reset];
    [_horizontalPixelator reset];
    _output = nil;
    _lastFrameTimestamp = 0;
    _awaitingFirstCallback = NO;
    _hasPostedOutput = NO;
    _pendingOutputSubpixelResetAxes = kMFRingAxisNone;
    _pendingLatencyCount = 0;
    _watchdogGeneration += 1;
}

- (void)resetToGeneration:(uint64_t)generation reason:(NSString *)reason {
    atomic_store_explicit(
        &_requestedGeneration, generation, memory_order_release);
    NSString *reasonSnapshot = [reason copy];
    dispatch_async(_displayLink.dispatchQueue, ^{
        [self flushFrameWindow_UnsafeWithAction:@"reset"];
        [_displayLink stop_Unsafe];
        [self clearMotion_UnsafeForGeneration:generation];
        DDLogInfo("MFSCROLL_RING_MODEL: engineVersion=1 engine=ring-live action=reset generation=%llu reason=%{public}@ legacyAuthoritative=0",
                  generation,
                  reasonSnapshot);
    });
}

- (void)recordPendingLatency_UnsafeWithSequence:(uint64_t)sequence
                                           axis:(MFRingAxis)axis
                                      timestamp:(CFTimeInterval)timestamp
                                   inputQueueMs:(double)inputQueueDelayMs {
    if (_pendingLatencyCount == kMFRingPendingLatencyCapacity) {
        DDLogInfo("MFSCROLL_RING_RENDERER: engineVersion=1 engine=ring-live action=latency-overflow generation=%llu droppedSequence=%llu capacity=%lu",
                  _plane.generation,
                  _pendingLatency[0].sequence,
                  (unsigned long)kMFRingPendingLatencyCapacity);
        memmove(&_pendingLatency[0],
                &_pendingLatency[1],
                sizeof(_pendingLatency[0])
                    * (kMFRingPendingLatencyCapacity - 1));
        _pendingLatencyCount -= 1;
    }
    _pendingLatency[_pendingLatencyCount++] = (MFRingPendingLatency) {
        .sequence = sequence,
        .axis = axis,
        .inputTimestamp = timestamp,
        .inputQueueDelayMs = inputQueueDelayMs,
    };
}

- (void)recordPendingLatenciesAtFirstOutput_UnsafeForVertical:(BOOL)verticalOutput
                                                   horizontal:(BOOL)horizontalOutput {
    CFTimeInterval now = CACurrentMediaTime();
    NSUInteger retainedCount = 0;
    for (NSUInteger index = 0; index < _pendingLatencyCount; index++) {
        MFRingPendingLatency pending = _pendingLatency[index];
        BOOL axisProducedOutput =
            (pending.axis == kMFRingAxisVertical && verticalOutput)
            || (pending.axis == kMFRingAxisHorizontal && horizontalOutput);
        if (!axisProducedOutput) {
            _pendingLatency[retainedCount++] = pending;
            continue;
        }
        NSString *axisName = pending.axis == kMFRingAxisHorizontal
            ? @"horizontal" : @"vertical";
        DDLogInfo("MFSCROLL_LATENCY: inputToFirstOutputMs=%.2f inputQueueMs=%.2f path=ring-live axis=%{public}@ sequence=%llu generation=%llu",
                  MAX(0.0, (now - pending.inputTimestamp) * 1000.0),
                  pending.inputQueueDelayMs,
                  axisName,
                  pending.sequence,
                  _plane.generation);
    }
    _pendingLatencyCount = retainedCount;
}

- (void)cancelPendingLatencies_UnsafeForAxis:(MFRingAxis)axis {
    NSUInteger retainedCount = 0;
    NSUInteger canceledCount = 0;
    for (NSUInteger index = 0; index < _pendingLatencyCount; index++) {
        MFRingPendingLatency pending = _pendingLatency[index];
        if (pending.axis == axis) {
            canceledCount += 1;
        } else {
            _pendingLatency[retainedCount++] = pending;
        }
    }
    _pendingLatencyCount = retainedCount;
    if (canceledCount > 0) {
        NSString *axisName = axis == kMFRingAxisHorizontal
            ? @"horizontal" : @"vertical";
        DDLogInfo("MFSCROLL_RING_RENDERER: engineVersion=1 engine=ring-live action=cancel-pending-on-reversal generation=%llu axis=%{public}@ count=%lu",
                  _plane.generation,
                  axisName,
                  (unsigned long)canceledCount);
    }
}

- (void)startDisplayLink_Unsafe {
    __weak RingScrollRenderer *weakSelf = self;
    [_displayLink start_UnsafeWithCallback:^(DisplayLinkCallbackTimeInfo timeInfo) {
        [weakSelf displayLinkCallback_Unsafe:timeInfo];
    }];
}

- (void)scheduleColdStartWatchdog_UnsafeForGeneration:(uint64_t)generation
                                     watchdogGeneration:(uint64_t)watchdogGeneration
                                                attempt:(NSUInteger)attempt {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(kMFRingColdStartWatchdogDelay * NSEC_PER_SEC)),
        _displayLink.dispatchQueue,
        ^{
            if (generation != atomic_load_explicit(
                    &_requestedGeneration, memory_order_acquire)
                || watchdogGeneration != _watchdogGeneration
                || !_awaitingFirstCallback
                || ![_displayLink isRunning_Unsafe]
                || ![_displayLink invalidateIfStalled_Unsafe]) {
                return;
            }

            if (attempt <= kMFRingColdStartWatchdogMaxAttempts) {
                DDLogInfo("MFSCROLL_DISPLAY: action=ring-watchdog-cold-restart attempt=%lu generation=%llu",
                          (unsigned long)attempt,
                          generation);
                [self startDisplayLink_Unsafe];
                [self scheduleColdStartWatchdog_UnsafeForGeneration:generation
                                                  watchdogGeneration:watchdogGeneration
                                                             attempt:attempt + 1];
                return;
            }

            [self flushFrameWindow_UnsafeWithAction:@"cold-abort"];
            [self clearMotion_UnsafeForGeneration:generation];
            DDLogInfo("MFSCROLL_DISPLAY: action=ring-watchdog-cold-abort attempts=%lu generation=%llu",
                      (unsigned long)kMFRingColdStartWatchdogMaxAttempts,
                      generation);
        });
}

- (void)armColdStartWatchdog_UnsafeForGeneration:(uint64_t)generation {
    _watchdogGeneration += 1;
    [self scheduleColdStartWatchdog_UnsafeForGeneration:generation
                                      watchdogGeneration:_watchdogGeneration
                                                 attempt:1];
}

- (void)enqueueReportWithSequence:(uint64_t)sequence
                       generation:(uint64_t)generation
                             axis:(MFRingAxis)axis
                         timestamp:(CFTimeInterval)timestamp
                       signedUnits:(int64_t)signedUnits
                        sourceName:(NSString *)sourceName
                 inputQueueDelayMs:(double)inputQueueDelayMs
                         displayID:(CGDirectDisplayID)displayID
                            config:(MFRingMotionConfig)config
                            output:(MFRingScrollRendererOutput)output {
    NSString *sourceSnapshot = [sourceName copy];
    MFRingScrollRendererOutput outputSnapshot = [output copy];

    /// Both operations target the same serial queue. Rebinding is therefore
    /// complete before the report can request a cold start.
    [_displayLink linkToDisplay:displayID];
    dispatch_async(_displayLink.dispatchQueue, ^{
        uint64_t requestedGeneration = atomic_load_explicit(
            &_requestedGeneration, memory_order_acquire);
        if (generation != requestedGeneration) {
            DDLogInfo("MFSCROLL_RING_MODEL: engineVersion=1 engine=ring-live action=reject sequence=%llu generation=%llu requestedGeneration=%llu staleGeneration=1 invalidTimestamp=0 legacyAuthoritative=0",
                      sequence,
                      generation,
                      requestedGeneration);
            return;
        }

        if (!_stateInitialized || _plane.generation != generation) {
            [self clearMotion_UnsafeForGeneration:generation];
        }

        if (axis != kMFRingAxisVertical
            && axis != kMFRingAxisHorizontal) {
            DDLogInfo("MFSCROLL_RING_MODEL: engineVersion=1 engine=ring-live action=reject sequence=%llu generation=%llu reason=invalid-axis axis=%ld legacyAuthoritative=0",
                      sequence,
                      generation,
                      (long)axis);
            return;
        }
        /// Requested-running is not proof of live callbacks. Discard old
        /// motion before applying the current report so a parked tail cannot
        /// be replayed into the new physical start.
        BOOL recoveredStalledLink = [_displayLink invalidateIfStalled_Unsafe];
        if (recoveredStalledLink) {
            [self flushFrameWindow_UnsafeWithAction:@"recover-stall"];
            [self clearMotion_UnsafeForGeneration:generation];
            DDLogInfo("MFSCROLL_RING_RENDERER: engineVersion=1 engine=ring-live action=recover-stall-discard generation=%llu sequence=%llu",
                      generation,
                      sequence);
        }

        MFRingMotionUpdate update = MFRingMotionPlaneApplyReport(
            &config,
            &_plane,
            axis,
            (MFRingMotionReport) {
                .generation = generation,
                .timestamp = timestamp,
                .signedUnits = signedUnits,
            });
        if (!update.accepted) {
            DDLogInfo("MFSCROLL_RING_MODEL: engineVersion=1 engine=ring-live action=reject sequence=%llu generation=%llu staleGeneration=%d invalidTimestamp=%d legacyAuthoritative=0",
                      sequence,
                      generation,
                      update.staleGeneration,
                      update.invalidTimestamp);
            return;
        }

        if (update.directionChanged) {
            /// Each physical wheel owns its velocity, cadence, rounding, and
            /// pending latency. A reversal cancels only that wheel; the other
            /// can continue on the same frame clock.
            SubPixelator *axisPixelator = axis == kMFRingAxisVertical
                ? _verticalPixelator : _horizontalPixelator;
            [axisPixelator reset];
            _pendingOutputSubpixelResetAxes |= axis;
            [self cancelPendingLatencies_UnsafeForAxis:axis];
        }

        _output = outputSnapshot;
        _displayID = displayID;
        [self recordPendingLatency_UnsafeWithSequence:sequence
                                                axis:axis
                                           timestamp:timestamp
                                        inputQueueMs:inputQueueDelayMs];

        NSString *axisName = axis == kMFRingAxisVertical
            ? @"vertical" : @"horizontal";
        DDLogInfo("MFSCROLL_RING_MODEL: engineVersion=1 engine=ring-live sequence=%llu generation=%llu source=%{public}@ axis=%{public}@ direction=%d directionChanged=%d units=%lld queueMs=%.3f dtMs=%.3f rawOmega=%.3f filteredOmega=%.3f cadenceMs=%.3f cadenceConfidence=%.3f pxPerUnit=%.3f tauMs=%.3f responsivenessDecayLimited=%d startsFromStoppedOutput=%d stoppedOpeningResponsivenessDecayLimited=%d stoppedOpeningVelocityDecayLimited=%d velocityBefore=%.3f carriedVelocity=%.3f impulseVelocity=%.3f velocityAfter=%.3f remainingPx=%.3f velocityLimited=%d carryDroppedPx=%.3f legacyAuthoritative=0",
                  sequence,
                  generation,
                  sourceSnapshot,
                  axisName,
                  signedUnits > 0 ? 1 : -1,
                  update.directionChanged,
                  signedUnits,
                  inputQueueDelayMs,
                  isfinite(update.reportIntervalSeconds)
                      ? update.reportIntervalSeconds * 1000.0 : -1.0,
                  update.rawSpeedUnitsPerSecond,
                  update.filteredSpeedUnitsPerSecond,
                  update.cadenceEstimateSeconds * 1000.0,
                  update.cadenceConfidence,
                  update.pixelsPerUnit,
                  update.decaySeconds * 1000.0,
                  update.responsivenessDecayLimited,
                  update.startsFromStoppedOutput,
                  update.stoppedOpeningResponsivenessDecayLimited,
                  update.stoppedOpeningVelocityDecayLimited,
                  update.velocityBeforePixelsPerSecond,
                  update.carriedVelocityPixelsPerSecond,
                  update.impulseVelocityPixelsPerSecond,
                  update.velocityAfterPixelsPerSecond,
                  update.remainingDistancePixels,
                  update.velocityLimited,
                  update.carryDroppedPixels);
        if (update.lowSpeedReversalFrequencyPreserved) {
            DDLogInfo("MFSCROLL_RING_FREQUENCY: engine=ring-live sequence=%llu generation=%llu axis=%{public}@ action=preserve-slow-reversal rawOmega=%.3f filteredOmega=%.3f cadenceMs=%.3f",
                      sequence, generation, axisName, update.rawSpeedUnitsPerSecond,
                      update.filteredSpeedUnitsPerSecond,
                      update.cadenceEstimateSeconds * 1000.0);
        }
        if (update.continuityOpeningDecayLimited) {
            DDLogInfo("MFSCROLL_RING_OPENING: sequence=%llu continuityDecayLimited=1 tauMs=%.3f velocityAfter=%.3f",
                      sequence, update.decaySeconds * 1000.0,
                      update.velocityAfterPixelsPerSecond);
        }
        if (update.stoppedOpeningDistanceRaised) {
            DDLogInfo("MFSCROLL_RING_OPENING: sequence=%llu stoppedOpeningDistanceRaised=1 pxPerUnit=%.3f tauMs=%.3f",
                      sequence, update.pixelsPerUnit, update.decaySeconds * 1000.0);
        }

        if (![_displayLink isRunning_Unsafe]) {
            _awaitingFirstCallback = YES;
            _lastFrameTimestamp = 0;
            [self startDisplayLink_Unsafe];
            [self armColdStartWatchdog_UnsafeForGeneration:generation];
        }
    });
}

- (void)displayLinkCallback_Unsafe:(DisplayLinkCallbackTimeInfo)timeInfo {
    uint64_t requestedGeneration = atomic_load_explicit(
        &_requestedGeneration, memory_order_acquire);
    if (!_stateInitialized
        || requestedGeneration != _plane.generation
        || ![_displayLink isRunning_Unsafe]) {
        return;
    }

    BOOL isFirstCallback = _awaitingFirstCallback || _lastFrameTimestamp <= 0;
    CFTimeInterval frameInterval = isFirstCallback
        ? timeInfo.nominalTimeBetweenFrames
        : timeInfo.outFrame - _lastFrameTimestamp;
    if (!isfinite(frameInterval) || frameInterval <= 0) {
        DDLogInfo("MFSCROLL_RING_RENDERER: engineVersion=1 engine=ring-live action=drop-frame reason=invalid-interval generation=%llu intervalMs=%.3f",
                  _plane.generation,
                  frameInterval * 1000.0);
        return;
    }

    if (!isFirstCallback && frameInterval > kMFRingMaximumLiveFrameGap) {
        /// Integrating a parked interval into one event would replay the whole
        /// bounded tail as a secondary burst. End this old session instead.
        DDLogInfo("MFSCROLL_RING_RENDERER: engineVersion=1 engine=ring-live action=parked-frame-discard generation=%llu gapMs=%.3f remainingPx=%.3f",
                  _plane.generation,
                  frameInterval * 1000.0,
                  MFRingMotionPlaneRemainingDistance(&_plane));
        [self flushFrameWindow_UnsafeWithAction:@"parked-discard"];
        uint64_t generation = _plane.generation;
        [_displayLink stop_Unsafe];
        [self clearMotion_UnsafeForGeneration:generation];
        return;
    }

    _awaitingFirstCallback = NO;
    _watchdogGeneration += 1;
    _lastFrameTimestamp = timeInfo.outFrame;

    MFRingMotionPlaneFrame frame = MFRingMotionPlaneAdvance(
        &_plane, frameInterval);
    if (!frame.accepted) {
        DDLogInfo("MFSCROLL_RING_RENDERER: engineVersion=1 engine=ring-live action=drop-frame reason=model-reject generation=%llu intervalMs=%.3f",
                  _plane.generation,
                  frameInterval * 1000.0);
        return;
    }

    if (_frameWindowStart <= 0) {
        _frameWindowStart = timeInfo.outFrame;
    }
    if (_frameWindowLastTimestamp > 0) {
        _frameWindowIntervalSum += frameInterval;
        _frameWindowMaximumGap = MAX(_frameWindowMaximumGap, frameInterval);
    }
    _frameWindowLastTimestamp = timeInfo.outFrame;
    _frameWindowCallbackCount += 1;
    _frameWindowPeakVelocity = MAX(
        _frameWindowPeakVelocity,
        hypot(frame.horizontal.velocityAfterPixelsPerSecond,
              frame.vertical.velocityAfterPixelsPerSecond));

    int64_t verticalPixels = (int64_t)[_verticalPixelator
        intDeltaWithDoubleDelta:frame.vertical.distancePixels];
    int64_t horizontalPixels = (int64_t)[_horizontalPixelator
        intDeltaWithDoubleDelta:frame.horizontal.distancePixels];
    if (verticalPixels != 0 || horizontalPixels != 0) {
        if (requestedGeneration != atomic_load_explicit(
                &_requestedGeneration, memory_order_acquire)) {
            return;
        }
        BOOL startsOutput = !_hasPostedOutput;
        _hasPostedOutput = YES;
        [self recordPendingLatenciesAtFirstOutput_UnsafeForVertical:
            verticalPixels != 0 horizontal:horizontalPixels != 0];
        _frameWindowNonzeroEventCount += 1;
        _frameWindowSignedOutputPixels += verticalPixels + horizontalPixels;
        _frameWindowAbsoluteOutputPixels += llabs(verticalPixels)
            + llabs(horizontalPixels);
        _frameWindowVerticalOutputPixels += verticalPixels;
        _frameWindowHorizontalOutputPixels += horizontalPixels;
        if (verticalPixels != 0) _frameWindowVerticalEventCount += 1;
        if (horizontalPixels != 0) _frameWindowHorizontalEventCount += 1;
        if (_output != nil) {
            MFRingAxis resetAxes = _pendingOutputSubpixelResetAxes;
            _pendingOutputSubpixelResetAxes = kMFRingAxisNone;
            _output(horizontalPixels, verticalPixels, resetAxes, startsOutput);
        }
    }

    if (timeInfo.outFrame - _frameWindowStart >= 0.25) {
        [self flushFrameWindow_UnsafeWithAction:@"window"];
    }

    double verticalSignedRemaining = copysign(
        frame.vertical.remainingDistancePixels,
        frame.vertical.velocityAfterPixelsPerSecond);
    double horizontalSignedRemaining = copysign(
        frame.horizontal.remainingDistancePixels,
        frame.horizontal.velocityAfterPixelsPerSecond);
    double futureVerticalPixels = [_verticalPixelator
        peekIntDeltaWithDoubleDelta:verticalSignedRemaining];
    double futureHorizontalPixels = [_horizontalPixelator
        peekIntDeltaWithDoubleDelta:horizontalSignedRemaining];
    BOOL verticalStopped = fabs(frame.vertical.velocityAfterPixelsPerSecond)
            <= MFRingMotionStopVelocityPixelsPerSecond()
        && futureVerticalPixels == 0;
    BOOL horizontalStopped = fabs(frame.horizontal.velocityAfterPixelsPerSecond)
            <= MFRingMotionStopVelocityPixelsPerSecond()
        && futureHorizontalPixels == 0;
    if (verticalStopped && horizontalStopped) {
        [self flushFrameWindow_UnsafeWithAction:@"stop"];
        [_displayLink stop_Unsafe];
        _lastFrameTimestamp = 0;
        _hasPostedOutput = NO;
        _pendingLatencyCount = 0;
        _watchdogGeneration += 1;
    }
}

@end
