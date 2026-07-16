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
#import "DisplayLink.h"

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
static CGEventSourceRef _eventSource;

static dispatch_queue_t _scrollQueue;

static TouchAnimator *_animator;
static DisplayLink *_motionDisplayLink;
static VectorSubPixelator *_motionSubPixelator;

static AXUIElementRef _systemWideAXUIElement; // TODO: should probably move this to Config or some sort of OverrideManager class
+ (AXUIElementRef) systemWideAXUIElement {
    return _systemWideAXUIElement;
}

#pragma mark - Variables - dynamic

static MFScrollModificationResult _modifications;
static ScrollConfig *_scrollConfig;
static MFScrollAnimationCurveParameters *_animationParams;
static ScrollAnalysisResult _lastScrollAnalysisResult;
static CFTimeInterval _lastScrollAnalysisResultTimeStamp;
//static BOOL _isSuspended = NO; TODO: Remove suspension stuff (already commented out)

#pragma mark - Display-synchronized scroll motion controller

/// The legacy TouchAnimator restarts a finite curve for every physical report. That preserves distance, but it also
/// turns report timing irregularities into repeated changes in output velocity. This controller instead maintains one
/// continuously moving target. New reports move the target without resetting velocity, so steady input converges to
/// steady output and fast input can be coalesced into one delta per display frame.
///
/// All mutable state below is confined to `_motionDisplayLink.dispatchQueue`.
static Vector _motionPosition;
static Vector _motionTarget;
static Vector _motionVelocity;
static Vector _motionLastSampledPosition;
static CFTimeInterval _motionLastFrameTime;
static CFTimeInterval _motionLastInputTime;
static CFTimeInterval _motionFirstInputTime;
static double _motionFirstInputQueueDelayMs;
static BOOL _motionHasProducedDeltas;
static MFDirection _motionDirection;
static MFMomentumHint _motionLastMomentumHint;
static ScrollConfig *_motionConfig;

static void sendScroll(int64_t px, MFDirection scrollDirection, BOOL animated, MFAnimationCallbackPhase animationPhase, MFMomentumHint momentumHint, ScrollConfig *config);
static void motionControllerCancel(void);
static void motionControllerAdd(Vector delta, MFDirection direction, ScrollConfig *config, CFTimeInterval inputTime, double inputQueueDelayMs);

static double motionMagnitude(Vector vector) {
    return hypot(vector.x, vector.y);
}

static void motionControllerResetState_Unsafe(void) {
    _motionPosition = _P(0, 0);
    _motionTarget = _P(0, 0);
    _motionVelocity = _P(0, 0);
    _motionLastSampledPosition = _P(0, 0);
    _motionLastFrameTime = 0;
    _motionLastInputTime = 0;
    _motionFirstInputTime = 0;
    _motionFirstInputQueueDelayMs = 0;
    _motionHasProducedDeltas = NO;
    _motionDirection = kMFDirectionNone;
    _motionLastMomentumHint = kMFMomentumHintNone;
    _motionConfig = nil;
    [_motionSubPixelator reset];
}

static void motionControllerStop_Unsafe(MFAnimationCallbackPhase phase) {
    if (_motionHasProducedDeltas && _motionConfig != nil) {
        sendScroll(0, _motionDirection, YES, phase, _motionLastMomentumHint, _motionConfig);
    }
    [_motionDisplayLink stop_Unsafe];
    motionControllerResetState_Unsafe();
}

static void motionControllerCancel(void) {
    dispatch_async(_motionDisplayLink.dispatchQueue, ^{
        if ([_motionDisplayLink isRunning_Unsafe]) {
            motionControllerStop_Unsafe(kMFAnimationCallbackPhaseCanceled);
        } else {
            motionControllerResetState_Unsafe();
        }
    });
}

/// Exact solution for one dimension of a critically damped spring whose target is fixed for this display frame.
/// Using the analytic solution keeps the response stable across 60/120 Hz displays and dropped frames.
static void motionControllerAdvanceDimension(double *position, double *velocity, double target, double omega, double dt) {
    double error = *position - target;
    double velocityPlusOmegaError = *velocity + omega * error;
    double decay = exp(-omega * dt);
    double newError = (error + velocityPlusOmegaError * dt) * decay;
    double newVelocity = (*velocity - omega * velocityPlusOmegaError * dt) * decay;
    *position = target + newError;
    *velocity = newVelocity;
}

