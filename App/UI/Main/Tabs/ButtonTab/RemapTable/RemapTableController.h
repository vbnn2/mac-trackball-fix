//
// --------------------------------------------------------------------------
// RemapTableController.h
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Were exposing most of this just so RemapTableTranslator can use it. Might not be the cleanest solution.

@interface RemapTableController :  NSViewController <NSTableViewDelegate>


///
/// Interaction with `RemapTableTranslator`
///     `dataModel` Is actually an NSMutableArray I think. Take care not to accidentally corrupt this!
@property NSArray *dataModel;
@property (readonly) NSArray *groupedDataModel;

- (void)addRowWithHelperPayload:(NSDictionary *)payload;
- (IBAction)handleKeystrokeMenuItemSelected:(id)sender;
- (IBAction)updateTableAndWriteToConfig:(id _Nullable)sender;

///
/// Interation with `ButtonTabController`
///
- (void)reloadAll;

/// Fork: which app's remaps this table is editing.
///     `nil` or `@""` == global (`config[Remaps]`, the normal MMF behaviour).
///     A bundleID    == that app's override (`config[AppOverrides][<id>][Root][Remaps]`).
///     Set it, then call `-reloadAll`.
@property (nonatomic, strong, nullable) NSString *appScopeBundleID;

/// Does an override table exist for `bundleID`? (An *empty* table still counts — that's a meaningful override.)
+ (BOOL)hasOverrideForBundleID:(NSString *)bundleID;
+ (NSArray<NSString *> *)bundleIDsWithOverrides;
+ (void)removeOverrideForBundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
