//
// --------------------------------------------------------------------------
// ScrollAnalyzer.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// [Aug 2025] Terminology: Instead of **scrollSwipe** we could use:
///     - In code:                        scrollBurst                                                                               (But I guess scrollSwipe is also fine for code,  since I know what it means.)
///     - In user-facing text:      'turns/rolls/flicks/strokes/movements of the scroll wheel'       (Or we can avoid referring to the concept directly and say something like 'keep scrolling in the same direction quickly for a while and scrolling will become very fast.')
///
/// - [Aug 2025] Improvement ideas:
///     - Don't trigger fastScroll for slow-and-long scrolls.
///         - I think that's the scenario where V-Coba describes triggering it accidentally here: https://github.com/noah-nuebling/mac-mouse-fix/issues/1512
///         - `consecutiveScrollSwipeMinTickSpeed` already tries to address this.
///             - Improvment ideas:
///                 - Tune it up
///                 - Measure the scrollwheel speed *during* swipes instead of overall? I'd say slow movement during a long swipe indicates the user wants deliberate slow-and-steady movement.
///     - Disable fastScroll entirely
///         - I think it's useful but I haven't tested how scrolling feels without it since it was introduced in one of the first MMF versions I think.

#import "ScrollAnalyzer.h"
#import <Cocoa/Cocoa.h>
#import "Scroll.h"
#import "ScrollUtility.h"
#import "ModificationUtility.h"

@implementation ScrollAnalyzer

#pragma mark Init

+ (void)initialize {
    if (self == [ScrollAnalyzer class]) {
        
        /// Get default config
        ///     Note that this will never update because the init function only runs once. So make sure that whatever values you use here aren't intended to update!
//        ScrollConfig *_scrollConfig = [ScrollConfig copyOfConfig];
        
        /// Setup smoothing algorithm for `timeBetweenTicks`
        
        _tickTimeSmoother = [[RollingAverage alloc] initWithCapacity: 3]; /// Capacity 1 turns off smoothing
        /// ^ No smoothing feels the best.
        ///     - Without smoothing, there will somemtimes randomly be extremely small `timeSinceLastTick` values. I was worried that these would overdrive the acceleration curve, producing extremely high `pxToScrollForThisTick` values at random. But since we've capped the acceleration curve to a maximum `pxToScrollForThisTick` this isn't a noticable issue anymore.
        ///     - No smoothing is way more responsive than RollingAverage
        ///     - No smoothing is more responsive than DoubleExponential. And when there are extremely small `timeSinceLastTick` values (avoiding these is the whole reason we use smoothing), the DoubleExponentialSmoother will extrapolate the trend and make it even *worse* - sometimes it even produces negative values!
        ///     - We could try if a light exponential smoothing would feel better, but this is good enought for now
        ///     Edit: I do prefer the smoothness over the responsiveness now. Like a LOT. Capacity 3 works well.
        
//        _tickTimeSmoother = [[ExponentialSmoother alloc] initWithA:_scrollConfig.ticksPerSecond_ExponentialSmoothing_InputValueWeight];
        /// ^ Light exponential smoothing is also worse than no smoothing at all. The loss in responsiveness is not worth the added "stability" imo
        
    }
}

#pragma mark Vars

/// Constant

static NSObject<Smoother> *_tickTimeSmoother;

/// Dynamic

static double _previousScrollTickTimeStamp = 0;
static MFDirection _previousDirection = kMFDirectionNone;
static double _filteredVelocityInUnitsPerSecond = 0;
static BOOL _velocityFilterIsInitialized = NO;

static int _consecutiveScrollTickCounter;

static int _consecutiveScrollSwipeCounter;
static double _consecutiveScrollSwipeCounter_ForFreeScrollWheel;

static int _ticksInCurrentConsecutiveSwipeSequence;
static CFTimeInterval _consecutiveSwipeSequenceStartTime;

#pragma mark - Interface

/// Reset ticks and swipes