static void motionControllerDisplayLinkCallback(DisplayLinkCallbackTimeInfo timeInfo) {
    if (![_motionDisplayLink isRunning_Unsafe] || _motionConfig == nil) {
        return;
    }

    CFTimeInterval frameTime = timeInfo.outFrame;
    CFTimeInterval dt = _motionLastFrameTime > 0
        ? frameTime - _motionLastFrameTime
        : timeInfo.nominalTimeBetweenFrames;
    dt = CLIP(dt, 1.0 / 240.0, 1.0 / 20.0);
    _motionLastFrameTime = frameTime;

    /// While reports are arriving, a fast critical response keeps the page attached to the ring. Once reports stop,
    /// a gentler response drains only the remaining target error: it glides without inventing distance or overshoot.
    static const CFTimeInterval releaseDelay = 70.0 / 1000.0;
    BOOL inputIsActive = CACurrentMediaTime() - _motionLastInputTime <= releaseDelay;
    double omega = inputIsActive ? 65.0 : 18.0;
    if (!inputIsActive) {
        /// Lowering omega while the controller still has high forward velocity can make an otherwise critically
        /// damped system cross its target. Keep enough damping to satisfy v <= omega * distanceRemaining, which
        /// guarantees monotonic settling for this one-axis controller. The small margin absorbs frame-time error.
        Vector remaining = subtractedVectors(_motionTarget, _motionPosition);
        double distanceRemaining = motionMagnitude(remaining);
        if (distanceRemaining > 0.001) {
            double speedTowardTarget = dotProduct(_motionVelocity, remaining) / distanceRemaining;
            if (speedTowardTarget > 0) {
                omega = MAX(omega, 1.05 * speedTowardTarget / distanceRemaining);
                omega = MIN(omega, 80.0);
            }
        }
    }

    motionControllerAdvanceDimension(&_motionPosition.x, &_motionVelocity.x, _motionTarget.x, omega, dt);
    motionControllerAdvanceDimension(&_motionPosition.y, &_motionVelocity.y, _motionTarget.y, omega, dt);

    BOOL isSettled = !inputIsActive
        && motionMagnitude(subtractedVectors(_motionTarget, _motionPosition)) < 0.20
        && motionMagnitude(_motionVelocity) < 4.0;
    if (isSettled) {
        /// Snap the final fraction to the integer target. The subpixelator carries rounding error, so total emitted
        /// distance still exactly matches total accepted input.
        _motionPosition = _motionTarget;
        _motionVelocity = _P(0, 0);
    }

    Vector doubleDelta = subtractedVectors(_motionPosition, _motionLastSampledPosition);
    _motionLastSampledPosition = _motionPosition;
    Vector integerDelta = [_motionSubPixelator intVectorWithDoubleVector:doubleDelta];

    if (!isZeroVector(integerDelta)) {
        MFAnimationCallbackPhase phase = _motionHasProducedDeltas
            ? kMFAnimationCallbackPhaseContinue
            : kMFAnimationCallbackPhaseStart;
        MFMomentumHint momentumHint = (!_motionHasProducedDeltas || inputIsActive)
            ? kMFMomentumHintGesture
            : kMFMomentumHintMomentum;

        if (!_motionHasProducedDeltas) {
            DDLogDebug("MFSCROLL_LATENCY: inputToFirstOutputMs=%.2f inputQueueMs=%.2f engine=target",
                       MAX(0.0, (CACurrentMediaTime() - _motionFirstInputTime) * 1000.0),
                       _motionFirstInputQueueDelayMs);
        }

        sendScroll(llround(motionMagnitude(integerDelta)), _motionDirection, YES, phase, momentumHint, _motionConfig);
        _motionHasProducedDeltas = YES;
        _motionLastMomentumHint = momentumHint;
    }

    if (isSettled) {
        motionControllerStop_Unsafe(kMFAnimationCallbackPhaseEnd);
    }
}

static void motionControllerAdd(Vector delta, MFDirection direction, ScrollConfig *config, CFTimeInterval inputTime, double inputQueueDelayMs) {
    dispatch_async(_motionDisplayLink.dispatchQueue, ^{
        BOOL wasRunning = [_motionDisplayLink isRunning_Unsafe];
        if (!wasRunning) {
            motionControllerResetState_Unsafe();
            _motionFirstInputTime = inputTime;
            _motionFirstInputQueueDelayMs = inputQueueDelayMs;
        }

        _motionTarget = addedVectors(_motionTarget, delta);
        _motionDirection = direction;
        _motionConfig = config;
        _motionLastInputTime = inputTime;

        if (!wasRunning) {
            [_motionDisplayLink start_UnsafeWithCallback:^(DisplayLinkCallbackTimeInfo timeInfo) {
                motionControllerDisplayLinkCallback(timeInfo);
            }];
        }
    });
}

