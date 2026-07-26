//
// --------------------------------------------------------------------------
// Remap.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import "Remap.h"
#import "ModificationUtility.h"
#import "SharedUtility.h"
#import "ButtonTriggerGenerator.h"
#import "Actions.h"
#import "Modifiers.h"
#import "ModifiedDrag.h"
#import "NSArray+Additions.h"
#import "NSDictionary+Additions.h"
#import "Constants.h"
#import "Config.h"
#import "MFMessagePort.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"
#import "RemapSwizzler.h"
#import <os/lock.h>

@implementation Remap

#pragma mark - Notes

/// On Terminology
/// This used to be called `TransformationManager`. Renamed to `Remap` to unify terminology.
/// Desired Terminology: The `remaps` are a map from `modifiers` -> `modifications`, where a `modification` is itself a map from `trigger ` -> `effect`. More on this in RemapSwizzler.swift
///

#pragma mark - Swizzled

static os_unfair_lock _remapStateLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *_swizzleCache = nil;
static NSDictionary *_remaps;
static uint64_t _remapGeneration = 0;
static BOOL _addModeIsEnabled = NO;

+ (void)setRemaps:(NSDictionary *)remapsDict
    addModeEnabled:(NSNumber * _Nullable)addModeEnabled {

    NSDictionary *immutableRemaps = [remapsDict copy];

    os_unfair_lock_lock(&_remapStateLock);
    BOOL nextAddModeIsEnabled =
        addModeEnabled != nil ? addModeEnabled.boolValue : _addModeIsEnabled;
    BOOL remapsAreEqual = [_remaps isEqualToDictionary:immutableRemaps];
    BOOL addModeIsEqual = _addModeIsEnabled == nextAddModeIsEnabled;

    if (remapsAreEqual && addModeIsEqual) {
        os_unfair_lock_unlock(&_remapStateLock);
        DDLogDebug("Remaps were set to the same value");
        return;
    }

    /// Publish the mode and its matching table as one generation. Readers may
    /// calculate outside the lock, but generation validation prevents a mixed
    /// add-mode/ordinary result from entering the cache.
    _remaps = immutableRemaps;
    _addModeIsEnabled = nextAddModeIsEnabled;
    _remapGeneration += 1;
    [_swizzleCache removeAllObjects];
    NSDictionary *publishedRemaps = _remaps;
    os_unfair_lock_unlock(&_remapStateLock);

    /// Notify outside the state lock: SwitchMaster and RemapsAnalyzer call back
    /// into Remap while deriving their state.
    [SwitchMaster.shared remapsChangedWithRemaps:publishedRemaps];
    [RemapsAnalyzer reload];
    DDLogDebug("Set remaps to: %@", publishedRemaps);
}

+ (NSDictionary * _Nullable)modificationsWithModifiers:(NSDictionary *)modifiers {

    /// Build outside the lock, then publish only if the remap generation is
    /// unchanged. This keeps the scroll path responsive without permitting an
    /// NSMutableDictionary read/write race or returning a stale swizzle.
    while (true) {
        os_unfair_lock_lock(&_remapStateLock);
        if (_swizzleCache == nil) {
            _swizzleCache = [NSMutableDictionary dictionary];
        }
        NSDictionary *cached = _swizzleCache[modifiers];
        NSDictionary *remapsSnapshot = _remaps ?: @{};
        uint64_t generation = _remapGeneration;
        os_unfair_lock_unlock(&_remapStateLock);

        if (cached) {
            return cached;
        }

        DDLogDebug("Recalculating modifications for modifiers: %@", modifiers);
        NSDictionary *newModifications =
            [[RemapSwizzler swizzleRemaps:remapsSnapshot activeModifiers:modifiers] copy];

        os_unfair_lock_lock(&_remapStateLock);
        if (generation != _remapGeneration) {
            os_unfair_lock_unlock(&_remapStateLock);
            continue;
        }
        NSDictionary *concurrentlyCached = _swizzleCache[modifiers];
        if (concurrentlyCached == nil && newModifications != nil) {
            _swizzleCache[modifiers] = newModifications;
            concurrentlyCached = newModifications;
        }
        os_unfair_lock_unlock(&_remapStateLock);
        return concurrentlyCached;
    }
}

