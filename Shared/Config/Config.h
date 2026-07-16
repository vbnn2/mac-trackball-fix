//
// --------------------------------------------------------------------------
// Config.h
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2019
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface Config : NSObject

#pragma mark - For both

/// Singleton
+ (Config *)shared;

/// Main storage
@property (strong, nonatomic) NSMutableDictionary *config; /// [Aug 2025] This could just be an ivar instead of a property  (Except if we wanna support KVO)

/// Load
+ (void)load_Manual;

/// Load from file
- (void)loadConfigFromFile;

/// Read and write
NSObject * _Nullable config(NSString *keyPath);
void setConfig(NSString *keyPath, NSObject *value);
void removeFromConfig(NSString *keyPath);
void commitConfig(void);

/// Repair
- (void) repairIncompleteAppOverrideForBundleID: (NSString *)bundleID                           
                               relevantKeyPaths: (NSArray <NSString *> *)keyPathsToDefaultValues;
- (void) cleanConfig;

#pragma mark - For Helper

/// Overrides
- (BOOL)loadOverridesForAppUnderMousePointerWithEvent:(CGEventRef)event;

/// Fork: app overrides, keyed on the FRONTMOST app.
///     Upstream only ever resolved overrides via the app under the *mouse pointer* (the method above, whose only
///     caller is disabled at Scroll.m:375). That's arguably right for scrolling — you scroll what you point at —
///     but wrong for buttons, which belong to whatever app has focus. This fork only does frontmost.
///     `HelperState` owns the tracking and calls this on NSWorkspace.didActivateApplicationNotification.
- (void)loadOverridesForApp:(NSString *)bundleID;
@property (strong, nonatomic, readonly) NSString *currentAppOverrideBundleID; /// "" == no override / global
@property (strong, nonatomic, readonly) NSMutableDictionary *configWithAppOverridesApplied; /// [Aug 2025] This could just be an ivar

/// React
+ (void)loadFileAndUpdateStates;


@end

NS_ASSUME_NONNULL_END