#pragma mark - Public functions

+ (void)load_Manual {
    
    /// Setup dispatch queue
    ///  For multithreading while still retaining control over execution order.
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, -1);
    _scrollQueue = dispatch_queue_create("com.nuebling.mac-mouse-fix.helper.scroll", attr);
    
    /// Create AXUIElement for getting app under mouse pointer
    _systemWideAXUIElement = AXUIElementCreateSystemWide();
    /// Create Event source
    if (_eventSource == NULL) {
        _eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    }
    
    /// Create/enable scrollwheel input callback
    if (_eventTap == NULL) {
        CGEventMask mask = CGEventMaskBit(kCGEventScrollWheel);
        _eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, eventTapCallback, NULL);
        DDLogDebug("Scroll.m: _eventTap: %@", _eventTap);
        CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
        CFRelease(runLoopSource);
        CGEventTapEnable(_eventTap, false); // Not sure if this does anything
    }
    
    /// Create animator
    _animator = [[TouchAnimator alloc] init];
    _motionDisplayLink = [DisplayLink displayLinkOptimizedForWorkType:kMFDisplayLinkWorkTypeEventSending];
    _motionSubPixelator = [VectorSubPixelator biasedPixelator];
    motionControllerResetState_Unsafe();
    
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
    [_animator cancel];
    motionControllerCancel();
    [GestureScrollSimulator stopMomentumScroll]; /// Not sure if appropriate
    [ScrollAnalyzer resetState];
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

        DDLogDebug("Scroll.m: eventTap was disabled by %@", type == kCGEventTapDisabledByTimeout ? @"timeout. Re-enabling." : @"user input.");
        
        if (type == kCGEventTapDisabledByTimeout) {
            CGEventTapEnable(_eventTap, true);
        }
        
        return event;
    }

    /// Return non-scrollwheel events unaltered
    int64_t isPixelBased     = CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
    int64_t scrollPhase      = CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
    int64_t scrollDeltaAxis1 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    int64_t scrollDeltaAxis2 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
    int64_t lineDeltaAxis1   = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    int64_t lineDeltaAxis2   = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
    /// ^ The *line* deltas, as opposed to the point deltas above. See `unitsForThisTick` in heavyProcessing() for
    ///     why we carry both: point delta is already accelerated by macOS and is not a usable unit count.
    int64_t drawingTabletID  = CGEventGetIntegerValueField(event, kCGTabletEventDeviceID);
    bool isDiagonal = scrollDeltaAxis1 != 0 && scrollDeltaAxis2 != 0;

    /// Raw input trace. `./dev.sh logs | grep MFDELTA`
    ///
    /// Kept rather than removed: every scroll-engine fix in this fork came out of this one line, and it costs
    /// nothing when nobody's streaming — DDLogDebug expands to an `os_log_type_enabled()` guard (Logging.h:51), and
    /// OS_LOG_TYPE_DEBUG is off unless a `log stream --level debug` is attached.
    ///
    /// Notes:
    /// - Logged *before* the early-out below, so passed-through (continuous / diagonal) events appear too. That's
    ///   what proved the TB800 emits zero diagonal events, which dissolved Feature 2.
    /// - Scalars only: os_log renders scalars public but redacts %@, so this stays readable without
    ///   `sudo log config --mode private_data:on`.
    /// - `line` vs `point` is the distinction that matters: point delta is already accelerated by macOS (one
    ///   `line=1` report was measured yielding point deltas of 1, 3, 8 and 13), so only `line` is a usable unit count.
    DDLogDebug("MFDELTA: cont=%lld phase=%lld line=(%lld,%lld) point=(%lld,%lld) fixed=(%.3f,%.3f) diag=%d",
              isPixelBased,
              scrollPhase,
              lineDeltaAxis1,
              lineDeltaAxis2,
              scrollDeltaAxis1,
              scrollDeltaAxis2,
              CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1),
              CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2),
              (int)isDiagonal);

    if (isPixelBased != 0
        || scrollPhase != 0 /// Not entirely sure if testing for 'scrollPhase' here makes sense
        || drawingTabletID != 0 /// Untested
        || isDiagonal) {
        
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
        heavyProcessing(eventCopy, scrollDeltaAxis1, scrollDeltaAxis2, lineDeltaAxis1, lineDeltaAxis2, tickTime);
    });
    
    return NULL;
}

#pragma mark - Main event processing