#pragma mark - Storage

#define USE_TEST_REMAPS NO

+ (NSDictionary *)remaps {
    os_unfair_lock_lock(&_remapStateLock);
    NSDictionary *result = _remaps ?: @{};
    os_unfair_lock_unlock(&_remapStateLock);
    return result;
}

+ (void)setRemaps:(NSDictionary *)remapsDict {
    
    /// This method is private. It's used by `reload` and `enableAddMode`.

    [self setRemaps:remapsDict addModeEnabled:nil];
}

#pragma mark - Reload

+ (void)reload {
    [self reloadEndingAddMode:NO];
}

+ (void)reloadEndingAddMode:(BOOL)endingAddMode {

    /// The main app uses an array of dicts (aka a table) to represent the remaps in a way that is easy to present in a table view.
    /// The remaps are also stored to file in this format and therefore what `Config.config` contains.
    /// The helper was made to handle a dictionary format which should be more effictient among other perks.
    /// This function takes the remaps in table format from config, then converts it to dict format and makes that available to all the other Input modification classes to base their behaviour off of through self.remaps.
    
    DDLogDebug("TRM set remaps to config");

    ///
    /// Fork: don't cancel an in-progress recording (addMode).
    ///
    /// Upstream unconditionally disabled addMode here, on the assumption that reloads are rare while you're
    /// recording. This fork broke that assumption: a config change (per-app remap write → `configFileChanged`
    /// → `updateDerivedStates`) or a frontmost-app switch now calls `reload` frequently — and each one would
    /// rebuild `_remaps` from config, which (a) drops the synthetic addMode capture table and (b) makes
    /// SwitchMaster turn the button eventTap *off* (no button binds for the frontmost app), so the button you
    /// press to record is never even received. That's the intermittent "recording does nothing".
    ///
    /// So while addMode is enabled we DEFER the reload: keep the capture table live and the tap on. The reload
    /// isn't lost — `disableAddMode` invokes this builder with `endingAddMode`
    /// so the ordinary table and the disabled state are published atomically.
    if (self.addModeIsEnabled && !endingAddMode) {
        return;
    }

    ///
    /// Load test remaps
    ///
    
    if (USE_TEST_REMAPS) {
        
        [self setRemaps:self.testRemaps
         addModeEnabled:endingAddMode ? @NO : nil];
        
    } else {
        
        ///
        /// Load remaps from config
        ///
        
        NSMutableDictionary *remapsDict = [NSMutableDictionary dictionary];
        
        ///
        /// Get keyboard mods from scroll screen
        ///
        
        if ([(id)config(@"General.scrollKillSwitch") boolValue]) { /// Disable keyboard mods when scrollKillSwitch is on
            
        } else {
            
            NSEventModifierFlags horizontal = [(id)config(@"Scroll.modifiers.horizontal") unsignedIntegerValue];
            NSEventModifierFlags zoom = [(id)config(@"Scroll.modifiers.zoom") unsignedIntegerValue];
            NSEventModifierFlags swift = [(id)config(@"Scroll.modifiers.swift") unsignedIntegerValue];
            NSEventModifierFlags precise = [(id)config(@"Scroll.modifiers.precise") unsignedIntegerValue];
            /// ^ Might be faster to only get Scroll.modifiers once and then query that? Probably not significant
            
            if (horizontal) {
                NSDictionary *precondition = @{
                    kMFModificationPreconditionKeyKeyboard: @(horizontal)
                };
                NSDictionary *effect = @{
                    kMFTriggerScroll: @{
                        kMFModifiedScrollDictKeyEffectModificationType: kMFModifiedScrollEffectModificationTypeHorizontalScroll
                    }
                };
                [remapsDict setObject:effect forKey:precondition];
            }
            if (zoom) {
                NSDictionary *precondition = @{
                    kMFModificationPreconditionKeyKeyboard: @(zoom)
                };
                NSDictionary *effect = @{
                    kMFTriggerScroll: @{
                        kMFModifiedScrollDictKeyEffectModificationType: kMFModifiedScrollEffectModificationTypeZoom
                    }
                };
                [remapsDict setObject:effect forKey:precondition];
            }
            if (swift) {
                NSDictionary *precondition = @{
                    kMFModificationPreconditionKeyKeyboard: @(swift)
                };
                NSDictionary *effect = @{
                    kMFTriggerScroll: @{
                        kMFModifiedScrollDictKeyInputModificationType: kMFModifiedScrollInputModificationTypeQuickScroll
                    }
                };
                [remapsDict setObject:effect forKey:precondition];
            }
            if (precise) {
                NSDictionary *precondition = @{
                    kMFModificationPreconditionKeyKeyboard: @(precise)
                };
                NSDictionary *effect = @{
                    kMFTriggerScroll: @{
                        kMFModifiedScrollDictKeyInputModificationType: kMFModifiedScrollInputModificationTypePrecisionScroll
                    }
                };
                [remapsDict setObject:effect forKey:precondition];
            }
        }
        
        ///
        /// Get values from action table (button remaps)
        ///
        
//        BOOL killSwitch = [(id)config(@"General.buttonKillSwitch") boolValue] /*|| HelperState.shared.isLockedDown*/;
        
//        if (killSwitch) {
//            /// TODO: Turn off button interception completely (generally when the remaps dict is empty)
//        } else {
            
        /// Convert remaps table to remaps dict
        
        /// Fork: read the override-applied config so per-app remaps take effect.
        ///     `configWithAppOverridesApplied` is the base config with `AppOverrides[<frontmost bundleID>][Root]`
        ///     merged over it (Config.m:loadOverridesForApp:). It equals the base config when there's no override
        ///     for the current app, so the global case is unchanged.
        ///     Falls back to the base config: the property is only populated on the helper side and only once
        ///     `loadOverridesForApp:` has run — don't let a reload ordering quirk wipe every remap.
        NSDictionary *configForRemaps = Config.shared.configWithAppOverridesApplied ?: Config.shared.config;
        NSArray *remapsTable = [configForRemaps objectForKey:kMFConfigKeyRemaps];
        
        for (NSDictionary *tableEntry in remapsTable) {
            /// Get modification precondition section of keypath
            NSDictionary *modificationPrecondition = tableEntry[kMFRemapsKeyModificationPrecondition];
            /// Get trigger section of keypath
            NSArray *triggerKeyArray;
            id trigger = tableEntry[kMFRemapsKeyTrigger];
            if ([trigger isKindOfClass:NSString.class]) {
                NSString *triggerStr = (NSString *)trigger;
                triggerKeyArray = @[triggerStr];
                NSAssert([triggerStr isEqualToString:kMFTriggerScroll] || [triggerStr isEqualToString:kMFTriggerDrag] , @"");
            } else if ([trigger isKindOfClass:NSDictionary.class]) {
                NSDictionary *triggerDict = (NSDictionary *)trigger;
                NSString *duration = triggerDict[kMFButtonTriggerKeyDuration];
                NSNumber *level = triggerDict[kMFButtonTriggerKeyClickLevel];
                NSNumber *buttonNum = triggerDict[kMFButtonTriggerKeyButtonNumber];
                triggerKeyArray = @[buttonNum, level, duration];
            } else NSAssert(NO, @"");
            /// Get effect
            id effect = tableEntry[kMFRemapsKeyEffect]; /// This is always dict
            if ([trigger isKindOfClass:NSDictionary.class]) {
                effect = @[effect];
                /// ^ For some reason we built one shot effect handling code around _arrays_ of effects. So we need to wrap our effect in an array.
                ///  This doesn't make sense. We should clean this up at some point and remove the array.
            }
            /// Put it all together
            NSArray *keyArray = [@[modificationPrecondition] arrayByAddingObjectsFromArray:triggerKeyArray];
            [remapsDict setObject:effect forCoolKeyArray:keyArray];
        }
        
//        }
        
        [self setRemaps:remapsDict
         addModeEnabled:endingAddMode ? @NO : nil];
    }
}

