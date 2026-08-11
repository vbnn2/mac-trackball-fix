//
// --------------------------------------------------------------------------
// ScrollControl.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import "Scroll.h"
#import "DeviceManager.h"
#import "TouchSimulator.h"
#import "ScrollModifiers.h"
#import "Config.h"
#import "ScrollUtility.h"
#import "VectorUtility.h"
#import "HelperUtility.h"
#import "ScrollAnalyzer.h"
#import "ScrollConfigObjC.h"
#import <Cocoa/Cocoa.h>
#import "Queue.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"
#import "SubPixelator.h"
#import "GestureScrollSimulator.h"
#import "SharedUtility.h"
#import "ScrollModifiers.h"
#import "Actions.h"
#import "EventUtility.h"
#import "MathObjc.h"
#import "ScrollCadencePolicy.h"
#import "ScrollOutputPolicy.h"
#import "ScrollSyntheticEvent.h"
#import <stdatomic.h>
#import <os/lock.h>

@import IOKit;
#import "MFHIDEventImports.h"
#import "IOUtility.h"

///
/// There are issues where scrolling stops working intermittently or after a restart [Apr 8 2025]
///     See this note on the issue: https://github.com/noah-nuebling/notes-public/blob/23361f16a315f48f1f6278161b8cefab50fc3665/mmf/bug-investigation/scrolling-stops-intermittently_apr-2025.md
///

@implementation Scroll

#pragma mark - Variables - static

static CFMachPortRef _eventTap;
/// `CGEventTapEnable(false)` itself produces `kCGEventTapDisabledByUserInput` on this macOS build. Track the state
/// requested by SwitchMaster separately so the disabled callback cannot undo a deliberate shutdown.
static atomic_bool _eventTapShouldBeEnabled = false;
static CGEventSourceRef _eventSource;

static dispatch_queue_t _scrollQueue;

static TouchAnimator *_animator;

static AXUIElementRef _systemWideAXUIElement; // TODO: should probably move this to Config or some sort of OverrideManager class
+ (AXUIElementRef) systemWideAXUIElement {
    return _systemWideAXUIElement;
}

#pragma mark - Variables - dynamic

static MFScrollModificationResult _modifications;
static BOOL _modificationUsageNotified;
static ScrollConfig *_scrollConfig;
static MFScrollAnimationCurveParameters *_animationParams;
static ScrollAnalysisResult _lastScrollAnalysisResult;
static CFTimeInterval _lastScrollAnalysisResultTimeStamp;
/// Physical wheel gaps normally use the preceding event. Before the first event, helper uptime is the only measured
/// lower bound; recording it lets a real >20s first-use idle arm wake shaping without treating an unknown sentinel
/// as infinite idle.
static CFTimeInterval _scrollInputObservationStartTime;
static CFTimeInterval _previousPhysicalScrollInputTime;

/// Slow trackball motion can place more than the normal 500ms gesture timeout between reports. Keep cadence memory
/// separate from ScrollAnalyzer's gesture grouping so those reports can still form one visually continuous motion.
/// Explicit state resets (click, app change, config/modifier change) clear this memory.
static CFTimeInterval _stableSlowCadenceEstimate;
static double _stablePreviousModeledOutputSpeed;
/// Sparse cadence may bootstrap only from an immediately preceding accepted report that
/// was itself genuine low-unit, low-speed motion. Modeled speed alone is insufficient:
/// a decelerated multi-unit report can be slow numerically while still ending a fast spin.
static BOOL _stablePreviousReportCanSeedSlowCadence;
/// The capture can begin with a short one-unit hardware ramp after at least 20 seconds without wheel input. Preserve
/// the opening report's time and preceding idle gap so later reports in that same sub-second ramp retain the
/// ordinary opening-duration cap. After that measured interval, fade the cap continuously instead of jumping
/// straight to maximum Slow Smoothness.
static CFTimeInterval _stableIdleWakeOpeningTime;
static CFTimeInterval _stableIdleWakeOpeningGap;

/// A fast free-spin can be followed by one mechanical one-unit report after the intended motion has ended. Keep
/// this guard outside ScrollAnalyzer so an unconfirmed rebound cannot change cadence or direction history.
static BOOL _stableSettlingTailGuardArmed;
static MFDirection _stableSettlingTailDirection;
static CFTimeInterval _stableSettlingTailLastFastInputTime;
/// These belong to the scroll session rather than a single acceleration branch. Keeping them with the rest of the
/// resettable state prevents a config/modifier/target reset from leaving the next gesture classified as an old tail.
static BOOL _stableGestureReachedFastSpeed;
static BOOL _stableFastTailReportHandled;
/// The first sparse report after a fast gesture is deliberately bounded because it may be mechanical settling.
/// Remember only whether that accepted response was the immediately preceding physical report. If it finishes before
/// a real continuation arrives, the continuation needs the bounded opening-duration cap instead of inheriting a
/// long slow response from motion that is no longer visible.
static BOOL _stableFastTailContinuationPending;
/// A very close deliberate reversal keeps slow cadence on its opening report. If that
/// response ends before the immediately following small continuation, cap that one
/// stopped restart to the adaptive opening envelope so it cannot become weaker than
/// the reversal that opened the new direction.
static BOOL _stableCloseReversalContinuationPending;

/// Zoom is one physical-input-owned magnification gesture, rather than one gesture per
/// animator curve. Keep its phase transitions serialized because physical input/reset runs
/// on `_scrollQueue` while animator output runs on the display-link queue.
static os_unfair_lock _zoomGestureLock = OS_UNFAIR_LOCK_INIT;
static BOOL _zoomGestureActive;
static uint64_t _zoomGestureGeneration;
static BOOL _zoomGestureNeedsKeyboardReleaseTracking;
static BOOL _zoomGestureNeedsChromiumOpeningImpulse;

//static BOOL _isSuspended = NO; TODO: Remove suspension stuff (already commented out)

/// Aggregate the events that actually reach applications. The animator can be display-synchronized while integer
/// pixel quantization still skips output frames, so input/curve telemetry alone cannot prove visible cadence.
/// TouchAnimator invokes this callback on its display-link queue.
static CFTimeInterval _legacyOutputWindowStart;
static CFTimeInterval _legacyLastOutputTime;
static NSUInteger _legacyOutputEventCount;
static NSUInteger _legacyOutputIntervalCount;
static CFTimeInterval _legacyOutputIntervalSum;
static CFTimeInterval _legacyOutputMaxGap;
static int64_t _legacyOutputPixelSum;

static void legacyRecordOutput(int64_t px, MFDirection direction) {
    if (px <= 0) return;

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval gap = _legacyLastOutputTime > 0 ? now - _legacyLastOutputTime : 0;

    if (_legacyOutputWindowStart == 0 || gap > 0.5) {
        _legacyOutputWindowStart = now;
        _legacyOutputEventCount = 0;
        _legacyOutputIntervalCount = 0;
        _legacyOutputIntervalSum = 0;
        _legacyOutputMaxGap = 0;
        _legacyOutputPixelSum = 0;
        gap = 0;
    }

    if (gap > 0) {
        _legacyOutputIntervalCount += 1;
        _legacyOutputIntervalSum += gap;
        _legacyOutputMaxGap = MAX(_legacyOutputMaxGap, gap);
    }

    _legacyLastOutputTime = now;
    _legacyOutputEventCount += 1;
    _legacyOutputPixelSum += px;

    CFTimeInterval windowDuration = now - _legacyOutputWindowStart;
    if (windowDuration >= 0.25) {
        double eventHz = _legacyOutputIntervalSum > 0
            ? (double)_legacyOutputIntervalCount / _legacyOutputIntervalSum
            : 0;
        double outputSpeed = (double)_legacyOutputPixelSum / windowDuration;
        DDLogInfo("MFSCROLL_OUTPUT: eventHz=%.1f maxGapMs=%.2f outputV=%.1f events=%lu outputPx=%lld direction=%ld",
                   eventHz,
                   _legacyOutputMaxGap * 1000.0,
                   outputSpeed,
                   (unsigned long)_legacyOutputEventCount,
                   _legacyOutputPixelSum,
                   (long)direction);

        _legacyOutputWindowStart = now;
        _legacyOutputEventCount = 0;
        _legacyOutputIntervalCount = 0;
        _legacyOutputIntervalSum = 0;
        _legacyOutputMaxGap = 0;
        _legacyOutputPixelSum = 0;
    }
}

static BOOL currentZoomTargetNeedsOpeningImpulse(void) {
    NSString *bundleID = [HelperUtility appUnderMousePointerWithEvent:NULL].bundleIdentifier;
    return bundleID != nil
        && ([bundleID containsString:@"com.google.Chrome"]
            || [bundleID containsString:@"org.chromium.Chromium"]
            || [bundleID containsString:@"company.thebrowser.Browser"] /// Arc
            || [bundleID containsString:@"com.operasoftware.Opera"]
            || [bundleID containsString:@"com.microsoft.edgemac"]
            || [bundleID containsString:@"com.vivaldi.Vivaldi"]
            || [bundleID containsString:@"com.brave.Browser"]);
}

static uint64_t beginZoomGesture_Unsafe(BOOL needsKeyboardReleaseTracking,
                                        BOOL needsChromiumOpeningImpulse) {
    BOOL shouldEnableKeyboardReleaseTracking = NO;
    os_unfair_lock_lock(&_zoomGestureLock);
    if (!_zoomGestureActive) {
        _zoomGestureGeneration += 1;
        _zoomGestureActive = YES;
        _zoomGestureNeedsKeyboardReleaseTracking = needsKeyboardReleaseTracking;
        _zoomGestureNeedsChromiumOpeningImpulse = needsChromiumOpeningImpulse;
        shouldEnableKeyboardReleaseTracking = needsKeyboardReleaseTracking;
        [TouchSimulator postMagnificationEventWithMagnification:0.0
                                                            phase:kIOHIDEventPhaseBegan];
        DDLogInfo("MFSCROLL_ZOOM: action=begin-on-input generation=%llu",
                  _zoomGestureGeneration);
    }
    uint64_t generation = _zoomGestureGeneration;
    os_unfair_lock_unlock(&_zoomGestureLock);
    if (shouldEnableKeyboardReleaseTracking) {
        [SwitchMaster.shared zoomGestureKeyboardReleaseTrackingChanged:YES];
    }
    return generation;
}

static BOOL endZoomGesture_Unsafe(NSString *reason) {
    BOOL shouldDisableKeyboardReleaseTracking = NO;
    BOOL didEnd = NO;
    os_unfair_lock_lock(&_zoomGestureLock);
    if (_zoomGestureActive) {
        [TouchSimulator postMagnificationEventWithMagnification:0.0
                                                            phase:kIOHIDEventPhaseEnded];
        _zoomGestureActive = NO;
        _zoomGestureGeneration += 1;
        shouldDisableKeyboardReleaseTracking = _zoomGestureNeedsKeyboardReleaseTracking;
        _zoomGestureNeedsKeyboardReleaseTracking = NO;
        _zoomGestureNeedsChromiumOpeningImpulse = NO;
        didEnd = YES;
        DDLogInfo("MFSCROLL_ZOOM: action=end reason=%{public}@ generation=%llu cancel-animator=1",
                  reason,
                  _zoomGestureGeneration);
    }
    os_unfair_lock_unlock(&_zoomGestureLock);
    if (shouldDisableKeyboardReleaseTracking) {
        [SwitchMaster.shared zoomGestureKeyboardReleaseTrackingChanged:NO];
    }
    /// Invalidate the generation and post End before cancellation. A queued display-link
    /// callback then cannot send another Changed frame, and no zoom tail can become the
    /// initial motion of the next ordinary scroll session.
    if (didEnd) {
        [_animator cancel];
    }
    return didEnd;
}

static void sendZoomChangeIfActive(double magnification, uint64_t generation) {
    os_unfair_lock_lock(&_zoomGestureLock);
    if (_zoomGestureActive && _zoomGestureGeneration == generation) {
        /// Chromium's ordinary page zoom ignores a very small opening pinch distance.
        /// Restore its old one-time distance impulse, but keep the new physical-input
        /// lifecycle: Began was already sent at wheel input, and this remains Changed.
        if (_zoomGestureNeedsChromiumOpeningImpulse && magnification != 0.0) {
            _zoomGestureNeedsChromiumOpeningImpulse = NO;
            magnification += mfsign(magnification) > 0 ? 380.0 / 800.0 : -250.0 / 800.0;
            DDLogInfo("MFSCROLL_ZOOM: action=chromium-opening-impulse generation=%llu",
                      _zoomGestureGeneration);
        }
        [TouchSimulator postMagnificationEventWithMagnification:magnification
                                                            phase:kIOHIDEventPhaseChanged];
    }
    os_unfair_lock_unlock(&_zoomGestureLock);
}

static void sendScroll(int64_t px, MFDirection scrollDirection, BOOL animated, MFAnimationCallbackPhase animationPhase, MFMomentumHint momentumHint, ScrollConfig *config, MFScrollModificationResult modifications, uint64_t zoomGestureGeneration);

/// Give an ambiguous one-unit settling report a visible but tightly bounded response. This deliberately bypasses
/// ScrollAnalyzer so a possible mechanical rebound cannot change cadence/direction history. The normal TouchAnimator
/// queue still makes a following real report cancel or retarget this motion immediately.
static void startSettlingTailMicroGlide(int64_t distance,
                                       MFDirection direction,
                                       CFTimeInterval inputTime,
                                       double inputQueueDelayMs,
                                       ScrollConfig *config,
                                       MFScrollModificationResult modifications) {
    ScrollConfig *configForBlock = config;
    MFScrollModificationResult modificationsForBlock = modifications;

    [_animator startWithParams:^NSDictionary<NSString *,id> * _Nonnull(Vector valueLeft,
                                                                        BOOL isRunning,
                                                                        Curve *animationCurve,
                                                                        Vector currentSpeed) {
        (void)valueLeft;
        (void)isRunning;
        (void)animationCurve;
        (void)currentSpeed;

        /// This is a standalone bounded response, never retained distance from the old gesture.
        [_animator resetSubPixelator_Unsafe];
        Bezier *curve = [[Bezier alloc] initWithControlPoints:@[
            @[@0, @0],
            @[@0.20, @0.50],
            @[@0.55, @0.90],
            @[@1, @1],
        ] defaultEpsilon:0.01];
        return @{
            @"duration": @(configForBlock.stableSettlingTailResponsiveDuration),
            @"vector": nsValueFromVector(vectorFromDeltaAndDirection(distance, direction)),
            @"curve": curve,
        };
    } integerCallback:^(Vector distanceDeltaVec,
                        MFAnimationCallbackPhase animationPhase,
                        MFMomentumHint momentumHint) {
        int64_t distanceDelta = (int64_t)magnitudeOfVector(distanceDeltaVec);
        if (animationPhase == kMFAnimationCallbackPhaseStart) {
            DDLogInfo("MFSCROLL_LATENCY: inputToFirstOutputMs=%.2f inputQueueMs=%.2f path=settling-micro-glide",
                       MAX(0.0, (CACurrentMediaTime() - inputTime) * 1000.0),
                       inputQueueDelayMs);
        }
        legacyRecordOutput(distanceDelta, direction);
        sendScroll(distanceDelta,
                   direction,
                   YES,
                   animationPhase,
                   momentumHint,
                   configForBlock,
                   modificationsForBlock,
                   0);
    }];
}

#pragma mark - Public functions

+ (void)load_Manual {
    
    /// Setup dispatch queue
    ///  For multithreading while still retaining control over execution order.
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, -1);
    _scrollQueue = dispatch_queue_create("com.nuebling.mac-mouse-fix.helper.scroll", attr);
    _scrollInputObservationStartTime = CACurrentMediaTime();
    _previousPhysicalScrollInputTime = 0;
    
    /// Create AXUIElement for getting app under mouse pointer
    _systemWideAXUIElement = AXUIElementCreateSystemWide();
    /// Create Event source
    if (_eventSource == NULL) {
        _eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    }
    
    /// Create/enable scrollwheel input callback
    if (_eventTap == NULL) {
        /// Mouse-down events are observed only to terminate an existing scroll gesture. Activating or moving a
        /// window starts with a click/drag; if the old gesture survives that interaction, some scroll views keep it
        /// associated with the previous target and ignore same-direction deltas until a reversal opens a new one.
        /// The button events themselves are always returned unmodified by eventTapCallback().
        CGEventMask mask = CGEventMaskBit(kCGEventScrollWheel)
            | CGEventMaskBit(kCGEventLeftMouseDown)
            | CGEventMaskBit(kCGEventRightMouseDown)
            | CGEventMaskBit(kCGEventOtherMouseDown);
        _eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, eventTapCallback, NULL);
        DDLogDebug("Scroll.m: _eventTap: %@", _eventTap);
        CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
        CFRelease(runLoopSource);
        CGEventTapEnable(_eventTap, false); // Not sure if this does anything
    }
    
    /// Create animator
    _animator = [[TouchAnimator alloc] init];

    /// Create initial config instance
    ///     Edit: I don't think this makes sense. `_scrollConfig` will be retrieved as necessary on first consecutive ticks
    _scrollConfig = nil; /// [[ScrollConfig alloc] init];
}