static void heavyProcessing(CGEventRef event, int64_t scrollDeltaAxis1, int64_t scrollDeltaAxis2, int64_t lineDeltaAxis1, int64_t lineDeltaAxis2, CFTimeInterval tickTS) {
    
    /// Declare stuff for later
    static DriverUnsuspender unsuspendDrivers = ^{}; /// This is old stuff that should be removed I think [Jun 2 2025]
    double inputQueueDelayMs = MAX(0.0, (CACurrentMediaTime() - tickTS) * 1000.0);
    
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
    
    /// Run preliminary scrollAnalysis
    ///     To check if this is the first consecutive scrollTick
    ///
    ///     @note We check the `_modifications.effectMod` before updating `_modifications`. Not totally sure this makes sense?
    
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
        
        /// Update modfications
        MFScrollModificationResult newMods = [ScrollModifiers currentModificationsWithEvent:event];

        /// Fork: while ANY trackball mode is latched (Scroll & Zoom / Zoom), the ring zooms with no modifier held.
        ///     Forced here rather than in ScrollModifiers so it beats whatever the keyboard says: the whole point of
        ///     the mode is that you don't have to hold anything. Note this deliberately overrides any *effect*
        ///     modification (horizontal scroll, rotate, ...) but leaves input modifications (precise/quick) alone,
        ///     so Option-to-be-precise still works while zooming.
        if (HelperState.shared.trackballModeIsActive) {
            newMods.effectMod = kMFScrollEffectModificationZoom;
        }

        if (![ScrollModifiers scrollModsAreEqual:newMods other:_modifications]) {
            resetState_Unsafe();
            _modifications = newMods;
        }
        
        /// Get display  under mouse pointer
        CGDirectDisplayID displayID;
        [HelperUtility displayUnderMousePointer:&displayID withEvent:event];

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
        [_animator.displayLink linkToDisplayUnderMousePointerWithEvent:event];
        [_motionDisplayLink linkToDisplayUnderMousePointerWithEvent:event];

        /// Get scrollConfig
        _scrollConfig = [ScrollConfig scrollConfigWithModifiers:newMods inputAxis:inputAxis display:displayID];
        
    } /// End `if (firstConsecutive) {`
    
    ///
    /// Get effective direction
    ///  -> With user settings etc. applied
    
    scrollDirection = [ScrollUtility directionForInputAxis:inputAxis inputDelta:scrollDelta invertSetting:_scrollConfig.u_invertDirection horizontalModifier:(_modifications.effectMod == kMFScrollEffectModificationHorizontalScroll)]; /// Why do we need to get the scrollDirection again? We already calculated it during the "preliminary scrollAnalysis". Can it ever change betweent he 2 times we calculate it?
    
    /// Run full scrollAnalysis
    ScrollAnalysisResult scrollAnalysisResult = [ScrollAnalyzer updateWithTickOccuringAt:tickTS direction:scrollDirection units:llabs(lineDelta) config:_scrollConfig];

    /// Note [Jul 16 2026]: there used to be a "drop the lone trailing detent" heuristic here. It's been removed.
    ///     Short version: a settling detent and the first tick of a *resumed* scroll are identical at
    ///     the moment they arrive, and differ only in what comes after, which an event tap can't see. Measured over
    ///     1464 real events, it dropped 112 ticks of which **87 were the start of a scroll, not a trailing detent**
    ///     — the user felt that as "it sticks for a bit, then starts scrolling". The gap distributions overlap
    ///     completely (wrongly-dropped starts at 179-354ms vs real detents at ~260ms), so no timing window
    ///     separates them.
    ///     It's also obsolete: it was built when one unit was a 73-86px lurch. At the tuned default sensitivity a
    ///     detent is ~14px, which is what actually solved the problem.

    
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
    
    if (_scrollConfig.useAppleAcceleration) {
        
        pxToScrollForThisTick = scrollDelta;
        
    } else {
        
        /// Get tickInterval
        double timeBetweenTicks = scrollAnalysisResult.timeBetweenTicks;
        
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
        double pxPerUnit = _scrollConfig.pxAtRefSpeed * pow(scrollSpeed / _scrollConfig.refSpeed, _scrollConfig.gamma - 1.0);
        double pxForThisTickDouble = pxPerUnit * unitsForThisTick;

        ///
        /// Apply fast scroll to pxToScrollForThisTick
        ///
        
        if (_scrollConfig.fastScrollCurve != nil) {
            
            /// Evaluate fast scroll
            /// +1 cause consecutiveScrollSwipeCounter starts counting at 0, and fsThreshold at 1
            double consecutiveSwipes = scrollAnalysisResult.consecutiveScrollSwipeCounter;
            double fastScrollFactor = [_scrollConfig.fastScrollCurve evaluateAt:consecutiveSwipes+1];
            
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
        ///     Capping before fastScroll let the exponential multiplier bypass the safety limit entirely.
        double maxPxPerTick = _scrollConfig.pxAtRefSpeed * 12.0;
        if (pxForThisTickDouble > maxPxPerTick) {
            DDLogDebug("Scroll.m: capping px %.0f -> %.0f (v=%.0f units/s)", pxForThisTickDouble, maxPxPerTick, scrollSpeed);
            pxForThisTickDouble = maxPxPerTick;
        }

        pxToScrollForThisTick = llround(pxForThisTickDouble);

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
        
        ///
        /// Make direction change stop scroll animation
        ///
        /// Notes:
        /// The old-direction animation must stop immediately, especially at a content boundary,
        /// but the physical tick that requested the reversal must still be delivered.
        
        if (_lastScrollAnalysisResult.scrollDirectionDidChange) {
            if (_scrollConfig.useTargetedScrollEngine) {
                /// Drop the old-direction target immediately. Reversal is a control action, so preserving a stale
                /// coast here is less precise than preserving its remaining distance.
                DDLogDebug("Scroll.m: Direction change – cancel targeted scroll and keep current tick.");
                motionControllerCancel();
            } else {
                double currentAnimationSpeed = magnitudeOfVector(_animator.getLastAnimationSpeed);
                if (currentAnimationSpeed > 0) {
                    /// Cancel the old-direction coast, but keep processing this tick. The animator serializes
                    /// cancel() and startWithParams() on the same queue, so the new-direction animation starts
                    /// after the old one has stopped. Returning here used to discard the exact tick that should
                    /// make scrolling responsive again at a content boundary.
                    DDLogDebug("Scroll.m: Direction change – cancel scroll and keep current tick.");
                    [_animator cancel];
                }
            }
        }
        
        /// Debug
        DDLogDebug("Scroll.m: consecTicks: %lld, consecSwipes: %lld, consecSwipesFree: %f", scrollAnalysisResult.consecutiveScrollTickCounter, scrollAnalysisResult.DEBUG_consecutiveScrollSwipeCounterRaw, scrollAnalysisResult.consecutiveScrollSwipeCounter);
        DDLogDebug("Scroll.m: timeBetweenTicks: %f, timeBetweenTicksRaw: %f, diff: %f, ticks: %lld", scrollAnalysisResult.timeBetweenTicks, scrollAnalysisResult.DEBUG_timeBetweenTicksRaw, scrollAnalysisResult.timeBetweenTicks - scrollAnalysisResult.DEBUG_timeBetweenTicksRaw, scrollAnalysisResult.consecutiveScrollTickCounter);
    }
    
    ///
    /// Send scroll events
    ///
    
    if (pxToScrollForThisTick == 0) {
        
        DDLogWarn("Scroll.m: pxToScrollForThisTick is 0");
        
    } else if (!_scrollConfig.smoothEnabled) {
        
        /// Send scroll event directly - without the animator. Will scroll all of pxToScrollForThisTick at once.
        sendScroll(pxToScrollForThisTick, scrollDirection, NO, kMFAnimationCallbackPhaseNone, kMFMomentumHintNone, _scrollConfig);
        
    } else if (_scrollConfig.useTargetedScrollEngine) {

        /// Keep one display-synchronized motion session alive across physical reports. TouchAnimator remains the
        /// fallback for every other animation curve and for gesture effects.
        if (firstConsecutive) {
            [_animator cancel];
        }
        motionControllerAdd(vectorFromDeltaAndDirection(pxToScrollForThisTick, scrollDirection),
                            scrollDirection,
                            _scrollConfig,
                            tickTS,
                            inputQueueDelayMs);

    } else {
        
        /// Send scroll events through animator, spread out over time.

        if (firstConsecutive) {
            motionControllerCancel();
        }
        
        /// Create config-copy for animation-callback-block
        ///  Edit: Turned copying off now, since it's extremely slow. I don't think this is necessary with the current architecture (the `_scrollConfig` is a reference into a cache. When the scrollConfig updates the cache is deleted but this reference should still be valid)
        
//        ScrollConfig *configCopyForBlock = [_scrollConfig copy];
        ScrollConfig *configCopyForBlock = _scrollConfig;
        
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
            
            /// Calculate distance to scroll
            double delta = pxToScrollForThisTick + pxLeftToScroll;
            
            /// Get curve params
            MFScrollAnimationCurveParameters *pCurve = _scrollConfig.animationCurveParams;
            
            /// Get baseDuration
            
            double baseDuration;
            
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
                double tickStart        = _scrollConfig.animationTickStart;
                /// ^ Fork: was `consecutiveScrollTickIntervalMax`. Those two were the same constant (160ms) but mean
                ///     different things, and we've since raised the max to ~500ms so a slow ring counts as one
                ///     continuous scroll. Left coupled, that would re-anchor this curve: a 260ms tick would sample
                ///     mid-curve and get a *shorter* animation (~415ms -> ~172ms) exactly when it needs a longer one.
                ///     `animationTickStart` keeps the duration mapping where upstream tuned it.
                double tickEnd          = _scrollConfig.consecutiveScrollTickIntervalMin;
                double tick             = scrollAnalysisResult.timeBetweenTicks;
                
                /// Adjust tickStart
                /// Explanation:
                /// - This is quite confusing. I think behind this design is the idea that the baseCurve is the part of the animation that feels like the user is directly pushing the page. (Whereas the rest of the curve feels more like the page keeps sliding after the user pushed it). This code is an approximation of the idea that only when the duration between the physical ticks of the users scrollwheel become shorter than the duration of this baseAnimation, should we start to speed up the baseAnimation. And that increases this physical relationship between the duration of the baseAnimation and the time between scrollwheel ticks. The extreme of this idea would be to try and make the duration of the base animation exactly equal to the time between scrollwheel ticks. But I think I tried that and it felt shitty (Not totally sure at the moment)
                /// - Overall this is quite confusing and complex to understand. Maybe we should remove it.
                /// - Update: This is also pretty much never used atm I think.
                
                if (tickStart > baseTimeStart) {
                    
                    tickStart = baseTimeStart;
                    DDLogDebug("Scroll.m: animation init - baseMsPerStepCurve - adjusting tickStart below consecutiveScrollTickIntervalMax to baseTimeStart: %f", baseTimeStart);
                    assert(false);
                }
                
                /// Adjust tick
                /// Notes:
                /// - Scroll analyzer sets tick to `DBL_MAX` to signify that there are no previous consecutive ticks. (Not sure if  that's a great idea) We have to set it to a sendible value here so the scaling Math doesn't break.
                
                if (tick == DBL_MAX) {
                    tick = _scrollConfig.consecutiveScrollTickIntervalMax;
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
                
                if (tick > _scrollConfig.consecutiveScrollTickIntervalMax && tick != DBL_MAX) {
                    DDLogError("Scroll.m: animation init - tickTime is over max. This is a bug but we can recover. tickTime: %f", tick);
                    tick = _scrollConfig.consecutiveScrollTickIntervalMax;
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
                DDLogDebug("Scroll.m: animation init - baseMsPerStepCurve - calculating animation baseDuration - baseTimeEnd: %.1f, baseBaseTimeStart: %.1f, tick: %.1f, tickEnd: %.1f, tickStart: %1.f, consecutiveScrollTickIntervalMax: %.1f, result: %.1f", baseTimeEnd, baseTimeStart, tick*1000, tickEnd*1000, tickStart*1000, _scrollConfig.consecutiveScrollTickIntervalMax*1000, baseDuration*1000);
            }
            
            /// Get curve and duration
            
            double duration;
            Curve *c;
            
            if (!pCurve.useDragCurve) {
                
                DDLogDebug("Scroll.m: animation init – animation curve base");
                
                c = pCurve.baseCurve;
                duration = baseDuration;
                
            } else {
                
                DDLogDebug("Scroll.m: animation init – animation curve hybrid");
                
                /// speedSmoothing
                
                Bezier *baseCurve = pCurve.baseCurve;
                double speedSmoothing = pCurve.speedSmoothing;
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
                HybridCurve *hc = [[BezierHybridCurve alloc]
                     initWithBaseCurve:baseCurve
                     minDuration:baseDuration
                     distance:delta
                     dragCoefficient:pCurve.dragCoefficient
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
                DDLogDebug("MFSCROLL_LATENCY: inputToFirstOutputMs=%.2f inputQueueMs=%.2f",
                           MAX(0.0, (CACurrentMediaTime() - tickTS) * 1000.0),
                           inputQueueDelayMs);
            }
            sendScroll(distanceDelta, scrollDirection, YES, animationPhase, momentumHint, config);
            
        }];
    }
    
    CFRelease(event);
}