#pragma mark - AddMode

+ (BOOL)addModeIsEnabled {
    os_unfair_lock_lock(&_remapStateLock);
    BOOL result = _addModeIsEnabled;
    os_unfair_lock_unlock(&_remapStateLock);
    return result;
}

+ (BOOL)enableAddMode {

    /// \discussion  Add mode configures the helper such that it remaps to "add mode feedback effects" instead of normal effects.
    /// When "add mode feedback effects" are triggered, the helper will send information about how exactly the effect was triggered to the main app.
    /// This allows us to capture triggers that the user performs and use them in the main app to add new rows to the remaps table view
    /// The dataModel for the remaps table view is an array of dicts, where each dict is called a tableEntry.
    /// Each table entry has 3 keys:
    ///     - kMFRemapsKeyTrigger
    ///     - kMFRemapsKeyModificationPrecondition
    ///     - kMFRemapsKeyEffect
    /// Our feedback dicts we send to the main app during addMode use 3 - overlapping, but different - keys:
    ///     - kMFRemapsKeyTrigger
    ///     - kMFRemapsKeyModificationPrecondition
    ///     - kMFActionDictKeyType / kMFModifiedDragDictKeyType (Edit: or kMFModifiedScrollDictKeyType)
    /// kMFActionDictKeyType / kMFModifiedDragDictKeyType is added in this funciton and used so the helper knows how to process the dictionary, but it's removed before we send stuff off to the mainApp
    /// kMFRemapsKeyTrigger is added in this function, and eventually sent off to the main app
    /// kMFRemapsKeyModificationPrecondition is addedDynamically in **RemapSwizzler**.
    /// So the final feedback dict we send to the main app contains values for the keys
    ///     - kMFRemapsKeyTrigger
    ///     - kMFRemapsKeyModificationPrecondition
    /// So it's _almost_ a tableEntry which can be used by the mainApp's remap tableview's dataModel, it's just lacking the kMFRemapsKeyEffect key and values.
    /// This makes sense, because The effect is then to be chosen by the user in the main app's GUI
    ///
    /// We implemented a policy of "modifiers need to be present to capture drags and scrolls" using the `addModePayloadIsValid:` method.
    ///     Edit: The remapSwizzler is actually responsible for this now.
    ///     TODO: Remove addModePayloadIsValid.
    
    DDLogDebug("TRM set remaps to addMode");
    
    NSMutableDictionary *triggerToEffectDict = [NSMutableDictionary dictionary];
    
    /// Drag trigger
    triggerToEffectDict[kMFTriggerDrag] = @{
        kMFModifiedDragDictKeyType: kMFModifiedDragTypeAddModeFeedback,
        kMFRemapsKeyTrigger: kMFTriggerDrag,
    }.mutableCopy;
    /// Scroll trigger
    triggerToEffectDict[kMFTriggerScroll] = @{
        kMFModifiedScrollDictKeyEffectModificationType: kMFModifiedScrollEffectModificationTypeAddModeFeedback,
        kMFRemapsKeyTrigger: kMFTriggerScroll,
    }.mutableCopy;
    
    /// Button triggers (dict based)
    for (int btn = 1; btn <= kMFMaxButtonNumber; btn++) {
        for (int lvl = 1; lvl <= 3; lvl++) {
            for (NSString *dur in @[kMFButtonTriggerDurationClick, kMFButtonTriggerDurationHold]) {
                
                NSMutableDictionary *addModeFeedbackDict = @{
                    kMFActionDictKeyType: kMFActionDictTypeAddModeFeedback,
                    kMFRemapsKeyTrigger: @{
                        kMFButtonTriggerKeyButtonNumber: @(btn),
                        kMFButtonTriggerKeyClickLevel: @(lvl),
                        kMFButtonTriggerKeyDuration: dur,
                    }
                }.mutableCopy;
                [triggerToEffectDict setObject:@[addModeFeedbackDict] forCoolKeyArray:@[@(btn),@(lvl),dur]];
                ///  ^ We're wrapping `addModeFeedbackDict` in an array here because we started building helper with dicts of several effects in mind.
                ///      This doesn't make sense though and we should remove it.
            }
        }
    }
    
    /// Send feedback
//    [MFMessagePort sendMessage:@"addModeEnabled" withPayload:nil expectingReply:NO];
    
    /// Set `_remaps` to generated
    ///    Why weren't we using setRemaps here? Changed it to setRemaps now. Hopefully nothing breaks.

    [self setRemaps:@{
        @{}: triggerToEffectDict
    } addModeEnabled:@YES];
    
    /// Return success
    return YES;
}

