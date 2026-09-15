//
// --------------------------------------------------------------------------
// RingScrollRenderer.h
// Display-paced output owner for the TB800 free-rotating scroll ring.
// --------------------------------------------------------------------------
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "DisplayLink.h"
#import "RingInputCorrelator.h"
#import "RingMotionPlane.h"

NS_ASSUME_NONNULL_BEGIN

/// Pixel components use the canonical CGEvent convention: positive is
/// up/right and negative is down/left. Both independent physical rings may
/// contribute to one display-paced wheel event. `startsOutput` is an output-
/// sink lifecycle hint only; ordinary ring output remains phase-less.
typedef void (^MFRingScrollRendererOutput)(int64_t horizontalPixels,
                                           int64_t verticalPixels,
                                           MFRingAxis resetSubpixelAxes,
                                           BOOL startsOutput);

@interface RingScrollRenderer : NSObject

- (instancetype)initWithDisplayLink:(DisplayLink *)displayLink
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Methods may be called from the scroll queue. Work is applied in order on
/// the shared display-link queue, which is the sole owner of renderer state.
- (void)enqueueReportWithSequence:(uint64_t)sequence
                       generation:(uint64_t)generation
                             axis:(MFRingAxis)axis
                         timestamp:(CFTimeInterval)timestamp
                       signedUnits:(int64_t)signedUnits
                        sourceName:(NSString *)sourceName
                 inputQueueDelayMs:(double)inputQueueDelayMs
                         displayID:(CGDirectDisplayID)displayID
                            config:(MFRingMotionConfig)config
                            output:(MFRingScrollRendererOutput)output;

/// Publishes the generation synchronously before the ordered queue reset, so
/// a callback already admitted by CoreVideo cannot emit for the old session.
- (void)resetToGeneration:(uint64_t)generation reason:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END