+ (void)resetState {
    dispatch_async(_scrollQueue, ^{
        resetState_Unsafe();
    });
}
void resetState_Sync(void) {
    
    /// TODO: I just saw a crash here where _scrollQueue was nil
    
    dispatch_sync(_scrollQueue, ^{
        resetState_Unsafe();
    });
}
void resetState_Unsafe(void) {
    DDLogDebug("Scroll.m: reset-animator");
    /// A zoom gesture is intentionally longer-lived than an individual animator response,
    /// but any explicit session reset still needs a terminal phase before stale callbacks are
    /// cancelled or a new target begins receiving input.
    if (!endZoomGesture_Unsafe(@"session-reset")) {
        [_animator cancel];
    }
    [GestureScrollSimulator stopMomentumScroll]; /// Not sure if appropriate
    /// Command-Tab owns a synthetic Command key-down outside TouchAnimator. Every
    /// session reset must release it, including modifier release when the scroll tap
    /// is disabled before another wheel report can arrive.
    [Scroll appSwitcherModificationHasBeenDeactivated];
    [ScrollAnalyzer resetState];
    _stableSlowCadenceEstimate = 0;
    _stablePreviousModeledOutputSpeed = 0;
    _stablePreviousReportCanSeedSlowCadence = NO;
    _stableIdleWakeOpeningTime = 0;
    _stableIdleWakeOpeningGap = 0;
    _stableSettlingTailGuardArmed = NO;
    _stableSettlingTailDirection = kMFDirectionNone;
    _stableSettlingTailLastFastInputTime = 0;
    _stableGestureReachedFastSpeed = NO;
    _stableFastTailReportHandled = NO;
    _stableFastTailContinuationPending = NO;
    _stableCloseReversalContinuationPending = NO;
}

+ (void)modifierStateDidChange:(MFScrollModificationResult)modifications {
    dispatch_async(_scrollQueue, ^{
        MFScrollModificationResult effectiveModifications = modifications;
        if (HelperState.shared.trackballModeIsActive) {
            effectiveModifications.effectMod = kMFScrollEffectModificationZoom;
        }

        if (![ScrollModifiers scrollModsAreEqual:effectiveModifications other:_modifications]) {
            _modificationUsageNotified = NO;
            DDLogInfo("MFSCROLL_CONFIG: action=modifier-callback oldInput=%ld oldEffect=%ld newInput=%ld newEffect=%ld reset-session=1",
                       (long)_modifications.inputMod,
                       (long)_modifications.effectMod,
                       (long)effectiveModifications.inputMod,
                       (long)effectiveModifications.effectMod);
            resetState_Unsafe();
            _modifications = effectiveModifications;
        }
    });
}

//+ (void)suspend {
//    /// Needs stop any output being generated by this class and *then* return
//    dispatch_sync(_scrollQueue, ^{
//        [_animator cancel];
//        _isSuspended = true;
//    });
//}

+ (void)startReceiving {
    
    
    /// Notes:
    /// - The switch Master will call this over and over again whenever it checks the current conditions and decides that scroll input should be intercepted. Therefore this should be eficient and do nothing if it's called while we're already intercepting scrolls.
    /// - We used to call `resetState` when starting/stopping, but this doesn't makes sense I think. Because we don't want to reset/cancel animations just because the interception of scrollwheel events stopped. Those things are logically separate.
    /// - We used to `dispatch_async` here because `resetState` should be synchronized on the scrollQueue (as evidenced by its base implementation being suffixed with `_Unsafe`). But since we're not calling `resetState` anymore, I don't think there's a reason to dispatch to the scrollQueue.
    /// - I did some rudimentary performance testing here (when we were still calling `resetState`) and it seems that `[Scroll startReceiving]` and `[Scroll stopReceiving]` have practically no impact on CPU usage even when spamming a button with such settings that SwitchMaster calls start/stop on each button press and release.

    
    /// DEBUG
    DDLogDebug("Scroll.m: startReceiving. isReceiving: %d", CGEventTapIsEnabled(_eventTap));

    /// Start event tap
    atomic_store_explicit(&_eventTapShouldBeEnabled, true, memory_order_release);
    if (!CGEventTapIsEnabled(_eventTap)) {
        CGEventTapEnable(_eventTap, true);
    }
    
}

+ (void)stopReceiving {
    
    /// Notes:
    /// - Are there other things we should enable/disable here? ScrollModifiers.reactToModiferChange() comes to mind
    /// - Also see notes for `- startReceiving`
    
    /// DEBUG
    DDLogDebug("Scroll.m: stopReceiving. isReceiving: %d", CGEventTapIsEnabled(_eventTap));
    
    
    /// Stop event tap
    atomic_store_explicit(&_eventTapShouldBeEnabled, false, memory_order_release);
    if (CGEventTapIsEnabled(_eventTap)) {
        CGEventTapEnable(_eventTap, false);
    }
}

+ (BOOL)isReceiving {
    /// At the time of writing we just need this for debugging. Should'nt ever need it for something else I think.
    return CGEventTapIsEnabled(_eventTap);
}

#pragma mark - Event tap

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"

static NSString *CGScrollWheelEventDescription(CGEventRef event) {
    
    /// Helper / debugging function
    /// TODO: Move this to another file (Don't forget the -Wunused-function warning ignore stuff above and below)
    
    double d            = CGEventGetDoubleValueField(event, kCGScrollWheelEventDeltaAxis1);
    double dPoint       = CGEventGetDoubleValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    double dFixed       = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1);
    double dContinuous  = CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
    double dCount       = CGEventGetDoubleValueField(event, kCGScrollWheelEventScrollCount);
    double dInstant     = CGEventGetDoubleValueField(event, kCGScrollWheelEventInstantMouser);
    double dPhase       = CGEventGetDoubleValueField(event, kCGScrollWheelEventScrollPhase);
    double dMomPhase    = CGEventGetDoubleValueField(event, kCGScrollWheelEventMomentumPhase);
    
    NSString *description = [NSString stringWithFormat:@"d: %f dPoint: %f dFixed: %f isContinuous: %f count: %f instant: %f phase: %f momPhase: %f", d, dPoint, dFixed, dContinuous, dCount, dInstant, dPhase, dMomPhase];
    
    return description;
}

#pragma clang diagnostic pop

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    
    
    /// Debug
    
//    DDLogDebug("Scroll.m: SCROOOL EVENT – %@", CGScrollWheelEventDescription(event));
    
    /// Handle eventTapDisabled messages
    
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {

        BOOL shouldBeEnabled = atomic_load_explicit(&_eventTapShouldBeEnabled, memory_order_acquire);
        DDLogInfo("MFSCROLL_TAP: action=%{public}@ reason=%{public}@ requestedEnabled=%d",
                   shouldBeEnabled ? @"re-enable" : @"keep-disabled",
                   type == kCGEventTapDisabledByTimeout ? @"timeout" : @"user-input",
                   shouldBeEnabled);

        /// Recover from a real timeout/user-input disable only while SwitchMaster still wants interception. A
        /// deliberate `stopReceiving` also generates this callback on macOS 26; unconditionally enabling here made
        /// the VS Code compatibility shutdown last only a few milliseconds.
        if (shouldBeEnabled) {
            CGEventTapEnable(_eventTap, true);
        }
        
        return event;
    }

    /// Our continuous/gesture output re-enters the HID tap by design so apps
    /// receive normal routing semantics. Pass it through before field decoding,
    /// target lookup, and raw-input telemetry. In the latest capture, these
    /// self-generated events were over 90% of tap traffic.
    if (type == kCGEventScrollWheel && MFScrollEventIsSynthetic(event)) {
        return event;
    }

    /// A click or drag changes which view owns the next scroll gesture, even when the frontmost bundle identifier
    /// stays the same. End the old session on the scroll queue, preserving event order with future wheel input, and
    /// pass the button event through untouched. This also mirrors trackpad behavior: pressing the pointer cancels
    /// any scroll momentum which was still active.
    if (type == kCGEventLeftMouseDown
        || type == kCGEventRightMouseDown
        || type == kCGEventOtherMouseDown) {
        int64_t buttonNumber = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) + 1;
        dispatch_async(_scrollQueue, ^{
            DDLogInfo("MFSCROLL_TARGET: mouse-down button=%lld action=reset-session",
                       buttonNumber);
            resetState_Unsafe();
        });
        return event;
    }

    /// Inspect physical scrollwheel events
    int64_t isPixelBased     = CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
    int64_t scrollPhase      = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
    int64_t scrollDeltaAxis1 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    int64_t scrollDeltaAxis2 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
    int64_t lineDeltaAxis1   = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    int64_t lineDeltaAxis2   = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
    /// ^ The *line* deltas, as opposed to the point deltas above. See `unitsForThisTick` in heavyProcessing() for
    ///     why we carry both: point delta is already accelerated by macOS and is not a usable unit count.
    int64_t drawingTabletID  = CGEventGetIntegerValueField(event, kCGTabletEventDeviceID);
    /// Unlike a bundle ID, the routing window distinguishes two windows belonging to the same application. Newer
    /// event paths may attach it directly. The TB800's HID-tap events on macOS 26 leave both fields at zero, so use
    /// the existing non-AX WindowServer point lookup for physical reports. A live 1,000-call benchmark measured
    /// about 37 microseconds per lookup, safely below the observed sub-4.3ms scroll-queue budget.
    int64_t scrollTargetWindowID = CGEventGetIntegerValueField(
        event,
        kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if (scrollTargetWindowID <= 0) {
        scrollTargetWindowID = CGEventGetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer);
    }
    bool isDiagonal = scrollDeltaAxis1 != 0 && scrollDeltaAxis2 != 0;
    BOOL isHandledPhysicalScroll = isPixelBased == 0
        && scrollPhase == 0
        && drawingTabletID == 0
        && !isDiagonal;
    if (isHandledPhysicalScroll && scrollTargetWindowID <= 0) {
        NSPoint pointerLocation = getFlippedPointerLocationWithEvent(event);
        scrollTargetWindowID = [NSWindow windowNumberAtPoint:pointerLocation
                                belowWindowWithWindowNumber:0];
    }

    /// Raw input trace. `./dev.sh logs-record`
    ///
    /// Kept rather than removed: every scroll-engine fix in this fork came out of this one line. It is emitted at
    /// info level so the rolling recorder can capture it without globally enabling debug logs; MMF-generated wheel
    /// events return above, keeping this path limited to physical or otherwise external input.
    ///
    /// Notes:
    /// - Logged *before* the early-out below, so passed-through (continuous / diagonal) events appear too. That's
    ///   what proved the TB800 emits zero diagonal events, which dissolved Feature 2.
    /// - Scalars only: os_log renders scalars public but redacts %@, so this stays readable without
    ///   `sudo log config --mode private_data:on`.
    /// - `line` vs `point` is the distinction that matters: point delta is already accelerated by macOS (one
    ///   `line=1` report was measured yielding point deltas of 1, 3, 8 and 13), so only `line` is a usable unit count.
    DDLogInfo("MFSCROLL_INPUT: cont=%lld phase=%lld line=(%lld,%lld) point=(%lld,%lld) fixed=(%.3f,%.3f) diag=%d window=%lld",
              isPixelBased,
              scrollPhase,
              lineDeltaAxis1,
              lineDeltaAxis2,
              scrollDeltaAxis1,
              scrollDeltaAxis2,
              CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1),
              CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2),
              (int)isDiagonal,
              scrollTargetWindowID);

    if (!isHandledPhysicalScroll) {
        return event;
    }
    
    /// Filter out scroll events by wacom tablet
    if (CGEvent_IsWacomEvent(event))
        return event;

    /// Get timestamp
    ///     Get timestamp here instead of _scrollQueue for accurate timing
    CFTimeInterval tickTime = CGEventGetTimestampInSeconds(event);
    
    /// Create copy of event
    
    CGEventRef eventCopy = CGEventCreateCopy(event); /// Create a copy, because the original event will become invalid and unusable in the new queue.
    
    /// Enqueue heavy processing
    ///  Executing heavy stuff on a different thread to prevent the eventTap from timing out. We wrote this before knowing that you can just re-enable the eventTap when it times out. But this doesn't hurt.
    
    dispatch_async(_scrollQueue, ^{
        heavyProcessing(eventCopy,
                        scrollDeltaAxis1,
                        scrollDeltaAxis2,
                        lineDeltaAxis1,
                        lineDeltaAxis2,
                        scrollTargetWindowID,
                        tickTime);
    });
    
    return NULL;
}

#pragma mark - Main event processing