+ (BOOL)disableAddMode {

    /// Reload
    if (self.addModeIsEnabled) {
        /// Keep the currently published add-mode flag/table pair intact while the
        /// ordinary table is built, then swap both in one generation.
        [self reloadEndingAddMode:YES];
    }

    /// Return success
    return YES;
}

//+ (void)disableAddModeWithPayload:(NSDictionary *)payload {
//    /// Wrapper for disableAddMode. Not sure if this is useful
//
//    if (![self addModePayloadIsValid:payload]) return;
//
//    [self disableAddMode];
//}

//+ (void)sendAddModeFeedbackWithPayload:(NSDictionary *)payload {
//
//    if (![self addModePayloadIsValid:payload]) return;
//
//    [MFMessagePort sendMessage:@"addModeFeedback" withPayload:payload expectingReply:NO];
//    ///    [Remap performSelector:@selector(disableAddMode) withObject:nil afterDelay:0.5];
//    /// ^ We did this to keep the remapping disabled for a little while after adding a new row, but it leads to adding several entries at once when trying to input button modification precondition, if you're not fast enough.
//}

+ (void)sendAddModeFeedback:(NSDictionary *)payload {
    
    DDLogDebug("Concluding addMode with payload: %@", payload);
    
    if (![self addModePayloadIsValid:payload]) {
        /// The way things are set up currently, we constantly get invalid payloads. So we just ignore them
//        [self disableAddMode];
        return;
    }
    
//    [self reload];
    
//    [MFMessagePort sendMessage:@"addModeDisabled" withPayload:nil expectingReply:NO];
    
    
    
    [MFMessagePort sendMessage:@"addModeFeedback" withPayload:payload waitForReply:NO];
    ///    [Remap performSelector:@selector(disableAddMode) withObject:nil afterDelay:0.5];
    /// ^ We did this to keep the remapping disabled for a little while after adding a new row, but it leads to adding several entries at once when trying to input button modification precondition, if you're not fast enough.

}

