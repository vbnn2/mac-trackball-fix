//
// --------------------------------------------------------------------------
// CoolSUUpdater.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2024
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import "CoolSUUpdater.h"
#import "SparkleUpdaterController.h"
#import "Logging.h"

@implementation CoolSUUpdater

- (void)checkForUpdates:(id)sender {

    /// This is invoked, when the user chooses `Check for Updates...` from the menu bar.
    ///     (Make sure the .xib files actually connects to this subclass instead of SUUpdater)

    /// Fork: Updates are disabled.
    ///     This is a fork, so we never want to pull updates from upstream's appcast. We no-op here instead of
    ///     calling `[super checkForUpdates:sender]`, which would contact the update server and could offer the
    ///     user a build from a different project. The menu item is also removed from the storyboard, but this
    ///     guards the action in case anything else invokes it.
    DDLogInfo("UPDATER: checkForUpdates: ignored — updates are disabled in this fork.");
    return;
}

@end