#pragma mark - Send Scroll events

static void sendScroll(int64_t px, MFDirection scrollDirection, BOOL animated, MFAnimationCallbackPhase animationPhase, MFMomentumHint momentumHint, ScrollConfig *config) {
    
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
    
    if (_modifications.effectMod == kMFScrollEffectModificationZoom) {
        outputType = kMFScrollOutputTypeZoom;
    } else if (_modifications.effectMod == kMFScrollEffectModificationRotate) {
        outputType = kMFScrollOutputTypeRotation;
    } else if (_modifications.effectMod == kMFScrollEffectModificationFourFingerPinch) {
        outputType = kMFScrollOutputTypeFourFingerPinch;
    } else if (_modifications.effectMod == kMFScrollEffectModificationCommandTab) {
        outputType = kMFScrollOutputTypeCommandTab;
    } else if (_modifications.effectMod == kMFScrollEffectModificationThreeFingerSwipeHorizontal) {
        outputType = kMFScrollOutputTypeThreeFingerSwipeHorizontal;
    } /// kMFScrollEffectModificationHorizontalScroll is handled above when determining scroll direction
    
    /// Send event
    
    sendOutputEvents(dx, dy, outputType, animationPhase, momentumHint, config);
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

static void sendOutputEvents(int64_t dx, int64_t dy, MFScrollOutputType outputType, MFAnimationCallbackPhase animatorPhase, MFMomentumHint momentumHint, ScrollConfig *config) {
    
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
                [GestureScrollSimulator postGestureScrollEventWithDeltaX:dx deltaY:dy phase:eventPhase autoMomentumScroll:YES invertedFromDevice:_scrollConfig.invertedFromDevice];
                
            } else {
                
                /// Post end event
                [GestureScrollSimulator postGestureScrollEventWithDeltaX:0.0 deltaY:0.0 phase:kIOHIDEventPhaseEnded autoMomentumScroll:YES invertedFromDevice:_scrollConfig.invertedFromDevice];
                
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
                    [GestureScrollSimulator postMomentumScrollDirectlyWithDeltaX:0 deltaY:0 momentumPhase:kCGMomentumScrollPhaseEnd invertedFromDevice:_scrollConfig.invertedFromDevice];
                    
                    /// Set eventPhase to start
                    eventPhase = kIOHIDEventPhaseBegan;
                    
                    /// Debug
                    DDLogDebug("Scroll.m: \nHybrid event - momentum: (0, 0, %d) JJJ", kCGMomentumScrollPhaseEnd);
                }
                
                /// Send normal gesture scroll
                [GestureScrollSimulator postGestureScrollEventWithDeltaX:dx deltaY:dy phase:eventPhase autoMomentumScroll:NO invertedFromDevice:_scrollConfig.invertedFromDevice];
                
                /// Simulate tap to prevent momentum scrolling
                ///     - Send kIOHIDEventPhaseMayBegin and kIOHIDEventPhaseCancelled events to prevent momentum scrolling from starting in apps like Xcode
                ///     - This is the only way I found to reliably prevent auto-momentumscroll in when running iPad apps like Downpay.
                ///     - The MayBegin and Cancelled events are sent by a real trackpad when putting two fingers on the Trackpad and then lifting them off without actually scrolling. So I think we can think of these events simulating a quick tap with 2 fingers on the Trackpad.
                ///     - We're *only* ever sending kIOHIDEventPhaseMayBegin and kIOHIDEventPhaseCancelled events to simulate a tap to stop momentum scrolling. On a real Trackpad, they also only seem to occur for taps. We're currently simulating taps in Scroll.m (for scrollwheel scrolling) and GestureScrollSimulator.m (for Click and Drag scrolling) [Jul 2025]
                if (animatorPhase == kMFAnimationCallbackPhaseCanceled) {
                    assert(eventPhase == kIOHIDEventPhaseEnded);
                    
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseMayBegin autoMomentumScroll:NO invertedFromDevice:_scrollConfig.invertedFromDevice];
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseCancelled autoMomentumScroll:NO invertedFromDevice:_scrollConfig.invertedFromDevice];
                }
                
                /// Debug
                DDLogDebug("Scroll.m: \nHybrid event - gesture: (%lld, %lld, %d)", dx, dy, eventPhase);
                
            } else { /// momentumHint is momentum
                
                CGMomentumScrollPhase momentumPhase = kCGMomentumScrollPhaseNone;
                
                if (lastMomentumHint == kMFMomentumHintGesture) {
                    /// Momentum begins
                    
                    /// Send gesture end event
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseEnded autoMomentumScroll:NO invertedFromDevice:_scrollConfig.invertedFromDevice];
                    
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
                [GestureScrollSimulator postMomentumScrollDirectlyWithDeltaX:dx deltaY:dy momentumPhase:momentumPhase invertedFromDevice:_scrollConfig.invertedFromDevice];
                
                /// Simulate tap to prevent momentum scrolling
                ///     [Jul 2025] Simulating the tap shouldn't usually be necessary for kMFAnimationCallbackPhaseEnd, since in that case the scrolling should naturally have slowed down to the point where there is no further automatic momentum scrolling. But Always doing it should make things more robust.
                ///     [Jul 2025] Doing this for kMFAnimationCallbackPhaseCanceled is necessary to get reliable scroll canceling in DownPay iPad app..
                if (animatorPhase == kMFAnimationCallbackPhaseEnd || animatorPhase == kMFAnimationCallbackPhaseCanceled) {
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseMayBegin autoMomentumScroll:NO invertedFromDevice:_scrollConfig.invertedFromDevice];
                    [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseCancelled autoMomentumScroll:NO invertedFromDevice:_scrollConfig.invertedFromDevice];
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
        
        /// Create base event
        
        /// Use the public scroll-event constructor instead of mutating a null event into type 22.
        /// Do not override its location: HID-posted events can move the cursor to the supplied point.
        /// Always post the animator phase, including zero-delta Ended events. Dropping the end event
        /// leaves some scroll views latched until unrelated pointer or click input resets their state.
        CGEventRef event = CGEventCreateScrollWheelEvent(_eventSource, kCGScrollEventUnitPixel, 2, 0, 0);
        CGEventSetTimestamp(event, (CGEventTimestamp)(CACurrentMediaTime() * NSEC_PER_SEC));
        CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, eventPhase);
        
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
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
    } else if (outputType == kMFScrollOutputTypeLineScroll) {
        
        /// --- LineScroll ---
        
        /// We ignore the phases here
        
        if (dx+dy == 0) return;
        
        /// Create a real line-based scroll event.
        CGEventRef event = CGEventCreateScrollWheelEvent(_eventSource, kCGScrollEventUnitLine, 2, 0, 0);
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
        
        double eventDelta = (dx + dy)/800.0; /// This works because, if dx != 0 -> dy == 0, and the other way around.

        /// Invert zoom
        ///     Must happen here — *before* the Chromium hack below. That hack adds asymmetric, sign-dependent
        ///     offsets (+380/800 vs -250/800), so negating after it would apply the wrong branch's correction and
        ///     make zooming lopsided in Chromium browsers.
        if (config.u_invertZoom) {
            eventDelta = -eventDelta;
        }

        /// HACK:
        ///     Chromium browsers need a ton of zooming deltas before they actually start zooming. So we send a bunch of deltas right away to make things more responsive.
        ///     Another way to combat this would be to only send the `end` event when the user releases the modifier.
        if (eventPhase == kIOHIDEventPhaseBegan) {
            
            NSString *bundleID = [HelperUtility appUnderMousePointerWithEvent:NULL].bundleIdentifier;
            
            if (bundleID != nil) {
                if ([bundleID containsString:@"com.google.Chrome"]
                    || [bundleID containsString:@"org.chromium.Chromium"]
                    || [bundleID containsString:@"company.thebrowser.Browser"] /// Arc browser
                    || [bundleID containsString:@"com.operasoftware.Opera"]
                    || [bundleID containsString:@"com.microsoft.edgemac"]
                    || [bundleID containsString:@"com.vivaldi.Vivaldi"]
                    || [bundleID containsString:@"com.brave.Browser"]) {
                    
                    /// Using `containsString` to also catch other release channels like "com.google.Chrome.canary" . Could perhaps use -hasPrefix: instead.
                    /// [Aug 2025] Also see the 'Universal Back and Forward' stuff in Actions.m
                    /// TODO: Add other Chromium browsers with the same behaviour.
                    /// Notes:
                    /// - Blisk (org.blisk.Blisk) and Colibri (co.opqr.colibri) don't seem to support pinch to zoom.
                    
                    [TouchSimulator postMagnificationEventWithMagnification:eventDelta phase:kIOHIDEventPhaseBegan]; /// First delta seems to be ignored
                    eventPhase = kIOHIDEventPhaseChanged;
                    
                    assert(eventDelta != 0);
                    if (mfsign(eventDelta) > 0) {
                        eventDelta += 380/800.0;
                    } else {
                        eventDelta -= 250/800.0;
                    }
                }
            }
        }
        
        [TouchSimulator postMagnificationEventWithMagnification:eventDelta phase:eventPhase];
        
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
        
        [TouchSimulator postDockSwipeEventWithDelta:eventDelta type:type phase:eventPhase invertedFromDevice:_scrollConfig.invertedFromDevice];
        
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