/// Using this to prevent payloads containing a modifiedDrag / modifiedScroll with a keyboard-modifier-only precondition, or an empty precondition from being sent to the main app
/// Empty preconditions only happen when weird bugs occur so this is just an extra safety net for that
///     Edit: We simplified things now and this is the only safety net against sending payloads without necessary modificationPreconditions.
/// Keyboard-modifier-only modifiedDrags and modifiedScrolls work in principle but they cause some smaller bugs and issues in the mainApp UI. We don't wan't to polish that up so we're just disabling the ability to add them.
///     Also the remap table is completely structured around buttons now, so it wouldn't fit into the UI to have keyboard-modifier-only modifiedDrags and modifiedScrolls
+ (BOOL)addModePayloadIsValid:(NSDictionary *)payload {
    
    if ([payload[kMFRemapsKeyTrigger] isEqual:kMFTriggerDrag]
        || [payload[kMFRemapsKeyTrigger] isEqual:kMFTriggerScroll]) {
        
        NSArray *buttonPreconds = payload[kMFRemapsKeyModificationPrecondition][kMFModificationPreconditionKeyButtons];
        if (buttonPreconds == nil || buttonPreconds.count == 0) {
//            assert(false);
            return NO;
        }
    }
    return YES;
}

#pragma mark - Dummy Data