static void heavyProcessing(CGEventRef event,
                            int64_t scrollDeltaAxis1,
                            int64_t scrollDeltaAxis2,
                            int64_t lineDeltaAxis1,
                            int64_t lineDeltaAxis2,
                            int64_t scrollTargetWindowID,
                            CFTimeInterval tickTS) {
    
    /// Declare stuff for later
    static DriverUnsuspender unsuspendDrivers = ^{}; /// This is old stuff that should be removed I think [Jun 2 2025]
    double inputQueueDelayMs = MAX(0.0, (CACurrentMediaTime() - tickTS) * 1000.0);
    double physicalInputGap = DBL_MAX;
    if (_previousPhysicalScrollInputTime > 0) {
        physicalInputGap = tickTS - _previousPhysicalScrollInputTime;
    } else if (_scrollInputObservationStartTime > 0
               && tickTS >= _scrollInputObservationStartTime) {
        physicalInputGap = tickTS - _scrollInputObservationStartTime;
    }
    _previousPhysicalScrollInputTime = tickTS;
    
    /// Get axis
    
    MFAxis inputAxis = [ScrollUtility axisForVerticalDelta:scrollDeltaAxis1 horizontalDelta:scrollDeltaAxis2];
    
    /// Get scrollDelta
    
    int64_t scrollDelta = 0;
    int64_t lineDelta = 0;

    if (inputAxis == kMFAxisVertical) {
        scrollDelta = scrollDeltaAxis1;
        lineDelta = lineDeltaAxis1;
    } else if (inputAxis == kMFAxisHorizontal) {
        scrollDelta = scrollDeltaAxis2;
        lineDelta = lineDeltaAxis2;
    } else {
        NSCAssert(NO, @"Invalid scroll axis");
    }
    
    /// Initialized scrollConfig for preliminary analysis
    /// Could also use `[ScrollConfig scrollConfigWithModifiers:inputAxis:event:]` here? It probably doesn't matter. This should only happen once on the very first tick after the helper starts.
    
    if (_scrollConfig == nil) {
        _scrollConfig = ScrollConfig.shared;
    }

    /// A scroll animation belongs to the window that received its opening phase. If the target changes, continuing
    /// that old gesture/momentum session in the new window can make its scroll view ignore or dampen deltas until a
    /// later direction change cancels the session. Bundle tracking alone misses keyboard-driven switches between
    /// windows of the same app, so also compare WindowServer's event-routing window ID.
    static NSString *previousScrollTargetBundleID = nil;
    static int64_t previousScrollTargetWindowID = 0;
    NSString *currentScrollTargetBundleID = HelperState.shared.frontmostAppBundleID ?: @"";
    BOOL scrollTargetAppChanged = previousScrollTargetBundleID != nil
        && ![currentScrollTargetBundleID isEqualToString:previousScrollTargetBundleID];
    BOOL scrollTargetWindowChanged = scrollTargetWindowID > 0
        && previousScrollTargetWindowID > 0
        && scrollTargetWindowID != previousScrollTargetWindowID;
    if (scrollTargetAppChanged || scrollTargetWindowChanged) {
        NSString *reason = scrollTargetWindowChanged ? @"window-change" : @"app-change";
        DDLogInfo("MFSCROLL_TARGET: %{public}@ app=%{public}@->%{public}@ window=%lld->%lld action=reset-session",
                   reason,
                   previousScrollTargetBundleID ?: @"",
                   currentScrollTargetBundleID,
                   previousScrollTargetWindowID,
                   scrollTargetWindowID);
        resetState_Unsafe();
    }
    previousScrollTargetBundleID = [currentScrollTargetBundleID copy];
    if (scrollTargetWindowID > 0) {
        previousScrollTargetWindowID = scrollTargetWindowID;
    }

    /// Modifier state changes the input axis/effect and selects a different cached config. Sample it before the
    /// preliminary direction analysis on every physical report. Deferring this until a gesture boundary lets the
    /// old animation/config survive while a modifier is pressed or released mid-gesture.
    MFScrollModificationResult newMods = [ScrollModifiers currentModificationsWithEvent:event];

    /// Fork: while ANY trackball mode is latched (Scroll & Zoom / Zoom), the ring zooms with no modifier held.
    /// Forced here rather than in ScrollModifiers so it beats whatever the keyboard says. This deliberately
    /// overrides only the effect modification; input modifications such as precise/quick remain intact.
    if (HelperState.shared.trackballModeIsActive) {
        newMods.effectMod = kMFScrollEffectModificationZoom;
    }

    if (![ScrollModifiers scrollModsAreEqual:newMods other:_modifications]) {
        DDLogInfo("MFSCROLL_CONFIG: action=modifier-change oldInput=%ld oldEffect=%ld newInput=%ld newEffect=%ld reset-session=1",
                   (long)_modifications.inputMod,
                   (long)_modifications.effectMod,
                   (long)newMods.inputMod,
                   (long)newMods.effectMod);
        resetState_Unsafe();
        _modifications = newMods;
        _modificationUsageNotified = NO;
    }

    BOOL modificationsAreActive =
        _modifications.inputMod != kMFScrollInputModificationNone
        || _modifications.effectMod != kMFScrollEffectModificationNone;
    if (modificationsAreActive && !_modificationUsageNotified) {
        [ScrollModifiers handleCurrentModificationHasBeenUsedWithEvent:event];
        _modificationUsageNotified = YES;
    }

    /// Start the magnification gesture from the physical wheel report—not from the first
    /// display callback. Slow Ctrl-wheel input can otherwise let Chromium discard a nonzero
    /// `Began` delta and finish the animator before it ever sees `Changed`.
    uint64_t zoomGestureGeneration = 0;
    if (_modifications.effectMod == kMFScrollEffectModificationZoom) {
        zoomGestureGeneration = beginZoomGesture_Unsafe(!HelperState.shared.trackballModeIsActive,
                                                         currentZoomTargetNeedsOpeningImpulse());
    }

    /// Run preliminary scrollAnalysis
    ///     To check if this is the first consecutive scrollTick

    MFDirection scrollDirection = [ScrollUtility directionForInputAxis:inputAxis inputDelta:scrollDelta invertSetting:_scrollConfig.u_invertDirection horizontalModifier:(_modifications.effectMod == kMFScrollEffectModificationHorizontalScroll)];
    
    BOOL firstConsecutive = [ScrollAnalyzer peekIsFirstConsecutiveTickWithTickOccuringAt:tickTS direction:scrollDirection config:_scrollConfig];
    
    ///
    /// Update stuff
    ///     on the first scrollTick
    
    if (firstConsecutive) {
        /// Checking which app is under the mouse pointer and the other stuff we do here is really slow, so we only do it when necessary
        
        /// Disable suspension
//        _isSuspended = NO;
        
        /// Notify TrialCounter.swift
        [TrialCounter.shared handleUse];
        
        /// Update active device
        [HelperState.shared updateActiveDeviceWithEvent:event];
        
        /// Update mouse did move
        ///     Note: (17.09.2024) We need this in MMF 3, otherwise the displayLink never updates to another display (ScrollUtility.mouseDidMove must be true for the displayLink to update)
        ///             Discussion:
        ///             - This code comes from MMF 2 iirc. We originally commented this out for MMF 3.0.0, but re-activated it for 3.0.3.
        ///                 -> We commented it out since we thought we didn't need it since there are no app-specific settings anymore in MMF 3. However, I overlooked the display-link-updating stuff, which makes it so this is still needed under MMF 3.
        ///             - Having this state stored inside of ScrollUtility instead of a variable defined in Scroll.m is pretty weird, and might have contributed to us commenting it out for MMF 3 even though it was still used.
        [ScrollUtility updateMouseDidMoveWithEvent:event];
        
        /// Update application Overrides
        if ((NO)) { /// Unused in MMF 3
            if (!ScrollUtility.mouseDidMove) {
                [ScrollUtility updateFrontMostAppDidChange];
                /// Only checking this if mouse didn't move, because of || in (mouseMoved || frontMostAppChanged). For optimization. Not sure if significant.
            }
            
            if (ScrollUtility.mouseDidMove || ScrollUtility.frontMostAppDidChange) {
                
                /// Set app overrides
                DDLogDebug("Scroll.m: Frontmost app did change. Reloading config overrides.");
                BOOL didChange = [Config.shared loadOverridesForAppUnderMousePointerWithEvent:event];
                if (didChange) {
                    DDLogDebug("Scroll.m: Config did change. Resetting state.");
                    resetState_Unsafe();
                }
            }
        }
        
        /// Notify other touch drivers
        
        if ((NO)) { /// Unused
            
//            DriverUnsuspender thisDriverUnsuspender = [OutputCoordinator suspendTouchDriversFromDriver:kTouchDriverScroll];
//            if (thisDriverUnsuspender != nil) {
//                unsuspendDrivers = thisDriverUnsuspender;
//            }
        }
        
        /// Get display  under mouse pointer
        CGDirectDisplayID displayID = kCGNullDirectDisplay;
        CVReturn displayResolveResult =
            [HelperUtility displayUnderMousePointer:&displayID withEvent:event];
        if (displayResolveResult != kCVReturnSuccess
            || displayID == kCGNullDirectDisplay) {
            displayID = CGMainDisplayID();
            DDLogInfo("MFSCROLL_DISPLAY: action=context-fallback result=%d fallbackDisplay=%u",
                      displayResolveResult,
                      displayID);
        }

        CGPoint pointerLocation = CGEventGetLocation(event);
        DDLogInfo("MFSCROLL_CONTEXT: target=%{public}@ window=%lld display=%u pointer=(%.1f,%.1f) mouseMoved=%d animatorRequestedRunning=%d",
                   currentScrollTargetBundleID,
                   scrollTargetWindowID,
                   displayID,
                   pointerLocation.x,
                   pointerLocation.y,
                   ScrollUtility.mouseDidMove,
                   _animator.isRunning);

        /// Fork: drive the scroll animation from the display the pointer is actually on.
        ///     `_animator`'s CVDisplayLink has to be bound to an *active* display, or its callback stops firing
        ///     and no scroll events get posted at all — a total freeze that only clears when you move the mouse.
        ///     Upstream bound it to `NSScreen.mainScreen` (the menu-bar display) via `linkToMainScreen`. On a
        ///     multi-monitor setup that's frequently NOT the display being scrolled, and if that display's vsync
        ///     is parked (adaptive-sync / idle), the animation freezes. Re-binding to the display under the
        ///     pointer on each fresh scroll keeps the link on a live display.
        ///     `linkToDisplayUnderMousePointerWithEvent:` no-ops when the display hasn't changed, so it's cheap,
        ///     and it runs on every gesture start (this block) — including mid-momentum — so it isn't stranded
        ///     the way the old `!isRunning`-gated relink was.
        [_animator.displayLink linkToDisplay:displayID];
        /// Get scrollConfig
        _scrollConfig = [ScrollConfig scrollConfigWithModifiers:newMods inputAxis:inputAxis display:displayID];
        
    } /// End `if (firstConsecutive) {`

    /// Long wheel idle can be followed by a short hardware ramp of one-unit reports. Arm from the physical gap,
    /// after target/modifier resets have run, so the same opening report establishes the bounded response. No timer
    /// drives this state: later physical reports consult their own timestamp and substantial input exits immediately.
    if (physicalInputGap != DBL_MAX
        && physicalInputGap >= _scrollConfig.stableIdleWakeMinimumIdle) {
        _stableIdleWakeOpeningTime = tickTS;
        _stableIdleWakeOpeningGap = physicalInputGap;
    }

    /// Consume this one-report marker before processing the new input. A requested-running animator means the
    /// bounded tail is still visibly continuous, so ordinary measured slow smoothing remains appropriate. A stopped
    /// animator means that response expired; the small continuation below may retain its measured cadence, but its
    /// directly-driven phase must restart with the same bounded duration used by an opening report.
    BOOL stableFastTailResponseExpiredBeforeContinuation =
        _stableFastTailContinuationPending && !_animator.isRunning;
    _stableFastTailContinuationPending = NO;
    BOOL stableCloseReversalResponseExpiredBeforeContinuation =
        _stableCloseReversalContinuationPending && !_animator.isRunning;
    _stableCloseReversalContinuationPending = NO;
    
    ///
    /// Get effective direction
    ///  -> With user settings etc. applied
    
    scrollDirection = [ScrollUtility directionForInputAxis:inputAxis inputDelta:scrollDelta invertSetting:_scrollConfig.u_invertDirection horizontalModifier:(_modifications.effectMod == kMFScrollEffectModificationHorizontalScroll)]; /// Why do we need to get the scrollDirection again? We already calculated it during the "preliminary scrollAnalysis". Can it ever change betweent he 2 times we calculate it?

    /// Intercept the narrow mechanical-rebound signature before ScrollAnalyzer sees it. A blanket late-report drop
    /// previously made real scroll starts sticky, so this guard is armed only by a fast gesture and only matches a
    /// one-unit/one-point report. It never releases an isolated report later: that would merely move the burst.
    ///
    /// An ambiguous same-direction report while a glide is live must still enter the ordinary retarget path. Leaving
    /// that glide untouched silently discarded the physical report, which makes a deliberate resumed scroll feel
    /// stuck once the old tail expires. The existing one-shot tail blend below limits that first response while
    /// retaining current velocity. With no live motion, a bounded micro-glide makes an intentional isolated report
    /// visible without amplifying mechanical settling into a full accelerated tick. An ambiguous reversal cancels
    /// the old direction and starts the same bounded response immediately. The guard then disarms, so a genuine
    /// continuation never waits for confirmation.
    int64_t settlingUnits = MAX(1, llabs(lineDelta));
    int64_t settlingPointDelta = llabs(scrollDelta);
    CFTimeInterval timeSinceFastInput = _stableSettlingTailLastFastInputTime > 0
        ? tickTS - _stableSettlingTailLastFastInputTime
        : DBL_MAX;
    double rawSettlingVelocity = physicalInputGap > 0 && physicalInputGap != DBL_MAX
        ? (double)settlingUnits / physicalInputGap
        : DBL_MAX;
    BOOL isSettlingTailCandidate = _scrollConfig.animationCurve == kMFScrollAnimationCurveNameLowInertia
        && _stableSettlingTailGuardArmed
        && timeSinceFastInput >= 0
        && timeSinceFastInput <= _scrollConfig.stableSettlingTailWindowMax
        && physicalInputGap >= _scrollConfig.stableFastTailInputGapMin
        && settlingUnits == 1
        && settlingPointDelta <= _scrollConfig.stableSettlingTailPointDeltaMax
        && rawSettlingVelocity <= _scrollConfig.stableFastTailRawVelocityMax;

    BOOL stableSettlingTailSameDirectionCandidate = NO;
    if (isSettlingTailCandidate) {
        BOOL sameDirection = scrollDirection == _stableSettlingTailDirection;
        double currentAnimationSpeed = magnitudeOfVector(_animator.getLastAnimationSpeed);
        BOOL animationWasRunning = _animator.isRunning;
        double activeMotionUnit = CLIP(
            currentAnimationSpeed / _scrollConfig.stableFastTailContinuitySpeed,
            0.0,
            1.0);
        int64_t microGlidePixels = (int64_t)llround(
            _scrollConfig.stableSettlingTailResponsiveDistanceMax
            + activeMotionUnit
            * (_scrollConfig.stableSettlingTailResponsiveDistanceMin
               - _scrollConfig.stableSettlingTailResponsiveDistanceMax));
        if (sameDirection) {
            if (animationWasRunning) {
                /// Do not consume a real same-direction report merely because it shares the narrow rebound shape.
                /// It will receive the below one-shot tail blend, then TouchAnimator will retarget with its
                /// preserved live velocity on this same report.
                stableSettlingTailSameDirectionCandidate = YES;
                DDLogInfo("MFSCROLL_TAIL: action=retarget-same gapMs=%.1f sinceFastMs=%.1f currentV=%.1f animatorRunning=1 guard=disarm",
                           physicalInputGap * 1000.0,
                           timeSinceFastInput * 1000.0,
                           currentAnimationSpeed);
            } else {
                /// This report already received the one allowed bounded tail response. Without recording that fact
                /// here, the early return below leaves ScrollAnalyzer's old gesture active and the next report can
                /// be bounded a second time by the ordinary fast-tail path.
                _stableFastTailReportHandled = YES;
                _stableFastTailContinuationPending = YES;
                startSettlingTailMicroGlide(microGlidePixels,
                                            scrollDirection,
                                            tickTS,
                                            inputQueueDelayMs,
                                            _scrollConfig,
                                            _modifications);
                DDLogInfo("MFSCROLL_TAIL: action=micro-same gapMs=%.1f sinceFastMs=%.1f currentV=%.1f animatorRunning=0 microPx=%lld durationMs=%.1f continuation=armed guard=disarm",
                           physicalInputGap * 1000.0,
                           timeSinceFastInput * 1000.0,
                           currentAnimationSpeed,
                           microGlidePixels,
                           _scrollConfig.stableSettlingTailResponsiveDuration * 1000.0);
            }
        } else {
            [_animator cancel];
            startSettlingTailMicroGlide(microGlidePixels,
                                        scrollDirection,
                                        tickTS,
                                        inputQueueDelayMs,
                                        _scrollConfig,
                                        _modifications);
            DDLogInfo("MFSCROLL_TAIL: action=micro-reversal gapMs=%.1f sinceFastMs=%.1f currentV=%.1f oldDirection=%ld candidateDirection=%ld microPx=%lld durationMs=%.1f guard=disarm",
                       physicalInputGap * 1000.0,
                       timeSinceFastInput * 1000.0,
                       currentAnimationSpeed,
                       (long)_stableSettlingTailDirection,
                       (long)scrollDirection,
                       microGlidePixels,
                       _scrollConfig.stableSettlingTailResponsiveDuration * 1000.0);
        }

        _stableSettlingTailGuardArmed = NO;
        _stableSettlingTailDirection = kMFDirectionNone;
        _stableSettlingTailLastFastInputTime = 0;
        if (!stableSettlingTailSameDirectionCandidate) {
            _stablePreviousReportCanSeedSlowCadence = NO;
            CFRelease(event);
            return;
        }
    }

    if ((_stableSettlingTailGuardArmed && scrollDirection != _stableSettlingTailDirection)
        || timeSinceFastInput > _scrollConfig.stableSettlingTailWindowMax) {
        _stableSettlingTailGuardArmed = NO;
        _stableSettlingTailDirection = kMFDirectionNone;
        _stableSettlingTailLastFastInputTime = 0;
    }
    
    /// Run full scrollAnalysis
    ScrollAnalysisResult scrollAnalysisResult = [ScrollAnalyzer updateWithTickOccuringAt:tickTS direction:scrollDirection units:llabs(lineDelta) config:_scrollConfig];

    /// Any ambiguous one-unit settling report has already been handled above. Reports reaching the analyzer are
    /// confirmed, substantial, outside the settling window, or were not preceded by a fast gesture.

    
    /// Store scrollAnalysisResult
    ///     So that command tab output code can access it. Not sure if good solution
    _lastScrollAnalysisResult = scrollAnalysisResult;
    _lastScrollAnalysisResultTimeStamp = CACurrentMediaTime();
    
    /// Debug
    DDLogDebug("Scroll.m: ScrollAnalysisResult: %@", [ScrollAnalyzer scrollAnalysisResultDescription:scrollAnalysisResult]);
    
    /// Make scrollDelta positive, now that we have scrollDirection stored
    scrollDelta = llabs(scrollDelta);

    /// Get the unit count this event carries.
    ///
    /// Why this exists [Jul 2026]:
    ///     `ScrollAnalyzer` models input as a notched wheel: one event == one detent, and the only signal is how
    ///     fast detents arrive. That's wrong for a free-spinning ring like the TB800, which reports multi-unit
    ///     deltas. Measured over 346 real events: |line| ranges 1...9, and only 35 of 260 vertical
    ///     events were |line| == 1 — the mode is 9. Report rate and magnitude climb *together*, so the curve's
    ///     input (1/timeBetweenTicks) spans only ~10x (6.2 -> 66.7 Hz) while true scroll velocity
    ///     (rate * |line|) spans ~97x. Everything past that 10x was being thrown away.
    ///
    /// Why the LINE delta and not `scrollDelta`:
    ///     `scrollDelta` is the *point* delta, which macOS has already accelerated — a single |line| == 1 report
    ///     was measured yielding point deltas of 1, 3, 8 and 13 depending on spin speed. Scaling by it would
    ///     compound macOS's acceleration with our own curve *and* the device magnitude. The line delta is the
    ///     closest available proxy for the device's own unit count.
    ///     (Caveat: we can't tell from CGEvent alone whether the line delta is raw HID counts or is itself lightly
    ///     accelerated by IOHIDFamily. Confirming that needs an HID-level read.)
    ///
    /// Notched mice are unaffected: they report +-1 per detent, so this is a no-op factor of 1 for them.
    /// The MAX() guards the case where a point delta arrives with a zero line delta (not observed, but it would
    /// otherwise zero out the scroll).
    int64_t unitsForThisTick = MAX(1, llabs(lineDelta));
    
    /// Return if suspended (so we dont' send any events)
//    if (_isSuspended) {
//        return;
//    }
    
    ///
    /// Acceleration (Get pxToScrollForThisTick)
    ///
    
    /// @discussion See the RawAccel guide for more info on acceleration curves https://github.com/a1xd/rawaccel/blob/master/doc/Guide.md
    ///     -> Edit: Their whole shtick is to make the outputSpeed(inputSpeed) curve smooth. This is relatively hard and I don't think this would be noticable for scrolling. Instead we simply define a sens(inputSpeed) curve using a Bezier curve.
    
    int64_t pxToScrollForThisTick;
    double pxForThisTickBeforeRateLimit = 0;
    double stableRateLimitPx = 0;
    double stableOutputSpeedRatio = 0;
    BOOL stableRateLimited = NO;
    BOOL stableAdaptiveControlEnabled = NO;
    BOOL stableBoundsEnabled = NO;
    BOOL stableHasMeasuredTickInterval = NO;
    BOOL stableSlowCadenceContinuationForTick = NO;
    CFTimeInterval stableSlowCadenceForTick = 0;
    CFTimeInterval stableSlowCadenceEstimateBeforeTick = 0;
    CFTimeInterval stableSlowCadenceDurationReferenceForTick = 0;
    double stableSlowCadenceMemoryBlendForTick = 0.0;
    double stableSlowCadenceContinuationBlendForTick = 0.0;
    double stableSlowCadenceReversalBlendForTick = 1.0;
    BOOL stableRestartAfterExpiredFastTailForTick = NO;
    BOOL stableRestartAfterExpiredCloseReversalForTick = NO;
    BOOL stableSharpDecelerationTailForTick = NO;
    BOOL stableStoppedSharpDecelerationTailForTick = NO;
    double stableIdleWakeOpeningCapBlendForTick = 0.0;
    double stableIdleWakeOpeningGapForTick = 0.0;
    double stableIdleWakeElapsedForTick = DBL_MAX;
    double stableModeledOutputSpeedForTick = 0.0;
    double stablePreviousModeledOutputSpeedForTick = 0.0;
    double stableSlowCadenceSpeedMaxForTick = 0.0;
    double stableAnimationCadenceIntervalForTick = DBL_MAX;
    /// A new gesture's first report has no cadence measurement. Do not classify that unknown report as "very slow"
    /// and apply the maximum adaptive duration: doing so delays every scroll start by hundreds of milliseconds.
    /// As soon as the second report supplies a real interval, use the speed-derived blend directly. Counting reports
    /// here made careful scrolling stay on normal Smoothness for three reports and then jump abruptly to Slow
    /// Smoothness. Acceleration is already filtered in continuous time by ScrollAnalyzer, so a second history gate
    /// only adds latency and makes the response depend on report count.
    /// A fast gesture's first sparse tail report must also remain brief, but intentional continued slow movement
    /// must regain adaptive smoothing. Track whether one tail report has already been handled; a second slow report
    /// is evidence of continuation and returns to the normal speed-derived curve.
    double stableAdaptiveSlowSmoothingBlendForTick = 0.0;
    BOOL stableFastTailReport = NO;
    double stableFastTailContinuity = 1.0;
    
    if (_scrollConfig.useAppleAcceleration) {
        
        pxToScrollForThisTick = scrollDelta;
        
    } else {
        
        /// Get tickInterval
        double timeBetweenTicks = scrollAnalysisResult.timeBetweenTicks;
        stableHasMeasuredTickInterval = timeBetweenTicks != DBL_MAX;
        
        /// Validate tickInterval
        assert(timeBetweenTicks == DBL_MAX
               || ISBETWEEN(timeBetweenTicks, _scrollConfig.consecutiveScrollTickIntervalMin, _scrollConfig.consecutiveScrollTickIntervalMax));
        
        /// Handle tickInterval = `DBL_MAX`
        ///     `DBL_MAX` is a special flag used by scrollAnalyzer to indicate that it has been more than `consecutiveScrollTickIntervalMax` since the last tick, and therefore the last two ticks were not consecutive. Kinda weird.
        if (timeBetweenTicks == DBL_MAX) {
            timeBetweenTicks = _scrollConfig.consecutiveScrollTickIntervalMax;
        }
        
        /// Clip tickInterval
        /// Notes:
        /// - The `_scrollConfig.accelerationCurve` also uses `consecutiveScrollTickInterval_AccelerationEnd` in iits definition, but it linearly interpolates the acceleration for lower `timeBetweenTicks`. To cap the acceleration we use CLIPLOW() here.
        /// - I'm not totally sure if this is optimal for the UX, also code is a bit messy.
        timeBetweenTicks = CLIPLOW(timeBetweenTicks, _scrollConfig.consecutiveScrollTickInterval_AccelerationEnd);
        
        /// Get the TRUE scroll velocity, in units/s.
        ///     ScrollAnalyzer estimates this directly with a time-based filter. This avoids dividing independently
        ///     smoothed unit and interval values, and keeps the filter's latency stable across changing report rates.
        double scrollSpeed = scrollAnalysisResult.velocityInUnitsPerSecond;

        /// Apply the tuning model.
        ///     pxPerUnit(v) = pxAtUnitSpeed * v^(gamma-1)   ->   px/s = pxAtUnitSpeed * v^gamma
        ///
        ///     gamma == 1 gives output exactly proportional to input velocity. gamma < 1 compresses the input's
        ///     ~110x velocity range into a smaller output range; gamma > 1 genuinely accelerates. Both knobs come
        ///     from the sliders in the Scrolling tab — see ScrollConfig.pxAtUnitSpeed / .gamma.
        ///
        ///     Why this replaces `accelerationCurve`: that curve is defined over an events/s domain and its output
        ///     was px-per-event. Feeding it real velocity would silently invalidate its tuning, and multiplying its
        ///     output by the unit count (what we did first) stacks a third multiplier on top of it and fastScroll —
        ///     measured at ~100k px/s on a fast spin. This model has one meaning for "speed" and one for "distance".
        double pxPerUnit = MFScrollPixelsPerUnit(
            scrollSpeed,
            _scrollConfig.pxAtRefSpeed,
            _scrollConfig.refSpeed,
            _scrollConfig.gamma,
            _scrollConfig.velocityModelDistanceMultiplier);
        double pxForThisTickDouble = pxPerUnit * unitsForThisTick;
        double fastScrollFactor = 1.0;

        ///
        /// Apply fast scroll to pxToScrollForThisTick
        ///
        
        if (_scrollConfig.fastScrollCurve != nil) {
            
            /// Evaluate fast scroll
            /// +1 cause consecutiveScrollSwipeCounter starts counting at 0, and fsThreshold at 1
            double consecutiveSwipes = scrollAnalysisResult.consecutiveScrollSwipeCounter;
            fastScrollFactor = [_scrollConfig.fastScrollCurve evaluateAt:consecutiveSwipes+1];
            
            /// LImit fastScroll
            /// - Limit it to 100,000, which is still super extreme, but it can grow far FAR larger. Especially with a free spinning wheel.
            /// - If it gets into the trillions things will still work properly, but the animations times might be several hours long which we obviously don't want
            /// - 100.000 still lets you scroll the world's longest website in a few seconds.
            /// - Edit: We also limit the animationDuration in TouchAnimator now, so this might not be necessary or useful anymore
            if (fastScrollFactor > 100000) fastScrollFactor = 100000;
            
            /// Apply fastScroll
            pxForThisTickDouble *= fastScrollFactor;
        }

        /// Cap the FINAL output, after every acceleration layer.
        ///
        /// The old limit was pixels/report. Its effective speed therefore changed with hardware cadence and let the
        /// TB800 enqueue 17k–24k px/s during a hard spin. Limit distance by the real time represented by this report
        /// instead. The first report has no interval, so retain the old bounded-start behavior for that one report.
        pxForThisTickBeforeRateLimit = pxForThisTickDouble;
        stableAdaptiveControlEnabled =
            _scrollConfig.animationCurve == kMFScrollAnimationCurveNameLowInertia;
        stableBoundsEnabled = !_scrollConfig.useAppleAcceleration;

        double modeledOutputSpeed = MFScrollModeledOutputSpeed(
            scrollSpeed,
            _scrollConfig.pxAtRefSpeed,
            _scrollConfig.refSpeed,
            _scrollConfig.gamma,
            _scrollConfig.velocityModelDistanceMultiplier) * fastScrollFactor;
        stableOutputSpeedRatio = modeledOutputSpeed / _scrollConfig.stableMaximumOutputSpeed;
        stableAnimationCadenceIntervalForTick = scrollAnalysisResult.timeBetweenTicks;

        /// ScrollAnalyzer's three-sample interval average smooths steady movement and deceleration, but after a
        /// sparse report it can remain hundreds of milliseconds behind a real acceleration. The velocity filter has
        /// already recognized that acceleration on this report, so let a materially shorter raw interval drive only
        /// the directly-driven animation duration. Distance, analyzer history, adaptive smoothing, and deceleration
        /// remain unchanged.
        if (stableAdaptiveControlEnabled && stableHasMeasuredTickInterval) {
            double rawCadenceInterval = MAX(
                scrollAnalysisResult.DEBUG_timeBetweenTicksRaw,
                _scrollConfig.consecutiveScrollTickIntervalMin);
            BOOL cadenceAcceleratedMaterially =
                rawCadenceInterval
                    <= scrollAnalysisResult.timeBetweenTicks
                        * _scrollConfig.stableAccelerationCadenceRawIntervalRatioMax;
            BOOL modeledSpeedAccelerated =
                _stablePreviousModeledOutputSpeed > 0
                && modeledOutputSpeed > _stablePreviousModeledOutputSpeed;
            if (cadenceAcceleratedMaterially && modeledSpeedAccelerated) {
                stableAnimationCadenceIntervalForTick = rawCadenceInterval;
                DDLogInfo("MFSCROLL_ADAPTIVE: cadence=measured rawMs=%.1f smoothedMs=%.1f modeledV=%.1f previousModeledV=%.1f action=use-raw-acceleration-cadence",
                           rawCadenceInterval * 1000.0,
                           scrollAnalysisResult.timeBetweenTicks * 1000.0,
                           modeledOutputSpeed,
                           _stablePreviousModeledOutputSpeed);
            }
        }

        /// A timeout only says that the animator/analyzer should start a new gesture. It does not prove that sparse
        /// trackball movement stopped. Cadence is a scalar timing signal, so preserve it through a small slow
        /// reversal while the direction-change path below cancels the old-direction animator immediately. A
        /// reversal near the 500ms gesture boundary is instead a fresh input: fade stale cadence out continuously
        /// so it cannot make the opening report feel stuck. Reject a late tail after fast motion and any larger
        /// accelerating report.
        double adaptiveSpeedEnd = _scrollConfig.stableMaximumOutputSpeed
            * _scrollConfig.u_adaptiveSmoothnessEndSpeedRatio;
        double slowCadenceSpeedMax = MIN(adaptiveSpeedEnd, _scrollConfig.stableFastGestureSpeed);
        stableModeledOutputSpeedForTick = modeledOutputSpeed;
        stablePreviousModeledOutputSpeedForTick = _stablePreviousModeledOutputSpeed;
        stableSlowCadenceSpeedMaxForTick = slowCadenceSpeedMax;
        stableSharpDecelerationTailForTick = MFScrollIsSharpDecelerationTailReport(
            stableAdaptiveControlEnabled,
            stableHasMeasuredTickInterval,
            scrollAnalysisResult.scrollDirectionDidChange,
            unitsForThisTick,
            modeledOutputSpeed,
            _stablePreviousModeledOutputSpeed,
            slowCadenceSpeedMax,
            _scrollConfig.stableSharpDecelerationCurrentSpeedRatioMax);
        stableStoppedSharpDecelerationTailForTick =
            MFScrollShouldCapStoppedSharpDecelerationTail(
                stableSharpDecelerationTailForTick,
                _animator.isRunning);
        if (_stableIdleWakeOpeningTime > 0) {
            stableIdleWakeOpeningGapForTick = _stableIdleWakeOpeningGap;
            stableIdleWakeElapsedForTick = MAX(0.0, tickTS - _stableIdleWakeOpeningTime);
            stableIdleWakeOpeningCapBlendForTick = MFScrollIdleWakeOpeningCapBlend(
                stableAdaptiveControlEnabled,
                firstConsecutive,
                stableIdleWakeOpeningGapForTick,
                stableIdleWakeElapsedForTick,
                _scrollConfig.stableIdleWakeMinimumIdle,
                _scrollConfig.stableIdleWakeResponseHoldDuration,
                _scrollConfig.stableIdleWakeResponseFadeDuration,
                unitsForThisTick,
                modeledOutputSpeed,
                slowCadenceSpeedMax);

            /// A larger/faster report proves the wake ramp is over on that same report. Time expiry is likewise
            /// observed only when another physical report arrives; there is no scheduled gate or delayed input.
            if (stableIdleWakeElapsedForTick
                    >= _scrollConfig.stableIdleWakeResponseHoldDuration
                        + _scrollConfig.stableIdleWakeResponseFadeDuration
                || unitsForThisTick > 2
                || modeledOutputSpeed >= slowCadenceSpeedMax) {
                _stableIdleWakeOpeningTime = 0;
                _stableIdleWakeOpeningGap = 0;
            }
        }
        stableRestartAfterExpiredFastTailForTick =
            stableFastTailResponseExpiredBeforeContinuation
            && !firstConsecutive
            && !scrollAnalysisResult.scrollDirectionDidChange
            && unitsForThisTick <= 2
            && modeledOutputSpeed < slowCadenceSpeedMax;
        stableSlowCadenceContinuationForTick = MFScrollShouldContinueSlowCadence(
            stableAdaptiveControlEnabled,
            firstConsecutive,
            _stablePreviousReportCanSeedSlowCadence,
            unitsForThisTick,
            scrollAnalysisResult.scrollDirectionDidChange,
            physicalInputGap,
            _scrollConfig.consecutiveScrollTickIntervalMax,
            _scrollConfig.stableSlowCadenceMemoryMaxInterval);

        if (stableSlowCadenceContinuationForTick) {
            /// Preserve cadence only in proportion to how recent the preceding report was. A one-unit input after
            /// the full 1.5s memory horizon is visually a new start even though the prior report lets us recognize
            /// a possible sparse continuation. Letting that stale cadence fully control duration made the opening
            /// 20px take almost half a second. Same-direction sparse input remains fully blended at the 500ms
            /// gesture boundary and eases to zero at the memory limit. A reversal gets a second continuous taper:
            /// it is full through the measured close-reversal interval, then reaches zero at the gesture boundary.
            /// Neither taper delays, confirms, or discards the physical report.
            double memoryTaperRange = MAX(
                _scrollConfig.stableSlowCadenceMemoryMaxInterval
                    - _scrollConfig.consecutiveScrollTickIntervalMax,
                DBL_EPSILON);
            stableSlowCadenceMemoryBlendForTick = CLIP(
                (_scrollConfig.stableSlowCadenceMemoryMaxInterval - physicalInputGap)
                    / memoryTaperRange,
                0.0,
                1.0);
            stableSlowCadenceContinuationBlendForTick = stableSlowCadenceMemoryBlendForTick;
            if (scrollAnalysisResult.scrollDirectionDidChange) {
                double reversalTaperRange = MAX(
                    _scrollConfig.consecutiveScrollTickIntervalMax
                        - _scrollConfig.stableSlowCadenceReversalFullBlendMaxInterval,
                    DBL_EPSILON);
                stableSlowCadenceReversalBlendForTick = CLIP(
                    (_scrollConfig.consecutiveScrollTickIntervalMax - physicalInputGap)
                        / reversalTaperRange,
                    0.0,
                    1.0);
                stableSlowCadenceContinuationBlendForTick = MIN(
                    stableSlowCadenceContinuationBlendForTick,
                    stableSlowCadenceReversalBlendForTick);
            }
            stableSlowCadenceEstimateBeforeTick = _stableSlowCadenceEstimate;
            if (_stableSlowCadenceEstimate <= 0) {
                _stableSlowCadenceEstimate = physicalInputGap;
            } else {
                _stableSlowCadenceEstimate += _scrollConfig.stableSlowCadenceEstimateAlpha
                    * (physicalInputGap - _stableSlowCadenceEstimate);
            }
            if (scrollAnalysisResult.scrollDirectionDidChange) {
                /// Direction changes are a new motion decision. A close reversal should use its actual cross-
                /// direction gap, not a longer same-direction estimate retained from the preceding sparse stream.
                _stableSlowCadenceEstimate = MIN(_stableSlowCadenceEstimate, physicalInputGap);
            }
            stableSlowCadenceForTick = _stableSlowCadenceEstimate;
            /// The current pause may update cadence memory for a later report, but it must not lengthen its own
            /// animation. Use only cadence known before this report, bounded by the current/reversal-clamped estimate
            /// and the gesture boundary. A close reversal retains its actual cross-direction gap; an unestablished
            /// same-direction restart has no prior duration reference and therefore keeps only its measured slow-
            /// smoothing response. Multiplying a newly growing gap estimate by a shrinking memory blend produced a
            /// non-monotonic hump where 0.8-1.0s pauses restarted more slowly than 0.5s pauses.
            stableSlowCadenceDurationReferenceForTick =
                MFScrollSlowCadenceDurationReference(
                    stableSlowCadenceEstimateBeforeTick,
                    stableSlowCadenceForTick,
                    physicalInputGap,
                    scrollAnalysisResult.scrollDirectionDidChange,
                    _scrollConfig.consecutiveScrollTickIntervalMax);
            stableAdaptiveSlowSmoothingBlendForTick = stableSlowCadenceContinuationBlendForTick;
            DDLogInfo("MFSCROLL_ADAPTIVE: cadence=remembered gapMs=%.1f priorEstimateMs=%.1f estimateMs=%.1f durationRefMs=%.1f memoryBlend=%.2f reversalBlend=%.2f blend=%.2f reversal=%d previousSeed=%d action=%{public}@",
                       physicalInputGap * 1000.0,
                       stableSlowCadenceEstimateBeforeTick * 1000.0,
                       stableSlowCadenceForTick * 1000.0,
                       stableSlowCadenceDurationReferenceForTick * 1000.0,
                       stableSlowCadenceMemoryBlendForTick,
                       stableSlowCadenceReversalBlendForTick,
                       stableSlowCadenceContinuationBlendForTick,
                       scrollAnalysisResult.scrollDirectionDidChange,
                       _stablePreviousReportCanSeedSlowCadence,
                       stableSlowCadenceReversalBlendForTick < 1.0
                           ? @"taper-reversal-cadence"
                           : stableSlowCadenceEstimateBeforeTick <= 0
                               && !scrollAnalysisResult.scrollDirectionDidChange
                           ? @"bound-unestablished-stale-cadence"
                           : stableSlowCadenceContinuationBlendForTick < 1.0
                           ? @"taper-stale-cadence"
                           : @"use-slow-smoothness");
        } else if (stableAdaptiveControlEnabled && !stableHasMeasuredTickInterval) {
            stableAdaptiveSlowSmoothingBlendForTick = 0.0;
            DDLogInfo("MFSCROLL_ADAPTIVE: cadence=unknown previousSeed=%d units=%lld action=use-normal-smoothness",
                      _stablePreviousReportCanSeedSlowCadence,
                      unitsForThisTick);
        }

        stableRestartAfterExpiredCloseReversalForTick =
            MFScrollShouldCapStoppedCloseReversalContinuation(
                stableAdaptiveControlEnabled,
                stableCloseReversalResponseExpiredBeforeContinuation,
                firstConsecutive,
                scrollAnalysisResult.scrollDirectionDidChange,
                unitsForThisTick,
                modeledOutputSpeed,
                slowCadenceSpeedMax);

        /// Arm for exactly the next physical report only when the current report is
        /// the fully blended opening of a close, low-speed reversal. The next report
        /// consumes the marker before classification; no confirmation gate or delayed
        /// replay is introduced.
        _stableCloseReversalContinuationPending =
            stableAdaptiveControlEnabled
            && scrollAnalysisResult.scrollDirectionDidChange
            && stableSlowCadenceContinuationForTick
            && stableSlowCadenceReversalBlendForTick >= 1.0
            && unitsForThisTick <= 2
            && modeledOutputSpeed > 0.0
            && modeledOutputSpeed < slowCadenceSpeedMax;

        if (stableAdaptiveControlEnabled
            && stableHasMeasuredTickInterval
            && modeledOutputSpeed < slowCadenceSpeedMax
            && unitsForThisTick <= 2) {
            if (_stableSlowCadenceEstimate <= 0) {
                _stableSlowCadenceEstimate = physicalInputGap;
            } else {
                _stableSlowCadenceEstimate += _scrollConfig.stableSlowCadenceEstimateAlpha
                    * (physicalInputGap - _stableSlowCadenceEstimate);
            }
        } else if (unitsForThisTick > 2
                   || modeledOutputSpeed >= slowCadenceSpeedMax
                   || (firstConsecutive
                       && physicalInputGap > _scrollConfig.stableSlowCadenceMemoryMaxInterval)) {
            /// Acceleration invalidates the slow prediction on the same report. Its duration and velocity are then
            /// derived from current input, and the animator's retarget curve begins responding immediately.
            _stableSlowCadenceEstimate = 0;
        }

        _stablePreviousModeledOutputSpeed = modeledOutputSpeed;

        if (firstConsecutive) {
            _stableGestureReachedFastSpeed = NO;
            _stableFastTailReportHandled = NO;
        }
        if (modeledOutputSpeed >= _scrollConfig.stableFastGestureSpeed) {
            _stableGestureReachedFastSpeed = YES;
            /// Re-arm after every genuinely fast section, including fast -> slow -> fast within one gesture.
            _stableFastTailReportHandled = NO;
            _stableSettlingTailGuardArmed = YES;
            _stableSettlingTailDirection = scrollDirection;
            _stableSettlingTailLastFastInputTime = tickTS;
        }

        /// Hardware traces show the visible secondary burst as a real ~50px report arriving 150–320ms after a
        /// fast gesture, often after retained distance has already reached zero. Dropping it is unsafe because a
        /// deliberate resume looks the same. Reduce only the first response. A second report proves continued
        /// movement and therefore regains the speed-adaptive smoothness curve and full distance.
        double currentLegacyAnimationSpeed = magnitudeOfVector(_animator.getLastAnimationSpeed);
        stableFastTailReport = stableAdaptiveControlEnabled
            && !firstConsecutive
            && !scrollAnalysisResult.scrollDirectionDidChange
            && _stableGestureReachedFastSpeed
            && !_stableFastTailReportHandled
            && scrollAnalysisResult.DEBUG_velocityInUnitsPerSecondRaw <= _scrollConfig.stableFastTailRawVelocityMax
            && physicalInputGap >= _scrollConfig.stableFastTailInputGapMin
            && currentLegacyAnimationSpeed <= _scrollConfig.stableFastTailAnimatorSpeedMax;
        if (stableFastTailReport) {
            _stableFastTailReportHandled = YES;
            _stableFastTailContinuationPending = YES;
            double continuityUnit = CLIP(currentLegacyAnimationSpeed
                / _scrollConfig.stableFastTailContinuitySpeed, 0.0, 1.0);
            stableFastTailContinuity = continuityUnit * continuityUnit * (3.0 - 2.0 * continuityUnit);
            double fullTailDistance = pxForThisTickDouble;
            double distanceScale = _scrollConfig.stableFastTailDistanceScale
                + stableFastTailContinuity * (1.0 - _scrollConfig.stableFastTailDistanceScale);
            pxForThisTickDouble *= distanceScale;
            DDLogInfo("MFSCROLL_TAIL: action=blend source=%{public}@ rawV=%.1f gapMs=%.1f currentV=%.1f continuity=%.2f distanceScale=%.2f fullPx=%.1f outputPx=%.1f",
                       stableSettlingTailSameDirectionCandidate ? @"settling-same" : @"ordinary",
                       scrollAnalysisResult.DEBUG_velocityInUnitsPerSecondRaw,
                       physicalInputGap * 1000.0,
                       currentLegacyAnimationSpeed,
                       stableFastTailContinuity,
                       distanceScale,
                       fullTailDistance,
                       pxForThisTickDouble);
        }

        _stablePreviousReportCanSeedSlowCadence = MFScrollReportCanSeedSlowCadence(
            unitsForThisTick,
            modeledOutputSpeed,
            slowCadenceSpeedMax,
            stableFastTailReport,
            stableSettlingTailSameDirectionCandidate,
            stableSharpDecelerationTailForTick);

        if (stableAdaptiveControlEnabled
            && (stableHasMeasuredTickInterval || stableSlowCadenceContinuationForTick)) {
            stableAdaptiveSlowSmoothingBlendForTick = stableSlowCadenceContinuationForTick
                ? stableSlowCadenceContinuationBlendForTick
                : 1.0;
            if (stableFastTailReport && stableHasMeasuredTickInterval) {
                /// Preserve the existing tail rule: one isolated settling report stays brief in proportion to how
                /// much visible motion is still continuous. The next measured report returns to direct speed-based
                /// adaptation without waiting for an event counter.
                stableAdaptiveSlowSmoothingBlendForTick = stableFastTailContinuity;
            }
        }

        if (stableBoundsEnabled) {
            double rateInterval = stableHasMeasuredTickInterval
                ? MAX(scrollAnalysisResult.DEBUG_timeBetweenTicksRaw, _scrollConfig.velocityMeasurementIntervalMin)
                : 0;
            stableRateLimitPx = MFScrollOutputDistanceLimit(
                stableHasMeasuredTickInterval,
                rateInterval,
                _scrollConfig.velocityMeasurementIntervalMin,
                _scrollConfig.stableMaximumOutputSpeed,
                _scrollConfig.stableMaximumInitialDistance);

            if (pxForThisTickDouble > stableRateLimitPx) {
                DDLogDebug("Scroll.m: rate limiting px %.1f -> %.1f over %.2fms (modeled %.0f px/s, limit %.0f px/s)",
                           pxForThisTickDouble,
                           stableRateLimitPx,
                           rateInterval * 1000.0,
                           modeledOutputSpeed,
                           _scrollConfig.stableMaximumOutputSpeed);
                pxForThisTickDouble = stableRateLimitPx;
                stableRateLimited = YES;
            }
        }

        /// Every accepted physical report remains visible, even at extreme expert
        /// tuning values where the mathematical result falls below half a pixel.
        pxToScrollForThisTick = MAX(1, llround(pxForThisTickDouble));

        /// Debug
        DDLogDebug("Scroll.m: tuning v=%.1f rawV=%.1f units/s (units: %lld, dt: %.3f) -> pxPerUnit=%.1f -> px=%lld [ref=%.0f pxAtRef=%.0f gamma=%.2f]",
                   scrollSpeed, scrollAnalysisResult.DEBUG_velocityInUnitsPerSecondRaw,
                   unitsForThisTick, timeBetweenTicks, pxPerUnit, pxToScrollForThisTick,
                   _scrollConfig.refSpeed, _scrollConfig.pxAtRefSpeed, _scrollConfig.gamma);

        /// Validate
        if (pxToScrollForThisTick <= 0) {
            DDLogError("Scroll.m: pxForThisTick is smaller equal 0. This is invalid. Exiting. scrollSpeed: %f, pxForThisTick: %lld", scrollSpeed, pxToScrollForThisTick);
            assert(false);
        }
        
        /// Debug
        DDLogDebug("Scroll.m: consecTicks: %lld, consecSwipes: %lld, consecSwipesFree: %f", scrollAnalysisResult.consecutiveScrollTickCounter, scrollAnalysisResult.DEBUG_consecutiveScrollSwipeCounterRaw, scrollAnalysisResult.consecutiveScrollSwipeCounter);
        DDLogDebug("Scroll.m: timeBetweenTicks: %f, timeBetweenTicksRaw: %f, diff: %f, ticks: %lld", scrollAnalysisResult.timeBetweenTicks, scrollAnalysisResult.DEBUG_timeBetweenTicksRaw, scrollAnalysisResult.timeBetweenTicks - scrollAnalysisResult.DEBUG_timeBetweenTicksRaw, scrollAnalysisResult.consecutiveScrollTickCounter);
    }

    /// Direction cancellation is independent of the selected acceleration source. Keeping it inside the custom
    /// acceleration branch left System/Apple acceleration able to append the reversed tick to the old gesture.
    /// Cancel the old session, then continue below so the physical reversal report is still delivered immediately.
    if (scrollAnalysisResult.scrollDirectionDidChange) {
        DDLogInfo("MFSCROLL_DIRECTION: action=cancel-old-session appleAcceleration=%d keepCurrentTick=1",
                   _scrollConfig.useAppleAcceleration);
        [_animator cancel];
    }
    
    ///
    /// Send scroll events
    ///

    if (pxToScrollForThisTick == 0) {
        
        DDLogWarn("Scroll.m: pxToScrollForThisTick is 0");
        
    } else if (!_scrollConfig.smoothEnabled) {
        
        /// Send scroll event directly - without the animator. Will scroll all of pxToScrollForThisTick at once.
        sendScroll(pxToScrollForThisTick, scrollDirection, NO, kMFAnimationCallbackPhaseNone, kMFMomentumHintNone, _scrollConfig, _modifications, zoomGestureGeneration);
        
    } else {
        
        /// Send scroll events through animator, spread out over time.

        /// Create config-copy for animation-callback-block
        ///  Edit: Turned copying off now, since it's extremely slow. I don't think this is necessary with the current architecture (the `_scrollConfig` is a reference into a cache. When the scrollConfig updates the cache is deleted but this reference should still be valid)
        
//        ScrollConfig *configCopyForBlock = [_scrollConfig copy];
        ScrollConfig *configCopyForBlock = _scrollConfig;
        MFScrollModificationResult modificationsForBlock = _modifications;
        
        /// Start animation
        
        [_animator startWithParams:^NSDictionary<NSString *,id> * _Nonnull(Vector valueLeftVec, BOOL isRunning, Curve *animationCurve, Vector currentSpeed) {
            
            /// Validate
            assert(valueLeftVec.x == 0 || valueLeftVec.y == 0);
            
            /// Link to main screen
            ///     - This used to be above in the `isFirstConsecutive` section. Maybe it fits better there?
            ///     - (Sep 2024) This code was dead in MMF 3.0.0 - 3.0.2. It was re-activated in 3.0.3 by adding `[ScrollUtility updateMouseDidMoveWithEvent:]` in Scroll.m which was commented out. I really hope this doesn't lead to any new race-conditions / crashes. I tested it superficially, and I tried to think it through and didn't find issues, also people who used the 3.0.2-vcoba-2 build didn't seem to experience crashes, and that build had this change. That makes me relatively confident.
            ///     - (Sep 2024) There's a race condition on `ScrollUtility.mouseDidMove`, since `startWithParams:` dispatches async to another queue than the queue where .mouseDidMove is updated. (The heavyProcessing queue.)
            ///                         However, this should not lead to grave problems. Worst case, the `[_animator linkToMainScreen_Unsafe]` is not called even though the mouse moved, or it might be called several times in a row, even though the mouse didn't actually move in between.
            /// Fork: the display-link is now re-bound to the display under the pointer on every fresh scroll
            ///     (see the `linkToDisplayUnderMousePointerWithEvent:` call in the `firstConsecutive` block above),
            ///     so the old `mouseDidMove && !isRunning -> linkToMainScreen_Unsafe` relink is removed. It bound to
            ///     the wrong display (`NSScreen.mainScreen`) and, being gated on `!isRunning`, couldn't relink
            ///     mid-momentum — which is exactly the multi-monitor freeze it was supposed to prevent.
            
            /// Declare result dict (animator start params)
            NSMutableDictionary *p = [NSMutableDictionary dictionary];
            
            /// Get px that the animator still wants to scroll
            double pxLeftToScroll = 0.0;
            
            if (isRunning) {
                
                double distanceLeft = magnitudeOfVector(valueLeftVec);
                
                BOOL isSwipeSequenceStart = scrollAnalysisResult.consecutiveScrollTickCounter == 0 && scrollAnalysisResult.consecutiveScrollSwipeCounter == 0;
                
                if (isSwipeSequenceStart) { /// Checking for isReceiving here leads to lost input when the computer is slow
                    
                    /// Reset pxLeftToScroll
                    pxLeftToScroll = 0.0;
                    [_animator resetSubPixelator_Unsafe];
                    
                } else if ([animationCurve isKindOfClass:SimpleBezierHybridCurve.class]) {
                    
                    assert(false); /// Unused - remove
                    
                    SimpleBezierHybridCurve *c = (SimpleBezierHybridCurve *)animationCurve;
                    pxLeftToScroll = [c baseDistanceLeftWithDistanceLeft: distanceLeft]; /// If we feed valueLeft instead of baseValueLeft back into the animator, it will lead to unwanted acceleration
                } else {
                    pxLeftToScroll = distanceLeft;
                }
            } else {
                pxLeftToScroll = 0.0;
                [_animator resetSubPixelator_Unsafe]; /// Maybe it would make more sense to do this automatically inside the animator? That might lead to problems with click and drag smoothing.
                /// Validate
                //                assert(isZeroVector(currentSpeed));
            }
            
            /// Debug
            DDLogDebug("Scroll.m: animation init - current speed: (%f, %f)", currentSpeed.x, currentSpeed.y);
            
            /// Bound carry-over by time, not by an arbitrary pixel count. At normal speed the generous 200ms
            /// horizon is effectively inactive. As input reaches the rate ceiling it contracts to 85ms, preventing
            /// overload from becoming a long queue that continues drifting after the ring stops.
            double stableFastness = stableBoundsEnabled
                ? CLIP((stableOutputSpeedRatio - 0.5) / 0.5, 0.0, 1.0)
                : 0.0;
            double slowToFastCarryRatio = 0.200 / 0.070;
            double stableCarryLimitPx = configCopyForBlock.stableMaximumCarryDistance
                * (slowToFastCarryRatio + stableFastness * (1.0 - slowToFastCarryRatio));
            double stableDroppedCarryPx = 0;
            if (stableBoundsEnabled && pxLeftToScroll > stableCarryLimitPx) {
                stableDroppedCarryPx = pxLeftToScroll - stableCarryLimitPx;
                pxLeftToScroll = stableCarryLimitPx;
            }

            /// Calculate distance to scroll
            double delta = pxToScrollForThisTick + pxLeftToScroll;
            
            /// Get curve params
            MFScrollAnimationCurveParameters *pCurve = configCopyForBlock.animationCurveParams;
            
            /// Get baseDuration
            
            double baseDuration;
            double effectiveSmoothnessAmount = configCopyForBlock.u_smoothnessAmount;
            
            if (pCurve.baseMsPerStep != -1) {
                
                baseDuration = (double)pCurve.baseMsPerStep/1000.0;
                
            } else {
                
                /// Use curve for baseDuration instead of constant
                /// Notes:
                /// - The idea is to speed up animations as the user scrolls the wheel faster.
                /// - This is currently used for the `Smoothness: Regular` setting.
                
                /// Gather info
                
                Curve *baseTimeCurve    = pCurve.baseMsPerStepCurve;
                double baseTimeStart    = [baseTimeCurve evaluateAt:0.0]; /// The non-sped-up/maximum duration for the baseCurve
                double baseTimeEnd      = [baseTimeCurve evaluateAt:1.0];
                double configuredTickStart = configCopyForBlock.animationTickStart;
                double tickStart        = MIN(configuredTickStart, baseTimeStart);
                /// ^ Fork: was `consecutiveScrollTickIntervalMax`. Those two were the same constant (160ms) but mean
                ///     different things, and we've since raised the max to ~500ms so a slow ring counts as one
                ///     continuous scroll. Left coupled, that would re-anchor this curve: a 260ms tick would sample
                ///     mid-curve and get a *shorter* animation (~415ms -> ~172ms) exactly when it needs a longer one.
                ///     `animationTickStart` keeps the duration mapping where upstream tuned it.
                double tickEnd          = configCopyForBlock.consecutiveScrollTickIntervalMin;
                double tick             = stableAdaptiveControlEnabled
                    ? stableAnimationCadenceIntervalForTick
                    : scrollAnalysisResult.timeBetweenTicks;
                
                /// Adjust tickStart
                /// Explanation:
                /// - This is quite confusing. I think behind this design is the idea that the baseCurve is the part of the animation that feels like the user is directly pushing the page. (Whereas the rest of the curve feels more like the page keeps sliding after the user pushed it). This code is an approximation of the idea that only when the duration between the physical ticks of the users scrollwheel become shorter than the duration of this baseAnimation, should we start to speed up the baseAnimation. And that increases this physical relationship between the duration of the baseAnimation and the time between scrollwheel ticks. The extreme of this idea would be to try and make the duration of the base animation exactly equal to the time between scrollwheel ticks. But I think I tried that and it felt shitty (Not totally sure at the moment)
                /// - Overall this is quite confusing and complex to understand. Maybe we should remove it.
                /// - Update: This is also pretty much never used atm I think.
                
                if (configuredTickStart > baseTimeStart) {
                    DDLogDebug("Scroll.m: animation init - baseMsPerStepCurve - adjusting tickStart from %f to baseTimeStart: %f", configuredTickStart, tickStart);
                    assert(false);
                }
                
                /// Adjust tick
                /// Notes:
                /// - Scroll analyzer sets tick to `DBL_MAX` to signify that there are no previous consecutive ticks. (Not sure if  that's a great idea) We have to set it to a sendible value here so the scaling Math doesn't break.
                
                if (tick == DBL_MAX) {
                    tick = configCopyForBlock.consecutiveScrollTickIntervalMax;
                }
                
                /// TESTING
//                tick = _scrollConfig.consecutiveScrollTickIntervalMax + 1.0;
                
                /// Ensure that `tick <= max`
                ///
                /// Notes:
                /// - Asserting this apparently caused the crash in 3.0.2 from https://github.com/noah-nuebling/mac-mouse-fix/issues/988
                /// - To address this we turned off asserts in release builds by adding the NDEBUG preprocessor macro. For release builds, we're trying to recover by capping `tick` to `max` here, to smoothly recover if this bug happens.
                ///
                /// Discussion:
                /// - I looked at the code inside ScrollAnalyzer.m which generates the `tick` values and and I couldn't find a reason why `tick` would ever exceed `max` (aka `_scrollConfig.consecutiveScrollTickIntervalMax`).
                /// - The only idea I have for how this might happen is if the `max` changes between now and when the `scrollAnalysisResult` was calculated? The max *can* change, when quickScroll mod is activated. But since the `_scrollConfig` should only ever change on the first consecutiveTick and then the scrollAnalysis is made based on the new `_scrollConfig`... I still don't understand how it could lead to tick being `>` max here. So I'm not sure this is it.
                /// - The issue also apparently went away with the 3.0.2-v-coba which returned to the classic animator scheduling. No idea how that could play a role. This animation-init-code right here is run on the animator queue, so it might be indirectly affected by the animation-callback-scheduling changes between the different vcoba builds. But I don't understand how it could lead to this crash. Maybe have to think about it more.
                /// - One other idea is that the lower framerates in 3.0.2 could have indirectly caused problems somehowww, but one user also said the crashes didn't coincide with their computer being slow, so idk. (In this GH comment: https://github.com/noah-nuebling/mac-mouse-fix/issues/988#issuecomment-2187647181)
                /// - One possibility to consider is that we symbolicated the crashlog wrong? But I'm very confident we didn't.
                ///     - We used this command to symbolicate: `atos -arch arm64 -o ~/Downloads/dSYMs/Mac\ Mouse\ Fix\ Helper.app.dSYM/Contents/Resources/DWARF/Mac\ Mouse\ Fix\ Helper -l 0x100c3c000 0x100c4e44c` where the MMF Binary Image Address is the first and the Stacktrace Address is the second of the two hex numbers at the end. (you can get both of those from the crash report) The result is `__heavyProcessing_block_invoke (in Mac Mouse Fix Helper) (Scroll.m:621)`, and `Scroll.m:621` is the exactly location of an assert statement in the 3.0.2 source code (This assert probably caused the crash). If I put in any other hex numbers from the crash report I get gibberish. I'm pretty sure the symbolication is correct.
                ///     - In [this mail](message:<5F9539CA-3097-4E29-B83E-4B91784AD3AB@platten.me>) by Jack Platten, he also attached a crashlog and it also points to `Scroll.m:621` even though the hex numbers are totally differnt. So I'm very certain now that the symbolication is correct.
                ///
                /// Also see:
                /// - For further discussion, see the "Ensure that `tick <= max`" section inside `ScrollAnalyzer.m`
                
                if (tick > configCopyForBlock.consecutiveScrollTickIntervalMax && tick != DBL_MAX) {
                    double invalidTick = tick;
                    tick = configCopyForBlock.consecutiveScrollTickIntervalMax;
                    DDLogError("Scroll.m: animation init - tickTime is over max. This is a bug but we can recover. tickTime: %f cappedTickTime: %f", invalidTick, tick);
                    assert(false);
                };
                
                /// Scale timeBetweenTicks to unit
                double unitTick = [Math scaleWithValue:tick
                                                  from:[[Interval alloc] initWithStart:tickStart end:tickEnd]
                                                    to:Interval.unitInterval
                                      allowOutOfBounds:YES];
                unitTick = CLIP(unitTick, 0.0, 1.0);
                
                /// Sample curve
                double b = [baseTimeCurve evaluateAt:unitTick];
                baseDuration = (double)b/1000.0;
                
                /// Debug
                DDLogDebug("Scroll.m: animation init - baseMsPerStepCurve - calculating animation baseDuration - baseTimeEnd: %.1f, baseBaseTimeStart: %.1f, tick: %.1f, tickEnd: %.1f, tickStart: %1.f, consecutiveScrollTickIntervalMax: %.1f, result: %.1f", baseTimeEnd, baseTimeStart, tick*1000, tickEnd*1000, tickStart*1000, configCopyForBlock.consecutiveScrollTickIntervalMax*1000, baseDuration*1000);
            }

            /// The first report has no reliable velocity and is normally only ~20px. A short directly-driven phase
            /// makes that small distance visible immediately instead of presenting several one-pixel frames that
            /// feel like an input delay. Later reports retain the user's full duration tuning.
            if (stableAdaptiveControlEnabled
                && (firstConsecutive || stableRestartAfterExpiredFastTailForTick)) {
                baseDuration = MIN(baseDuration, configCopyForBlock.stableInitialResponseBaseDurationMax);
            }

            /// Very slow TB800 movement produces sparse change reports, so the fixed slider value can expose each
            /// report as a separate short burst. Blend extra time in only at the bottom of the speed range. The
            /// animation parameters above already contain the slider's fixed duration factor, so apply only the
            /// ratio between the adaptive factor and that fixed factor here.
            double effectiveOpeningDurationCap =
                configCopyForBlock.stableInitialResponseBaseDurationMax;
            if (stableAdaptiveControlEnabled) {
                double selectedSmoothness = configCopyForBlock.u_smoothnessAmount;
                double slowSmoothness = MAX(selectedSmoothness, configCopyForBlock.u_slowSmoothnessAmount);
                double transitionUnit = CLIP(stableOutputSpeedRatio
                    / configCopyForBlock.u_adaptiveSmoothnessEndSpeedRatio, 0.0, 1.0);
                double smoothTransition = transitionUnit * transitionUnit * (3.0 - 2.0 * transitionUnit);
                double speedAdaptiveSmoothness = slowSmoothness
                    + smoothTransition * (selectedSmoothness - slowSmoothness);
                effectiveSmoothnessAmount = selectedSmoothness
                    + stableAdaptiveSlowSmoothingBlendForTick
                    * (speedAdaptiveSmoothness - selectedSmoothness);

                double selectedDurationFactor = 0.4 + selectedSmoothness * 1.2;
                double effectiveDurationFactor = 0.4 + effectiveSmoothnessAmount * 1.2;
                double adaptiveDurationRatio =
                    effectiveDurationFactor / selectedDurationFactor;
                baseDuration *= adaptiveDurationRatio;
                effectiveOpeningDurationCap *= adaptiveDurationRatio;
            }
            if (stableSlowCadenceContinuationForTick) {
                /// Aim the full hybrid response at the observed sparse cadence. TouchAnimator's biased subpixelator
                /// still emits a pixel on the first display frame, while the remaining distance is distributed far
                /// enough to overlap the likely next report. Fade that target out over the stale end of cadence
                /// memory so a resumed first report cannot look stuck; a faster report still replans immediately.
                baseDuration = MFScrollSlowCadenceBaseDuration(
                    baseDuration,
                    stableSlowCadenceDurationReferenceForTick,
                    configCopyForBlock.stableSlowCadenceBaseDurationRatio,
                    configCopyForBlock.stableSlowCadenceBaseDurationMax,
                    stableSlowCadenceContinuationBlendForTick);
            }
            if (stableStoppedSharpDecelerationTailForTick) {
                /// Captured weak restarts were abrupt low-unit deceleration edges whose preceding animation had
                /// already ended. Keep the current report immediate and preserve its full distance, but do not
                /// spread that small stopped response across the maximum slow-smoothing duration.
                double uncappedSharpDecelerationBaseDuration = baseDuration;
                baseDuration = MFScrollStoppedSharpDecelerationBaseDurationCap(
                    baseDuration,
                    effectiveOpeningDurationCap);
                DDLogInfo("MFSCROLL_ADAPTIVE: cadence=measured units=%lld modeledV=%.1f previousModeledV=%.1f speedRatio=%.3f animatorRunning=0 openingCapMs=%.1f uncappedBaseMs=%.1f baseMs=%.1f action=cap-stopped-sharp-deceleration-tail",
                           unitsForThisTick,
                           stableModeledOutputSpeedForTick,
                           stablePreviousModeledOutputSpeedForTick,
                           stableModeledOutputSpeedForTick
                               / stablePreviousModeledOutputSpeedForTick,
                           effectiveOpeningDurationCap * 1000.0,
                           uncappedSharpDecelerationBaseDuration * 1000.0,
                           baseDuration * 1000.0);
            }
            if (stableIdleWakeOpeningCapBlendForTick > 0.0) {
                /// Keep the whole early hardware ramp inside report one's responsive envelope. Selecting the
                /// adaptive cap for a live retarget changed the same opening from 80ms on report one to roughly
                /// 130ms on report two. The later linear fade still reaches zero continuously, so ordinary
                /// extremely-slow cadence resumes without a report-count transition.
                double uncappedIdleWakeBaseDuration = baseDuration;
                double selectedIdleWakeOpeningCap = MFScrollIdleWakeBaseDurationCap(
                    configCopyForBlock.stableInitialResponseBaseDurationMax,
                    effectiveOpeningDurationCap);
                double cappedIdleWakeBaseDuration = MIN(
                    uncappedIdleWakeBaseDuration,
                    selectedIdleWakeOpeningCap);
                baseDuration = uncappedIdleWakeBaseDuration
                    + stableIdleWakeOpeningCapBlendForTick
                    * (cappedIdleWakeBaseDuration - uncappedIdleWakeBaseDuration);
                DDLogInfo("MFSCROLL_ADAPTIVE: cadence=measured idleGapMs=%.1f idleElapsedMs=%.1f wakeBlend=%.2f smoothness=%.2f animatorRunning=%d openingCapMs=%.1f adaptiveCapMs=%.1f uncappedBaseMs=%.1f baseMs=%.1f action=cap-idle-wake-ramp",
                           stableIdleWakeOpeningGapForTick * 1000.0,
                           stableIdleWakeElapsedForTick * 1000.0,
                           stableIdleWakeOpeningCapBlendForTick,
                           effectiveSmoothnessAmount,
                           isRunning,
                           selectedIdleWakeOpeningCap * 1000.0,
                           effectiveOpeningDurationCap * 1000.0,
                           uncappedIdleWakeBaseDuration * 1000.0,
                           baseDuration * 1000.0);
            }
            if (stableRestartAfterExpiredCloseReversalForTick) {
                double uncappedCloseReversalRestartBaseDuration = baseDuration;
                baseDuration = MFScrollStoppedCloseReversalBaseDurationCap(
                    baseDuration,
                    effectiveOpeningDurationCap);
                DDLogInfo("MFSCROLL_ADAPTIVE: cadence=measured gapMs=%.1f smoothness=%.2f animatorRunning=%d openingCapMs=%.1f uncappedBaseMs=%.1f baseMs=%.1f action=cap-stopped-close-reversal-continuation",
                           physicalInputGap * 1000.0,
                           effectiveSmoothnessAmount,
                           isRunning,
                           effectiveOpeningDurationCap * 1000.0,
                           uncappedCloseReversalRestartBaseDuration * 1000.0,
                           baseDuration * 1000.0);
            }
            double acceleratingRampTargetSpeed = delta / baseDuration;
            double acceleratingRampAnimatorSpeed = magnitudeOfVector(currentSpeed);
            if (MFScrollShouldCapAcceleratingLowUnitRamp(
                    stableAdaptiveControlEnabled,
                    stableHasMeasuredTickInterval,
                    unitsForThisTick,
                    scrollDelta,
                    stableModeledOutputSpeedForTick,
                    stablePreviousModeledOutputSpeedForTick,
                    stableSlowCadenceSpeedMaxForTick,
                    acceleratingRampAnimatorSpeed,
                    acceleratingRampTargetSpeed)) {
                double uncappedAcceleratingRampBaseDuration = baseDuration;
                baseDuration = MIN(baseDuration, effectiveOpeningDurationCap);
                DDLogInfo("MFSCROLL_ADAPTIVE: cadence=measured units=%lld pointPx=%lld modeledV=%.1f previousModeledV=%.1f currentV=%.1f oldTargetV=%.1f openingCapMs=%.1f uncappedBaseMs=%.1f baseMs=%.1f action=cap-accelerating-low-unit-ramp",
                           unitsForThisTick,
                           scrollDelta,
                           stableModeledOutputSpeedForTick,
                           stablePreviousModeledOutputSpeedForTick,
                           acceleratingRampAnimatorSpeed,
                           acceleratingRampTargetSpeed,
                           effectiveOpeningDurationCap * 1000.0,
                           uncappedAcceleratingRampBaseDuration * 1000.0,
                           baseDuration * 1000.0);
            }
            if (stableFastTailReport) {
                double durationScale = configCopyForBlock.stableFastTailDurationScale
                    + stableFastTailContinuity * (1.0 - configCopyForBlock.stableFastTailDurationScale);
                baseDuration *= durationScale;
            }
            if (stableRestartAfterExpiredFastTailForTick) {
                DDLogInfo("MFSCROLL_TAIL: action=restart-after-expired-tail gapMs=%.1f smoothness=%.2f openingCapMs=%.1f baseMs=%.1f",
                           physicalInputGap * 1000.0,
                           effectiveSmoothnessAmount,
                           configCopyForBlock.stableInitialResponseBaseDurationMax * 1000.0,
                           baseDuration * 1000.0);
            }

            /// Get curve and duration
            
            double duration;
            Curve *c;
            BOOL velocityRetargeted = NO;
            double retargetStartSpeed = magnitudeOfVector(currentSpeed);
            double retargetTargetSpeed = delta / baseDuration;
            double retargetBlendDuration = 0.0;
            
            if (!pCurve.useDragCurve) {
                
                DDLogDebug("Scroll.m: animation init – animation curve base");
                
                c = pCurve.baseCurve;
                duration = baseDuration;
                
            } else {
                
                DDLogDebug("Scroll.m: animation init – animation curve hybrid");
                
                /// speedSmoothing
                
                Bezier *baseCurve = pCurve.baseCurve;
                double speedSmoothing = pCurve.speedSmoothing;

                /// Regular scrolling normally uses a linear base curve. Restarting that curve for every hardware
                /// report preserves remaining distance but throws away the animator's velocity: output jumps to the
                /// new curve's average speed. Build a short cubic transition whose initial slope exactly matches the
                /// current output speed and whose exit slope reaches the new distance/duration target. New input
                /// therefore begins accelerating on this report while velocity remains continuous across the frame.
                if (stableAdaptiveControlEnabled
                    && isRunning
                    && baseCurve != nil
                    && retargetStartSpeed > 0.0
                    && delta > 0.0
                    && baseDuration > 0.0) {
                    retargetBlendDuration = MIN(24.0 / 1000.0, baseDuration * 0.25);
                    double blendUnit = CLIP(retargetBlendDuration / baseDuration, 0.001, 0.25);
                    double startSlope = retargetStartSpeed * baseDuration / delta;
                    double p2x = 1.0 - blendUnit;
                    double p2y = p2x; /// Exit slope 1.0 -> `delta / baseDuration`.
                    double p1x = blendUnit;
                    if (startSlope > 0.0 && startSlope * p1x > p2y) {
                        p1x = MAX(0.001, p2y / startSlope);
                    }
                    double p1y = CLIP(startSlope * p1x, 0.0, p2y);
                    baseCurve = [[Bezier alloc] initWithControlPoints:@[
                        @[@0, @0],
                        @[@(p1x), @(p1y)],
                        @[@(p2x), @(p2y)],
                        @[@1, @1],
                    ] defaultEpsilon:0.01];
                    velocityRetargeted = YES;
                }
                if (baseCurve == nil) {
                    
                    /// Create baseCurve as speedSmoothing curve.
                    /// Notes: 
                    /// - The idea is to make the initial speed of the baseCurve equal to the current speed. The speedSmoothing amount determines how long the curve will take to move away from the current speed.
                    /// - Currently using 0.01 epsilon for Bezier curve. This gives a little different results than even lower epsilons in MOS scroll analyzer. But it's not really noticable otherwise. Maybe we should do more extensive testing what the optimal epsilon is here when it comes to performance vs smoothness.
                    
                    /// Validate
                    assert(0.0 <= speedSmoothing && speedSmoothing <= 1.0);
                    
                    Vector baseCurveStartDirection = {
                        .y = magnitudeOfVector(currentSpeed)    / delta,
                        .x = 1                                  / ((double)baseDuration/1000.0),
                    };
                    Vector baseCurveP1 = vectorFromDeltaAndDirectionVector(speedSmoothing, baseCurveStartDirection);
                    baseCurve = [[Bezier alloc] initWithControlPoints:@[@[@0, @0], @[@(baseCurveP1.x), @(baseCurveP1.y)], /*@[@1, @1],*/ @[@1, @1]] defaultEpsilon:0.01];
                    
                    DDLogDebug("Scroll.m: animation init - start speed smoothing p1 - currentSpeed: %@, bezier: %@", vectorDescription(unitVector(baseCurveP1)), [baseCurve stringTraceWithStartX:0 endX:1 nOfSamples:10 bias:1]);
                }
                
                /// Create hybrid curve
                /// Increase release friction only near the overload ceiling. This leaves reading-speed Glide
                /// untouched while preventing a hard spin from inheriting the same long exponential tail.
                double effectiveDragCoefficient = pCurve.dragCoefficient;
                if (stableBoundsEnabled && pCurve.dragCoefficient < configCopyForBlock.stableFastDragCoefficient) {
                    effectiveDragCoefficient += stableFastness
                        * (configCopyForBlock.stableFastDragCoefficient - pCurve.dragCoefficient);
                }
                HybridCurve *hc = [[BezierHybridCurve alloc]
                     initWithBaseCurve:baseCurve
                     minDuration:baseDuration
                     distance:delta
                     dragCoefficient:effectiveDragCoefficient
                     dragExponent:pCurve.dragExponent
                     stopSpeed:pCurve.stopSpeed
                     distanceEpsilon:0.2];
                
                /// Get duration
                duration = hc.duration;
                
                /// Validate
                assert(fabs(hc.distance - delta) < 3);
                
                /// Debug
                DDLogDebug("Scroll.m: animation init - Created hybrid curve with distance %f, duration: %f", hc.distance, hc.duration);
                
                /// Assign
                c = hc;
            }
            
            
            /// Fill return dict
            p[@"duration"] = @(duration);
            p[@"vector"] = nsValueFromVector(vectorFromDeltaAndDirection(delta, scrollDirection));
            p[@"curve"] = c;

            /// Stable-engine tuning trace. One line per physical report is low-volume on the TB800 and exposes
            /// whether perceived drift comes from retained distance, the base curve, or the drag tail.
            double effectiveDragCoefficientForLog = pCurve.dragCoefficient;
            if (stableBoundsEnabled && pCurve.dragCoefficient < configCopyForBlock.stableFastDragCoefficient) {
                effectiveDragCoefficientForLog += stableFastness
                    * (configCopyForBlock.stableFastDragCoefficient - pCurve.dragCoefficient);
            }
            DDLogInfo("MFSCROLL_LEGACY: rawV=%.1f filteredV=%.1f modelScale=%.2f bounds=%d rawPx=%.1f tickPx=%lld rateCapPx=%.1f limited=%d retainedPx=%.1f carryCapPx=%.1f droppedPx=%.1f totalPx=%.1f currentV=%.1f smoothness=%.2f adaptiveBlend=%.2f cadenceKnown=%d slowCadence=%d cadenceTargetMs=%.1f cadenceDurationRefMs=%.1f retarget=%d targetV=%.1f blendMs=%.1f baseMs=%.1f durationMs=%.1f glideCoeff=%.2f cadenceMs=%.2f baseCadenceMs=%.2f direction=%ld",
                       scrollAnalysisResult.DEBUG_velocityInUnitsPerSecondRaw,
                       scrollAnalysisResult.velocityInUnitsPerSecond,
                       configCopyForBlock.velocityModelDistanceMultiplier,
                       stableBoundsEnabled,
                       pxForThisTickBeforeRateLimit,
                       pxToScrollForThisTick,
                       stableRateLimitPx,
                       stableRateLimited,
                       pxLeftToScroll,
                       stableCarryLimitPx,
                       stableDroppedCarryPx,
                       delta,
                       magnitudeOfVector(currentSpeed),
                       effectiveSmoothnessAmount,
                       stableAdaptiveSlowSmoothingBlendForTick,
                       stableHasMeasuredTickInterval,
                       stableSlowCadenceContinuationForTick,
                       stableSlowCadenceForTick * 1000.0,
                       stableSlowCadenceDurationReferenceForTick * 1000.0,
                       velocityRetargeted,
                       retargetTargetSpeed,
                       retargetBlendDuration * 1000.0,
                       baseDuration * 1000.0,
                       duration * 1000.0,
                       effectiveDragCoefficientForLog,
                       scrollAnalysisResult.timeBetweenTicks == DBL_MAX ? 0.0 : scrollAnalysisResult.timeBetweenTicks * 1000.0,
                       stableAnimationCadenceIntervalForTick == DBL_MAX ? 0.0 : stableAnimationCadenceIntervalForTick * 1000.0,
                       (long)scrollDirection);
            
            /// Debug
            DDLogDebug("Scroll.m: animation init - Returning value: %@", p);
            if ((0)) {
                static double scrollDeltaSum = 0;
                scrollDeltaSum += labs(pxToScrollForThisTick);
                DDLogDebug("Scroll.m: Delta sum animation init: %f", scrollDeltaSum);
            }
            
            /// Return
            return p;
            
        } integerCallback:^(Vector distanceDeltaVec, MFAnimationCallbackPhase animationPhase, MFMomentumHint momentumHint) {
            
            /// This will be called each frame
            
            /// Debug
            DDLogDebug("Scroll.m: in-animator with vec: %@, phase: %d, momentum: %d", vectorDescription(distanceDeltaVec), animationPhase, momentumHint);
            
            /// Extract 1d delta from vec
            double distanceDelta = magnitudeOfVector(distanceDeltaVec);
            
            /// Get reference to copy of config specific for this block
            ///     Use this instead of the global `_scrollConfig` to avoid race conditions
            ScrollConfig *config = configCopyForBlock;
            
            /// Unsuspend
            if ((0)) { /// This is old stuff that should be removed I think [Jun 2 2025]
                if (animationPhase != kMFAnimationCallbackPhaseStart && animationPhase != kMFAnimationCallbackPhaseContinue) {
                    unsuspendDrivers();
                }
            }
            
            /// Validate
            assert(distanceDeltaVec.x == 0 || distanceDeltaVec.y == 0);
            
            if (distanceDelta == 0) {
                assert(animationPhase == kMFAnimationCallbackPhaseEnd || animationPhase == kMFAnimationCallbackPhaseCanceled);
            }
            /// Debug
            if ((0)) {
                static double scrollDeltaSummm = 0;
                scrollDeltaSummm += distanceDelta;
                DDLogDebug("Scroll.m: in-animator - delta sum: %f", scrollDeltaSummm);
                DDLogDebug("Scroll.m: in-animator - delta %f, animationPhase: %d, momentumHint: %d", distanceDelta, animationPhase, momentumHint);
            }
            
            /// Send scroll
            if (animationPhase == kMFAnimationCallbackPhaseStart) {
                DDLogInfo("MFSCROLL_LATENCY: inputToFirstOutputMs=%.2f inputQueueMs=%.2f",
                           MAX(0.0, (CACurrentMediaTime() - tickTS) * 1000.0),
                           inputQueueDelayMs);
            }
            legacyRecordOutput((int64_t)distanceDelta, scrollDirection);
            sendScroll(distanceDelta, scrollDirection, YES, animationPhase, momentumHint, config, modificationsForBlock, zoomGestureGeneration);
            
        }];
    }
    
    CFRelease(event);
}