+ (void)resetState {
    
    _previousScrollTickTimeStamp = 0;
    
    _previousDirection = kMFDirectionNone;
    /// ^ This needs to be set to 0, so that scrollDirectionDidChange will definitely evaluate to NO on the next tick

    _filteredVelocityInUnitsPerSecond = 0;
    _velocityFilterIsInitialized = NO;
    
    /// The following are probably not necessary to reset, because the above resets will indirectly cause them to be reset on the next tick
    _consecutiveScrollTickCounter = 0;
    _consecutiveScrollSwipeCounter = 0;
    
    _ticksInCurrentConsecutiveSwipeSequence = 0;
    _consecutiveSwipeSequenceStartTime = -1;
//    [_tickTimeSmoother resetState]; /// Don't do this here
    
    /// We shouldn't definitely not reset _scrollDirectionDidChange here, because a scroll direction change causes this function to be called, and then the information about the scroll direction changing would be lost as it's reset immediately
}

+ (BOOL)peekIsFirstConsecutiveTickWithTickOccuringAt:(CFTimeInterval)thisScrollTickTimeStamp direction:(MFDirection)direction config:(ScrollConfig *)scrollConfig {
    
    /// Checks if a given tick is the first consecutive tick. Without changing state.
    
    /// Return direction change
    if (directionChanged(_previousDirection, direction)) {
        return YES;
    }
    
    /// Get seconds since last tick
    double secondsSinceLastTick = thisScrollTickTimeStamp - _previousScrollTickTimeStamp;
    /// Get timeout
    BOOL didTimeOut = secondsSinceLastTick > scrollConfig.consecutiveScrollTickIntervalMax; /// Should secondsSinceLastTick be smoothed before the comparison?
    
    return didTimeOut;
}