+ (NSDictionary *)testRemaps {
    /// This fanned out dictionary representation of our remappings is what we based our helper code on.
    /// It's not super human readable, but it should be very fast, and makes some of the operations like overrides and on the fly 'assessment of the mapping landscape' pretty handy.
    /// Using this in Helper is definitely faster than the tableView oriented (-> array based) structure which the MainApp uses. That's because we can do a lot of O(1) dict accesses where we'd have to use O(n) array searches using the other structure. I suspect that performance gains are negligible though.
    /// Having these 2 data structures might very well not be worth the cost of having to think about both and write a conversion function between them. But we've already built helper around this, and mainApp needs the table based structure, so we're sticking with this double-structure approach.
    return @{
        
        /// Empty precond
        
        @{}: @{                                                     // Key: modifier dict (empty -> no modifiers)
            //                @(3): @{                                                // Key: button
            //                        @(1): @{                                            // Key: level
            //                                kMFButtonTriggerDurationClick: @[                                   // Key: click/hold, value: array of actions
            //                                        @{
            //                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
            //                                            kMFActionDictKeyGenericVariant:@(kMFSHMissionControl)
            //                                        },
            //                                ],
            //                                kMFButtonTriggerDurationHold: @[                                  // Key: click/hold, value: array of actions
            //                                        @{
            //                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
            //                                            kMFActionDictKeyGenericVariant: @(kMFSHShowDesktop),
            //                                        },
            //                                ],
            //
            //                        },
            ////                        @(2): @{                                            // Key: level
            ////                                kMFButtonTriggerDurationClick: @[                                   // Key: click/hold, value: array of actions
            ////                                        @{
            ////                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
            ////                                            kMFActionDictKeyGenericVariant:@(kMFSHLookUp)
            ////                                        },
            ////                                ],
            ////                        }
            //                },
            @(4): @{                                                // Key: button
                @(1): @{                                            // Key: level
                    kMFButtonTriggerDurationClick: @[
                        @{
                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                            kMFActionDictKeyGenericVariant: @(kMFSHMissionControl),
                        }
                    ],
                    //                                kMFButtonTriggerDurationHold: @[
                    //                                        @{
                    //                                            kMFActionDictKeyType: kMFActionDictTypeSmartZoom,
                    //                                        }
                    //                                ],
                },
            },
            ////                        @(2): @{                                            // Key: level
            ////                                kMFButtonTriggerDurationClick: @[
            ////                                        @{
            ////                                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
            ////                                            kMFActionDictKeyGenericVariant: @(36),
            ////                                        }
            ////                                ],
            ////                        },
            //                },
            @(7)  : @{                                                // Key: button
                @(1): @{                                            // Key: level
                    kMFButtonTriggerDurationClick: @[                                  // Key: click/hold, value: array of actions
                        @{
                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                            kMFActionDictKeyGenericVariant: @(kMFSHLaunchpad),
                        },
                    ],
                },
            },
            
        },
        
        //        @{                                                          // Key: modifier dict
        //            kMFModificationPreconditionKeyButtons: @[
        //                    @{
        //                        kMFButtonModificationPreconditionKeyButtonNumber: @(3),
        //                        kMFButtonModificationPreconditionKeyClickLevel: @(2),
        //                    }
        //            ],
        //        }: @{
        //                kMFTriggerDrag: @{
        //                        kMFModifiedDragDictKeyType: kMFModifiedDragTypeFakeDrag,
        //                        kMFModifiedDragDictKeyFakeDragVariantButtonNumber: @3,
        //                }
        //        },
        
        /// Button 4 precond
        
        @{
            kMFModificationPreconditionKeyButtons: @[
                @{
                    kMFButtonModificationPreconditionKeyButtonNumber: @(4),
                    kMFButtonModificationPreconditionKeyClickLevel: @(1),
                },
            ],
            
        }: @{
            kMFTriggerScroll: @{
                kMFModifiedScrollDictKeyEffectModificationType: kMFModifiedScrollEffectModificationTypeZoom
            },
            kMFTriggerDrag: @{
                kMFModifiedDragDictKeyType: kMFModifiedDragTypeThreeFingerSwipe,
            },
            @(3): @{                                                // Key: button
                @(1): @{                                            // Key: level
                    kMFButtonTriggerDurationClick: @[
                        @{
                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                            kMFActionDictKeyGenericVariant: @(kMFSHSpotlight),
                        }
                    ],
                },
                @(2): @{                                            // Key: level
                    kMFButtonTriggerDurationClick: @[
                        @{
                            kMFActionDictKeyType: kMFActionDictTypeSymbolicHotkey,
                            kMFActionDictKeyGenericVariant: @(kMFSHLaunchpad),
                        }
                    ],
                },
            },
        },
        
        /// Button 5 precond
        
        @{
            kMFModificationPreconditionKeyButtons: @[
                @{
                    kMFButtonModificationPreconditionKeyButtonNumber: @(5),
                    kMFButtonModificationPreconditionKeyClickLevel: @(1),
                },
            ],
            
        }: @{
            kMFTriggerScroll: @{
                kMFModifiedScrollDictKeyEffectModificationType: kMFModifiedScrollEffectModificationTypeRotate,
            },
            kMFTriggerDrag: @{
                kMFModifiedDragDictKeyType: kMFModifiedDragTypeTwoFingerSwipe,
            },
        
        },
            
        /// Option precond
        
        @{
            kMFModificationPreconditionKeyKeyboard: @(NSEventModifierFlagOption)
        }: @{
            kMFTriggerScroll: @{
                kMFModifiedScrollDictKeyInputModificationType: kMFModifiedScrollInputModificationTypeQuickScroll
            }
        },
        
        /// Shift precond
            
        @{
            kMFModificationPreconditionKeyKeyboard: @(NSEventModifierFlagShift)
        }: @{
            kMFTriggerScroll: @{
                kMFModifiedScrollDictKeyEffectModificationType: kMFModifiedScrollEffectModificationTypeHorizontalScroll,
            }
        },

        
        /// Option & Shift precond
        
        @{
            kMFModificationPreconditionKeyKeyboard: @(NSEventModifierFlagOption | NSEventModifierFlagShift)
        }: @{
            kMFTriggerScroll: @{
                kMFModifiedScrollDictKeyEffectModificationType: kMFModifiedScrollEffectModificationTypeZoom
            }
        },
        
        /// Weird precond
        
        @{
            //            kMFModificationPreconditionKeyButtons: @[
            //                    @{
            //                        kMFButtonModificationPreconditionKeyButtonNumber: @(4),
            //                        kMFButtonModificationPreconditionKeyClickLevel: @(2),
            //                    },
            //                    @{
            //                        kMFButtonModificationPreconditionKeyButtonNumber: @(3),
            //                        kMFButtonModificationPreconditionKeyClickLevel: @(1),
            //                    },
            //            ],
            kMFModificationPreconditionKeyKeyboard: @(NSEventModifierFlagShift | NSEventModifierFlagControl)
        }: @{
            kMFTriggerDrag: @{
                kMFModifiedDragDictKeyType: kMFModifiedDragTypeThreeFingerSwipe,
            }
        },
    };
}


@end