#pragma mark - Send Scroll events

static void sendScroll(int64_t px, MFDirection scrollDirection, BOOL animated, MFAnimationCallbackPhase animationPhase, MFMomentumHint momentumHint, ScrollConfig *config, MFScrollModificationResult modifications, uint64_t zoomGestureGeneration) {
    
    /// Get x and y deltas
    
    int64_t dx = 0;
    int64_t dy = 0;
    
    if (scrollDirection == kMFDirectionUp) {
        dy = px;
    } else if (scrollDirection == kMFDirectionDown) {
        dy = -px;
    } else if (scrollDirection == kMFDirectionLeft) {
        dx = -px;
    } else if (scrollDirection == kMFDirectionRight) {
        dx = px;
    } else if (scrollDirection == kMFDirectionNone) {
        
    } else {
        assert(false);
    }
    
    /// Get params for sending event
    
    MFScrollOutputType outputType;
    
    if (!animated) {
        outputType = kMFScrollOutputTypeLineScroll;
    } else {
        if (config.animationCurveParams.sendGestureScrolls) {
            outputType = kMFScrollOutputTypeGestureScroll;
        } else {
            outputType = kMFScrollOutputTypeContinuousScroll;
        }
    }
    
    if (modifications.effectMod == kMFScrollEffectModificationZoom) {
        outputType = kMFScrollOutputTypeZoom;
    } else if (modifications.effectMod == kMFScrollEffectModificationRotate) {
        outputType = kMFScrollOutputTypeRotation;
    } else if (modifications.effectMod == kMFScrollEffectModificationFourFingerPinch) {
        outputType = kMFScrollOutputTypeFourFingerPinch;
    } else if (modifications.effectMod == kMFScrollEffectModificationCommandTab) {
        outputType = kMFScrollOutputTypeCommandTab;
    } else if (modifications.effectMod == kMFScrollEffectModificationThreeFingerSwipeHorizontal) {
        outputType = kMFScrollOutputTypeThreeFingerSwipeHorizontal;
    } /// kMFScrollEffectModificationHorizontalScroll is handled above when determining scroll direction
    
    /// Send event
    
    sendOutputEvents(dx, dy, outputType, animationPhase, momentumHint, config, zoomGestureGeneration);
}