/// This is the main input function which should be called on each scrollwheel tick event
+ (ScrollAnalysisResult)updateWithTickOccuringAt:(CFTimeInterval)thisScrollTickTimeStamp direction:(MFDirection)direction units:(int64_t)units config:(ScrollConfig *)scrollConfig {
    
    /// Update scrollDirectionDidChange
    ///     Checks whether the scrolling direction is different from when this function was last called.
    
    BOOL scrollDirectionDidChange = NO;
    if (directionChanged(_previousDirection, direction)) {
        scrollDirectionDidChange = YES;
    }
    _previousDirection = direction;
    
    /// Reset state if scroll direction changed
    if (scrollDirectionDidChange) {
        [self resetState];
    }

    /// Get raw seconds since last tick
    double secondsSinceLastTick = thisScrollTickTimeStamp - _previousScrollTickTimeStamp;
    
    /// Clip time since last tick to realistic value
    /// Notes:
    /// - We originally introduced this to protect against putting super high tickSpeeds (that were the result of measurement errors) into the accelerationCurve, making the scrolling randomly too fast. But since then we've introduced other measures to protect against this, such as capped accelerationCurves and `consecutiveScrollTickInterval_AccelerationEnd` (And the tickTime smoothing is arguably also a measure against this?). Not sure if this is good or necessary.
    
    if (secondsSinceLastTick < scrollConfig.consecutiveScrollTickIntervalMin) {
        secondsSinceLastTick = scrollConfig.consecutiveScrollTickIntervalMin;
    }
    
    /// Update consecutive tick and swipe counters
    
    _ticksInCurrentConsecutiveSwipeSequence += 1; /// Not totally sure if it makes sense to update this up here, but it seems to work well
    
    if (secondsSinceLastTick > scrollConfig.consecutiveScrollTickIntervalMax) { /// Should `secondsSinceLastTick` be smoothed *before* this comparison?
        /// This is the first consecutive tick
        
        /// --- Update swipes ---
        
        /// Guard: Enough ticks in last swipe
        
        if (scrollConfig.scrollSwipeThreshold_inTicks > _consecutiveScrollTickCounter)
            goto resetSwipes;
            
        /// Guard: Not too much time since last swipe
        
        double thisScrollSwipeTimeStamp = thisScrollTickTimeStamp;
        double interval = thisScrollSwipeTimeStamp - _previousScrollTickTimeStamp;
        
        if (interval > scrollConfig.consecutiveScrollSwipeMaxInterval)
            goto resetSwipes; /// Time between the last tick of the previous swipe and the first tick of the current swipe (now) is greater than swipe threshold
        
        /// Guard: Average speed high enough
        ///     We purely use `_consecutiveScrollSwipeCounter` to drive fastScroll. That's why we don't want to increase it when the user scrolls slowly. -> Should consider renaming to signify coupling with fastScroll
        
        double tickSpeedThisSwipeSequence = ((double)_ticksInCurrentConsecutiveSwipeSequence) / (CACurrentMediaTime() - _consecutiveSwipeSequenceStartTime);
        
        if (tickSpeedThisSwipeSequence < scrollConfig.consecutiveScrollSwipeMinTickSpeed)
            goto resetSwipes;
        
        /// Increment swipes
        
        _consecutiveScrollSwipeCounter += 1;
        _consecutiveScrollSwipeCounter_ForFreeScrollWheel += 1;
        
        goto updateTicks; /// Don't resetSwipes
        
    resetSwipes: /// Using goto even thought my professor said I'm not allowed to muahahaha
        _consecutiveScrollSwipeCounter = 0;
        _consecutiveScrollSwipeCounter_ForFreeScrollWheel = 0;
        _consecutiveSwipeSequenceStartTime = CACurrentMediaTime();
        _ticksInCurrentConsecutiveSwipeSequence = 0;
        
    updateTicks:
        
        /// --- Update ticks ---
        _consecutiveScrollTickCounter = 0;
        
    } else { /// This is not the first consecutive tick
        
        /// --- Update ticks ---
        _consecutiveScrollTickCounter += 1;
    }
    
    /// Update `_consecutiveScrollSwipeCounter_ForFreeScrollWheel`
    ///     It's a little awkward to update this down here after the other swipe-updating code , but we need to do it this way because we need the `consecutiveTickCounter` to be updated after the stuff above but before this
    if ((0)) {  /// [Aug 2025] HOTFIX: Turning this whole mechanism off!
                ///     The free-spinning mode on the MX Master doesn't need additional speedup! ('fastScroll') IIRC a few people have complained about this, too.
                ///     Maybe you could think about a compromise where you only speed things up a little bit or something. But for a hotfix I think this delivers good value to the people.
                ///     The decision to disable this may also affect decisions we made elsewhere in the codebase. IIRC we built in a cap for the animation-time to avoid the sped-up free-spinning from making it crazy long.
                ///     TODO: If we decide to keep this turned off - simplify the code
        if (_consecutiveScrollTickCounter >= scrollConfig.scrollSwipeMax_inTicks) {
            _consecutiveScrollSwipeCounter_ForFreeScrollWheel += 1.0/scrollConfig.scrollSwipeMax_inTicks;
        }
    }
    
    /// Smoothing
    
    double smoothedTimeBetweenTicks;
    
    if (_consecutiveScrollTickCounter == 0) { /// This is first consecutive tick –> reset smoothedTimeBetweenTicks state
        
        /// Reset smoothed tickTime
        /// Note: `DBL_MAX` indicates that it has been longer than `consecutiveScrollTickIntervalMax` since the last tick. Maybe we should define a constant for this.
        smoothedTimeBetweenTicks = DBL_MAX;
        
        /// Reset smoother:
        [_tickTimeSmoother reset];
        
        /// High smoothness seeds the filter so short, fast swipes ramp up less abruptly.
        if (scrollConfig.u_smoothness == kMFScrollSmoothnessHigh) {
            (void)[_tickTimeSmoother smoothWithValue:scrollConfig.consecutiveScrollTickIntervalMax];
        }
        
    } else { /// This is not first consecutive tick
        assert(secondsSinceLastTick <= scrollConfig.consecutiveScrollTickIntervalMax);
        smoothedTimeBetweenTicks = [_tickTimeSmoother smoothWithValue:secondsSinceLastTick];
    }

    /// Fork: estimate velocity with a time-based filter.
    ///
    /// A fixed three-report average has a variable time horizon: it is very laggy during slow scrolling and barely
    /// filters anything during a fast spin. A continuous-time EMA keeps the response characteristics stable:
    ///
    ///     alpha = 1 - exp(-dt / tau)
    ///
    /// Faster attack keeps intentional acceleration responsive. Slower release suppresses packet-to-packet jitter
    /// while the ring decelerates. At sparse report rates alpha naturally approaches 1, avoiding long slow-scroll lag.
    double velocityInterval;
    if (_consecutiveScrollTickCounter == 0 || !_velocityFilterIsInitialized) {
        velocityInterval = scrollConfig.isolatedTickVelocityInterval;
    } else {
        /// Do not reuse `consecutiveScrollTickInterval_AccelerationEnd` here. That 15ms constant defines where the
        /// legacy Bezier acceleration curve starts extrapolating; it is not a hardware sampling limit. Reusing it
        /// capped measured velocity at 66.7 reports/s even if a high-polling-rate device delivered faster events.
        velocityInterval = MAX(secondsSinceLastTick, scrollConfig.velocityMeasurementIntervalMin);
    }

    double rawVelocity = ((double)MAX(1, units)) / velocityInterval;

    if (!_velocityFilterIsInitialized || _consecutiveScrollTickCounter == 0) {
        _filteredVelocityInUnitsPerSecond = rawVelocity;
        _velocityFilterIsInitialized = YES;
    } else {
        double tau = rawVelocity >= _filteredVelocityInUnitsPerSecond
            ? scrollConfig.velocityFilterAttackTimeConstant
            : scrollConfig.velocityFilterReleaseTimeConstant;
        assert(tau > 0);

        double alpha = 1.0 - exp(-velocityInterval / tau);
        _filteredVelocityInUnitsPerSecond += alpha * (rawVelocity - _filteredVelocityInUnitsPerSecond);
    }
    
    /// Update `_previousScrollTickTimeStamp` for next call
    ///     This needs to be executed after `updateConsecutiveScrollSwipeCounterWithSwipeOccuringNow()`, because that function uses `_previousScrollTickTimeStamp`
    _previousScrollTickTimeStamp = thisScrollTickTimeStamp;
    
    /// Debug
//    DDLogDebug("tickTime: %f, Smoothed tickTime: %f", secondsSinceLastTick, smoothedTimeBetweenTicks);
    
    /// Output
    ScrollAnalysisResult result = (ScrollAnalysisResult) {
        .consecutiveScrollTickCounter = _consecutiveScrollTickCounter,
        .consecutiveScrollSwipeCounter = _consecutiveScrollSwipeCounter_ForFreeScrollWheel,
        .scrollDirectionDidChange = scrollDirectionDidChange,
        .timeBetweenTicks = smoothedTimeBetweenTicks,
        .velocityInUnitsPerSecond = _filteredVelocityInUnitsPerSecond,
        .DEBUG_timeBetweenTicksRaw = secondsSinceLastTick, /// Unsmoothed timeBetweenTicks
        .DEBUG_velocityInUnitsPerSecondRaw = rawVelocity,
        .DEBUG_consecutiveScrollSwipeCounterRaw = _consecutiveScrollSwipeCounter,
    };
    
    /// TESTING
//    result.timeBetweenTicks = scrollConfig.consecutiveScrollTickIntervalMax + 1.0;
    
    /// Ensure that `tick <= max`
    ///
    /// Discussion:
    /// - tickTime was apparently sometimes `>` max (and `!= DBL_MAX`) inside Scroll.m, leading to assertion-failed-crashes.
    /// - I thought about the code and I don't understand how this can happen. So we're trying to log the weird state and recover without crashing. We're doing the log-and-recover attempts both in here and inside `Scroll.m` since we're not sure how and where the erroneous state arises.
    ///
    /// Also see:
    /// - For further discussion, see the "Ensure that `tick <= max`" section inside `Scroll.m`
    
    if (result.timeBetweenTicks > scrollConfig.consecutiveScrollTickIntervalMax && result.timeBetweenTicks != DBL_MAX) {
        DDLogError("ScrollAnalyzer - smoothed tickTime is over max. This is a bug but we can recover. Analysis result: %@", [self scrollAnalysisResultDescription:result]);
        result.timeBetweenTicks = scrollConfig.consecutiveScrollTickIntervalMax;
        assert(false);
    }
    
    return result;
}

#pragma mark - Debug

+ (NSString *)scrollAnalysisResultDescription:(ScrollAnalysisResult)analysis {
    
    NSString *tickTimeStr = analysis.timeBetweenTicks == DBL_MAX ? @"9999" : stringf(@"%f", analysis.timeBetweenTicks); /// 9999 signals that the analyzed tick is the first consecutive tick.
    
    return stringf(@"dirChange: %d, ticks: %lld, swipes: %f, tickTime: %@, rawTickTime: %f, velocity: %f, rawVelocity: %f, rawSwipes: %lld", analysis.scrollDirectionDidChange, analysis.consecutiveScrollTickCounter, analysis.consecutiveScrollSwipeCounter, tickTimeStr, analysis.DEBUG_timeBetweenTicksRaw, analysis.velocityInUnitsPerSecond, analysis.DEBUG_velocityInUnitsPerSecondRaw, analysis.DEBUG_consecutiveScrollSwipeCounterRaw);
}

@end
