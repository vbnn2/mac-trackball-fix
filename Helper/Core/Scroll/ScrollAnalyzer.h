//
// --------------------------------------------------------------------------
// ScrollAnalyzer.h
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import <Foundation/Foundation.h>
#import "Constants.h"
#import "ScrollConfigObjC.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"
#import "ModificationUtility.h"

NS_ASSUME_NONNULL_BEGIN

@interface ScrollAnalyzer : NSObject

typedef struct {
    
    int64_t consecutiveScrollTickCounter;
    double consecutiveScrollSwipeCounter;
    BOOL scrollDirectionDidChange;
    CFTimeInterval timeBetweenTicks;

    double velocityInUnitsPerSecond;
    /// ^ Fork: time-filtered input velocity. This is estimated jointly from each report's unit count and interval,
    ///     rather than dividing two independently smoothed signals.

    CFTimeInterval DEBUG_timeBetweenTicksRaw;
    /// ^ Unsmoothed time between ticks. For debugging, don't use this.
    double DEBUG_velocityInUnitsPerSecondRaw;
    /// ^ Instantaneous units/second before time-based filtering.
    int64_t DEBUG_consecutiveScrollSwipeCounterRaw;
    /// ^ Mice with free scrollwheels (e.g. MX Master) make it hard to input several consecutive scroll swipes, because the swipes will bleed into each other and will be registered as a very long sequence of consecutive ticks instead.
    ///     `consecutiveScrollSwipeCounter` will count these long tick sequences as several consecutive swipes, while `DEBUG_consecutiveScrollSwipeCounterRaw` will not
    
} ScrollAnalysisResult;

+ (BOOL)peekIsFirstConsecutiveTickWithTickOccuringAt:(CFTimeInterval)thisScrollTickTimeStamp direction:(MFDirection)direction config:(ScrollConfig *)scrollConfig;

+ (ScrollAnalysisResult)updateWithTickOccuringAt:(CFTimeInterval)thisScrollTickTimeStamp direction:(MFDirection)direction units:(int64_t)units config:(ScrollConfig *)scrollConfig;

+ (void)resetState;

+ (NSString *)scrollAnalysisResultDescription:(ScrollAnalysisResult)analysis;

@end

NS_ASSUME_NONNULL_END