/// Define output types

typedef enum {
    kMFScrollOutputTypeGestureScroll,
    kMFScrollOutputTypeContinuousScroll,
    kMFScrollOutputTypeLineScroll,
    kMFScrollOutputTypeFourFingerPinch,
    kMFScrollOutputTypeThreeFingerSwipeHorizontal,
    kMFScrollOutputTypeZoom,
    kMFScrollOutputTypeRotation,
    kMFScrollOutputTypeCommandTab,
} MFScrollOutputType;

/// Output

static void sendOutputEvents(int64_t dx, int64_t dy, MFScrollOutputType outputType, MFAnimationCallbackPhase animatorPhase, MFMomentumHint momentumHint, ScrollConfig *config, uint64_t zoomGestureGeneration) {
    
    /// Init eventPhase
    IOHIDEventPhaseBits eventPhase = kIOHIDEventPhaseUndefined;
    if (animatorPhase != kMFAnimationCallbackPhaseNone) {
        eventPhase = [TouchAnimator IOHIDPhaseWithAnimationCallbackPhase:animatorPhase];
    }

    /// Debug
    if (runningPreRelease()) {
        
        static CFTimeInterval lastTs = 0.0;
        CFTimeInterval ts = CACurrentMediaTime();
        CFTimeInterval tsDiff = ts - lastTs;
        lastTs = ts;
        
        DDLogDebug("Scroll.m: \nHNGG: Posting event from scrollwheel: dx: %lld, dy: %lld, outputType: %d, phase: %d, momentum: %d, time: %d", dx, dy, outputType, animatorPhase, momentumHint, (int)(tsDiff*1000));
    }
    
    /// Validate
    
    if (dx+dy == 0) {
        assert(eventPhase == kIOHIDEventPhaseEnded || eventPhase == kIOHIDEventPhaseCancelled);
    }
    
    /// Send events based on outputType
    
    if (outputType == kMFScrollOutputTypeGestureScroll) {
        
        /// --- GestureScroll ---
        
        if (!config.animationCurveParams.sendMomentumScrolls) {
            
            if (eventPhase != kIOHIDEventPhaseEnded) {
                
                /// Post event
                [GestureScrollSimulator postGestureScrollEventWithDeltaX:dx deltaY:dy phase:eventPhase autoMomentumScroll:YES invertedFromDevice:config.invertedFromDevice];
                
            } else {
                
                /// Post end event
                [GestureScrollSimulator postGestureScrollEventWithDeltaX:0.0 deltaY:0.0 phase:kIOHIDEventPhaseEnded autoMomentumScroll:YES invertedFromDevice:config.invertedFromDevice];
                
                /// Debug
                DDLogDebug("Scroll.m: THAT CALL where displayLinkkk is stopped from Scroll.m");
                
                /// Suppress momentumScroll
                /// - Only works if autoMomentumScroll is set to YES
                /// - ...That's because This architecture is so complicated but idk how to make it better. The idea behind it was that certain apps like Xcode have their own automatic momentumScrolling built in. To stop it you need to send an explicit 'momentumStop' event. Even if you haven't sent any other momentum events beforehand. Why not just send the momentumStop event directly? Here are our reasons (not sure if they are good) To lower the chances of any misbehaviour our approach was to simulate the trackpad behaviour as closely as possible. That means we start momentumScrolling automatically (hence `autoMomentumScroll:YES`) and then we simulate a finger touching the trackpad immediately. However, in this scenario, since we start and then stop the autoMomentumScroll immediately, the TouchAnimator which is started for autoMomentumScroll never calls its callback at all! So this is sort of nonsensical. Butttt we're also using `autoMomentumScroll:YES` for Click and Drag so I guess it might be simpler to do it this way since we need the autoMomentumScroll implementation anyways. Another reason for the architecture is that we decided to call the cancel callback from our autoMomentum TouchAnimator callback because that puts it inline with the other events sending and therefore makes stuff easier to think about (??) and provides more context info when we call the callback (?).
                
                [GestureScrollSimulator stopMomentumScroll];
            }
            
        } else { /// sendMomentumScrolls == true
            
            /// Validate
            assert(momentumHint != kMFMomentumHintNone);
            
            /// Store lastMomentumHint
            static MFMomentumHint lastMomentumHint = kMFMomentumHintNone;
            
            /// Get eventPhase and momentumPhase
            
            if (momentumHint == kMFMomentumHintGesture) { /// momentumHint is gesture
                
                if (lastMomentumHint == kMFMomentumHintMomentum) {
                    
                    /// Send momentum end event
                    [GestureScrollSimulator postMomentumScrollDirectlyWithDeltaX:0 deltaY:0 momentumPhase:kCGMomentumScrollPhaseEnd invertedFromDevice:config.invertedFromDevice];
                    
                    /// Set eventPhase to start
                    eventPhase = kIOHIDEventPhaseBegan;
                    
                    /// Debug
                    DDLogDebug("Scroll.m: \nHybrid event - momentum: (0, 0, %d) JJJ", kCGMomentumScrollPhaseEnd);
                }
                
                /// Send normal gesture scroll
                [GestureScrollSimulator postGestureScrollEventWithDeltaX:dx deltaY:dy phase:eventPhase autoMomentumScroll:NO invertedFromDevice:config.invertedFromDevice];
                
                /// Simulate tap to prevent momentum scrolling
                ///     - Send kIOHIDEventPhaseMayBegin and kIOHIDEventPhaseCancelled events to prevent momentum scrolling from starting in apps like Xcode
                ///     - This is the only way I found to reliably prevent auto-momentumscroll in when running iPad apps like Downpay.
                ///     - The MayBegin and Cancelled events are sent by a real trackpad when putting two fingers on the Trackpad and then lifting them off without actually scrolling. So I think we can think of these events simulating a quick tap with 2 fingers on the Trackpad.
                ///     - We're *only* ever sending kIOHIDEventPhaseMayBegin and kIOHIDEventPhaseCancelled events to simulate a tap to stop momentum scrolling. On a real Trackpad, they also only seem to occur for taps. We're currently simulating taps in Scroll.m (for scrollwheel scrolling) and GestureScrollSimulator.m (for Click and Drag scrolling) [Jul 2025]
                if (animatorPhase == kMFAnimationCallbackPhaseCanceled) {
                    assert(eventPhase == kIOHIDEventPhaseEnded);
                    
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseMayBegin autoMomentumScroll:NO invertedFromDevice:config.invertedFromDevice];
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseCancelled autoMomentumScroll:NO invertedFromDevice:config.invertedFromDevice];
                }
                
                /// Debug
                DDLogDebug("Scroll.m: \nHybrid event - gesture: (%lld, %lld, %d)", dx, dy, eventPhase);
                
            } else { /// momentumHint is momentum
                
                CGMomentumScrollPhase momentumPhase = kCGMomentumScrollPhaseNone;
                
                if (lastMomentumHint == kMFMomentumHintGesture) {
                    /// Momentum begins
                    
                    /// Send gesture end event
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseEnded autoMomentumScroll:NO invertedFromDevice:config.invertedFromDevice];
                    
                    /// Get momentum phase
                    momentumPhase = kCGMomentumScrollPhaseBegin;
                    
                    /// Debug
                    DDLogDebug("Scroll.m: \nHybrid event - gesture: (0, 0, %d) HHH", kIOHIDEventPhaseEnded);
                    
                } else if (lastMomentumHint == kMFMomentumHintMomentum) {
                    /// Momentum continues
                    
                    /// Get momentum phase
                    if (animatorPhase == kMFAnimationCallbackPhaseContinue) {
                        momentumPhase = kCGMomentumScrollPhaseContinue;
                    } else if (animatorPhase == kMFAnimationCallbackPhaseEnd || animatorPhase == kMFAnimationCallbackPhaseCanceled) {
                        momentumPhase = kCGMomentumScrollPhaseEnd;
                    } else {
                        assert(false);
                        DDLogDebug("Scroll.m: \nHybrid event - Assert fail >:(");
                    }
                } else {
                    assert(false);
                }
                
                /// Send momentum event
                [GestureScrollSimulator postMomentumScrollDirectlyWithDeltaX:dx deltaY:dy momentumPhase:momentumPhase invertedFromDevice:config.invertedFromDevice];
                
                /// Simulate tap to prevent momentum scrolling
                ///     [Jul 2025] Simulating the tap shouldn't usually be necessary for kMFAnimationCallbackPhaseEnd, since in that case the scrolling should naturally have slowed down to the point where there is no further automatic momentum scrolling. But Always doing it should make things more robust.
                ///     [Jul 2025] Doing this for kMFAnimationCallbackPhaseCanceled is necessary to get reliable scroll canceling in DownPay iPad app..
                if (animatorPhase == kMFAnimationCallbackPhaseEnd || animatorPhase == kMFAnimationCallbackPhaseCanceled) {
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseMayBegin autoMomentumScroll:NO invertedFromDevice:config.invertedFromDevice];
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseCancelled autoMomentumScroll:NO invertedFromDevice:config.invertedFromDevice];
                }
                
                /// Debug
                DDLogDebug("Scroll.m: \nHybrid event - momentum: (%lld, %lld, %d)", dx, dy, momentumPhase);
            }
            
            /// Update lastMomentumHint
            lastMomentumHint = momentumHint;
            if (animatorPhase == kMFAnimationCallbackPhaseEnd || animatorPhase == kMFAnimationCallbackPhaseCanceled) {
                DDLogDebug("Scroll.m: HNGG reset lastMomentumHint");
                lastMomentumHint = kMFMomentumHintNone;
            }
        }
        
    } else if (outputType == kMFScrollOutputTypeContinuousScroll) {
        
        /// --- ContinuousScroll ---

        /// Continuous output models a high-resolution wheel, not a trackpad-finger gesture. Keep both phase fields
        /// unset for the entire stream. Some apps (Telegram in the Jul 2026 trace) ignore standalone MomentumPhase
        /// events which have no matching ScrollPhase gesture; Chromium can conversely stall while a synthetic
        /// ScrollPhase session is open. Phase-less pixel-wheel events are the common semantics both app families
        /// accept. The animator still provides the same smoothing and glide—only the event classification changes.
        CGMomentumScrollPhase continuousMomentumPhase = kCGMomentumScrollPhaseNone;
        eventPhase = kIOHIDEventPhaseUndefined;
        
        /// Create base event
        
        /// Use the public scroll-event constructor instead of mutating a null event into type 22.
        /// Do not override its location: HID-posted events can move the cursor to the supplied point.
        /// Do not attach ScrollPhase to this wheel-style output. GestureScrollSimulator is the separate output path
        /// for events which intentionally emulate a trackpad gesture and provides the matching gesture event stream.
        CGEventRef event = CGEventCreateScrollWheelEvent(_eventSource, kCGScrollEventUnitPixel, 2, 0, 0);
        MFScrollMarkSyntheticEvent(event);
        CGEventSetTimestamp(event, (CGEventTimestamp)(CACurrentMediaTime() * NSEC_PER_SEC));
        CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, eventPhase);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventMomentumPhase, continuousMomentumPhase);
        
        /// Setup subpixelator
        
        static VectorSubPixelator *linePixelator = nil;
        
        if (linePixelator == nil) {
            linePixelator = [VectorSubPixelator biasedPixelator];
        }
        if (animatorPhase == kMFAnimationCallbackPhaseStart) {
            [linePixelator reset];
        }
        
        /// Get alt deltas
        ///     Maybe we should reuse `GestureScrollSimulator` -> `getDeltaVectors()` here. Basically does the same.
        
        double dyLine = ((double)dy)/10.0;
        double dxLine = ((double)dx)/10.0;
        
        Vector pixelatedLines = [linePixelator intVectorWithDoubleVector:_P(dxLine, dyLine)];
        
        /// Set deltas
        
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1, pixelatedLines.y);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1, dy);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, fixedScrollDelta(pixelatedLines.y));
        
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, pixelatedLines.x);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, dx);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, fixedScrollDelta(pixelatedLines.x));
        
        /// Log
        
        if (runningPreRelease()) {
            
            static double tsStart = 0;
            if (animatorPhase == kMFAnimationCallbackPhaseStart) {
                tsStart = CACurrentMediaTime();
            }
            double ts = CACurrentMediaTime();
            double timeSinceStart = ts - tsStart;
            
            DDLogDebug("Scroll.m: \nHNGG: Posting continuousScroll event: %@, momentumHint: %d, time: %d", scrollEventDescriptionWithOptions(event, YES, NO), momentumHint, (int)(timeSinceStart*1000));
        }
        
        /// Post event

        /// Post at the HID tap so the event follows the same routing path as physical wheel input.
        /// Our own HID tap immediately passes continuous events through, so this does not recurse into
        /// the scroll engine. Session-tap injection can bypass routing/gesture state that some apps use,
        /// which matches the captured failure: events were posted, but the target view stayed stuck.
        if (dx != 0 || dy != 0) {
            CGEventPost(kCGHIDEventTap, event);
        }
        CFRelease(event);

    } else if (outputType == kMFScrollOutputTypeLineScroll) {
        
        /// --- LineScroll ---
        
        /// We ignore the phases here
        
        if (dx+dy == 0) return;
        
        /// Create a real line-based scroll event.
        CGEventRef event = CGEventCreateScrollWheelEvent(_eventSource, kCGScrollEventUnitLine, 2, 0, 0);
        MFScrollMarkSyntheticEvent(event);
        CGEventSetTimestamp(event, (CGEventTimestamp)(CACurrentMediaTime() * NSEC_PER_SEC));
        
        /// Get line deltas
        ///     Line deltas are 1/10 of pixel deltas. See CGEventSource pixelsPerLine - it's 10
        double dyLine = ((double)dy) / 10;
        double dxLine = ((double)dx) / 10;
        
        /// Get line deltas as int
        ///     Int deltas are generally truncated but also rounded up to be at least 1 (or -1). This also happens in real events.
        int64_t dyLineInt = (int64_t)dyLine;
        int64_t dxLineInt = (int64_t)dxLine;
        if (fabs(dyLine) != 0 && llabs(dyLineInt) == 0) dyLineInt = mfsign(dyLine);
        if (fabs(dxLine) != 0 && llabs(dxLineInt) == 0) dxLineInt = mfsign(dxLine);
        
        /// Get line deltas as fixed point number
        int64_t dyLineFixed = fixedScrollDelta(dyLine);
        int64_t dxLineFixed = fixedScrollDelta(dxLine);
        
        /// Set fields
        ///     We used to have a comment here saying that the `FixedPtDelta`s were automatically being set when setting the `PointDelta`s. But under the Ventura Beta this doesn't seem to be true, so we're setting it manually.
        
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1, dyLineInt);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1, dy);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, dyLineFixed);
        
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, dxLineInt);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, dx);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, dxLineFixed);
        
        /// Debug
        DDLogDebug("Scroll.m: Posting lineScroll event – %@", CGScrollWheelEventDescription(event));
        
        /// Send
        CGEventPost(kCGSessionEventTap, event);
        
        /// Release
        CFRelease(event);
        
    } else if (outputType == kMFScrollOutputTypeZoom) {
        
        /// --- Zoom ---

        /// `Began` is emitted synchronously with the first physical zoom input and
        /// `Ended` is emitted by the corresponding session reset (modifier release,
        /// mode exit, target change, etc.). An animator response ending between slow
        /// wheel reports must not split that one physical gesture into discarded
        /// one-frame Chromium gestures.
        if (animatorPhase == kMFAnimationCallbackPhaseEnd
            || animatorPhase == kMFAnimationCallbackPhaseCanceled) {
            return;
        }
        
        double eventDelta = (dx + dy)/800.0; /// This works because, if dx != 0 -> dy == 0, and the other way around.

        /// Invert zoom before posting the gesture delta so both directions retain identical scaling.
        if (config.u_invertZoom) {
            eventDelta = -eventDelta;
        }

        sendZoomChangeIfActive(eventDelta, zoomGestureGeneration);
        
    } else if (outputType == kMFScrollOutputTypeRotation) {
        
        /// --- Rotation ---
        /// TODO: Consider inverting sign with `-` so that scrolling down coincides with rotating clockwise
        
        double eventDelta = (dx + dy)/8.0; /// This works because, if dx != 0 -> dy == 0, and the other way around.
        
        [TouchSimulator postRotationEventWithRotation:eventDelta phase:eventPhase];
        
    } else if (outputType == kMFScrollOutputTypeFourFingerPinch
               || outputType == kMFScrollOutputTypeThreeFingerSwipeHorizontal) {
        
        /// --- FourFingerPinch or ThreeFingerSwipeHorizontal ---
        
        MFDockSwipeType type;
        double eventDelta;
        
        if (outputType == kMFScrollOutputTypeFourFingerPinch) {
            type = kMFDockSwipeTypePinch;
            eventDelta = -(dx + dy)/600.0; /// We negate here to counter the invertedFromDevice flag. The goal is that zooming and dockSwipe pinch feel congruent, just like on the trackpad.
            /// ^ Launchpad feels a lot less sensitive than Show Desktop, but to improve this we'd have to somehow detect which of both is active atm.
        } else if (outputType == kMFScrollOutputTypeThreeFingerSwipeHorizontal) {
            type = kMFDockSwipeTypeHorizontal;
            eventDelta = -(dx + dy)/600.0; /// Should this be different than the pinch scaling?
        } else {
            assert(false);
        }
        
        [TouchSimulator postDockSwipeEventWithDelta:eventDelta type:type phase:eventPhase invertedFromDevice:config.invertedFromDevice];
        
    } else if (outputType == kMFScrollOutputTypeCommandTab) {
        
        /// --- CommandTab ---
        
        double d = -(dx + dy);
        
        if (d == 0) return;
        
        /// Get state
        
        static bool appSwitcherWasOpenedByCurrentConsecutiveTicks = false; /// Use this to make first swipe only create one selection change
        bool isFirstConsecutive = _lastScrollAnalysisResult.consecutiveScrollTickCounter == 0; /// When commandTab is active, we only get one call of this function per Tick (animator is disabled), that's why we can do this
        
        /// Open app switcher
        
        if (!_appSwitcherIsOpen) {
            sendKeyEvent(55, kCGEventFlagMaskCommand, true);
            sendKeyEvent(48, kCGEventFlagMaskCommand, true);
            sendKeyEvent(48, kCGEventFlagMaskCommand, false);
            _appSwitcherIsOpen = YES;
            appSwitcherWasOpenedByCurrentConsecutiveTicks = true;
        } else {
            if (isFirstConsecutive)
                appSwitcherWasOpenedByCurrentConsecutiveTicks = false;
        }
        
        /// Select apps
        
        if (!appSwitcherWasOpenedByCurrentConsecutiveTicks) {
            
            if (d > 0) {
                sendKeyEvent(48, kCGEventFlagMaskCommand, true);
                sendKeyEvent(48, kCGEventFlagMaskCommand, false);
            } else {
                sendKeyEvent(48, kCGEventFlagMaskCommand | kCGEventFlagMaskShift, true);
                sendKeyEvent(48, kCGEventFlagMaskCommand | kCGEventFlagMaskShift, false);
            }
        }
        
    } else {
        assert(false);
    }
    
}

/// Output - Helper funcs

static BOOL _appSwitcherIsOpen = NO;

+ (void)appSwitcherModificationHasBeenDeactivated {
    
    if (_appSwitcherIsOpen) { /// Not sure if this check is necessary. Should only be called when the appSwitcher is open.
        sendKeyEvent(55, 0, false);
        _appSwitcherIsOpen = NO;
    }
}

void sendKeyEvent(CGKeyCode keyCode, CGEventFlags flags, bool keyDown) {
    
    CGEventTapLocation tapLoc = kCGSessionEventTap;
    
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, keyCode, keyDown);
    CGEventSetFlags(event, flags);
    
    CGEventPost(tapLoc, event);
    CFRelease(event);
}

@end
