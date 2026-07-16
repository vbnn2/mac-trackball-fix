//
// --------------------------------------------------------------------------
// HelperState.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// This class holds global state. Use sparingly!

import Foundation
import CoreGraphics

/// Fork: latched trackball modes. See `HelperState.trackballMode`.
///     File scope rather than nested in HelperState so ObjC gets `MFTrackballModeZoomOnly` rather than
///     `HelperStateMFTrackballModeZoomOnly`.
@objc enum MFTrackballMode: Int {
    case off = 0
    /// Ball scrolls in any direction (upstream's `TwoFingerSwipe` modifiedDrag — the same effect as the
    /// "Scroll & Navigate" drag effect, just latched on rather than held with a button), ring zooms.
    case scrollAndZoom = 1
    /// Ball keeps moving the pointer as normal; only the ring changes. Effectively a latched zoom modifier.
    case zoomOnly = 2
}

@objc class HelperState: NSObject {
    
    // MARK: Singleton & init
    @objc static let shared = HelperState()
    override init() {
        super.init()
        initUserIsActive()
        initFrontmostAppTracking()
        DispatchQueue.main.async { /// Need to do this to avoid strange Swift crashes when this is triggered from `SwitchMaster.load_Manual()`
            SwitchMaster.shared.helperStateChanged()
        }
    }

    // MARK: App overrides (fork)

    /// Which app's overrides are currently applied. "" == global / no override.
    ///
    /// Scoped to the FRONTMOST app deliberately. Upstream's only resolver keys off the app under the mouse
    /// *pointer* (`loadOverridesForAppUnderMousePointerWithEvent:`, whose sole caller is disabled at
    /// Scroll.m:375). That suits scrolling — you scroll what you point at — but not buttons, which belong to
    /// whatever has focus. This fork is button-first, so: frontmost only.
    ///
    /// Why a notification rather than polling on the input path: upstream's pointer resolver calls
    /// `HelperUtility appUnderMousePointer` (an AX/CG lookup) and had to be gated behind
    /// `mouseDidMove || frontMostAppDidChange` to stay off the scroll hot path. NSWorkspace tells us for free.
    @objc private(set) var frontmostAppBundleID: String = ""

    private func initFrontmostAppTracking() {

        applyOverrides(forApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", isInitial: true)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.applyOverrides(forApp: app?.bundleIdentifier ?? "", isInitial: false)
        }
    }

    private func applyOverrides(forApp bundleID: String, isInitial: Bool) {

        if !isInitial && bundleID == frontmostAppBundleID { return }
        frontmostAppBundleID = bundleID

        /// Cheap when there's no override for this app: loadOverridesForApp: just points
        /// `configWithAppOverridesApplied` back at the base config.
        Config.shared().loadOverrides(forApp: bundleID)

        /// Rebuild the remaps from the newly-merged config, and let SwitchMaster re-decide which taps it needs
        /// (Remap.reload() notifies it). Skipped on the initial call — Config/Remap aren't loaded yet at
        /// HelperState.init() time, and updateDerivedStates() will do it as part of normal startup.
        if !isInitial {
            DDLogDebug("HelperState: frontmost app -> \(bundleID.isEmpty ? "<none>" : bundleID)")

            /// Don't clobber an in-progress recording. `Remap.reload()` disables addMode (Remap.m), and a
            /// frontmost-app change fires while you record a per-app remap: to click the add field you activate
            /// the MMF window, which *is* an app switch, so reloading here would cancel addMode before the button
            /// press is captured. That's why recording failed whenever another app was frontmost.
            ///     We still updated `frontmostAppBundleID` and staged the override via `loadOverrides(forApp:)`
            ///     above, so the right config is live once addMode concludes (`disableAddMode` reloads then).
            if Remap.addModeIsEnabled { return }

            Remap.reload()
        }
    }
    
    // MARK: Trackball modes (fork)

    /// Latched modes for trackballs. In *any* active mode:
    ///     - the scroll ring zooms, as though Control were held (see Scroll.m)
    ///     - clicking any button exits (see Buttons.swift, plus `primaryClickExitTap` below for MB1/MB2)
    /// The modes differ only in what the ball does.
    ///
    /// Lives on HelperState because Scroll.m (objc), Buttons.swift and Actions.m all need to reach it, and
    /// HelperState is already imported by all three. Avoids adding a file to the .xcodeproj.
    ///
    /// `MFTrackballMode` is declared at file scope, not nested here — a nested @objc enum would be exported to
    /// ObjC as `HelperStateMFTrackballMode`, and Actions.m wants plain `MFTrackballModeZoomOnly`.
    ///
    /// The property is deliberately NOT @objc: `@objc private(set) var trackballMode` synthesises a
    /// `setTrackballMode:` selector that collides with `setTrackballMode(_:)` below. Nothing in ObjC needs the raw
    /// mode anyway — Scroll.m asks `trackballModeIsActive`, Actions.m calls `toggleTrackballMode:`.
    private(set) var trackballMode: MFTrackballMode = .off

    /// Everything except the drag keys off this, not off a specific mode — so adding a third mode later doesn't
    /// mean hunting down every reader.
    @objc var trackballModeIsActive: Bool { trackballMode != .off }

    /// For ObjC readers that need the specific mode. (`trackballMode` itself can't be @objc — see above.)
    @objc var trackballModeIsScrollAndZoom: Bool { trackballMode == .scrollAndZoom }

    /// Pressing a mode's own button while that mode is on turns it off. Note this is rarely reached: Buttons.swift
    /// intercepts *any* button press while a mode is active and exits, so in practice the button never gets as far
    /// as running its action. Kept correct anyway for MB1/MB2 and for direct callers.
    @objc func toggleTrackballMode(_ mode: MFTrackballMode) {
        setTrackballMode(trackballMode == mode ? .off : mode)
    }

    @objc func setTrackballMode(_ mode: MFTrackballMode) {

        if mode == trackballMode { return }

        let wasDragging = (trackballMode == .scrollAndZoom)
        let willDrag = (mode == .scrollAndZoom)
        trackballMode = mode

        DDLogInfo("HelperState: trackball mode -> \(mode == .off ? "OFF" : (mode == .scrollAndZoom ? "SCROLL & ZOOM" : "ZOOM ONLY"))")

        /// Only `.scrollAndZoom` latches the drag. `.zoomOnly` deliberately leaves the ball alone — the whole point
        /// is that the pointer still works while the ring zooms.
        if willDrag && !wasDragging {
            ModifiedDrag.initializeDrag(withDict: [kMFModifiedDragDictKeyType: kMFModifiedDragTypeTwoFingerSwipe])
        } else if wasDragging && !willDrag {
            ModifiedDrag.deactivate()
        }

        if mode != .off {
            /// Don't carry a stale 'owed mouseUp' into a new session — it would swallow an unrelated click.
            awaitingPrimaryClickUp = false
        }

        setPrimaryClickExitTapEnabled(mode != .off)

        /// The scroll tap has to be on while a mode is active, so the ring can be turned into zoom even with no
        /// modifiers held. SwitchMaster decides tap state, so tell it something changed.
        SwitchMaster.shared.helperStateChanged()
    }

    /// Left/right click exit tap.
    ///
    /// Why this is needed at all: `ButtonInputReceiver`'s tap mask is `OtherMouseDown|OtherMouseUp` only
    /// (ButtonInputReceiver.m:59) — left and right click are deliberately commented out, with a note that capturing
    /// MB1 there caused stuck click-and-drag race conditions. So buttons 3+ reach Buttons.handleInput and can exit
    /// the mode, but MB1/MB2 never would. Hence a separate tap.
    ///
    /// It exists only while the mode is on, so normal clicking is completely untouched the rest of the time — which
    /// also sidesteps the race that made upstream drop MB1 from the main tap.

    private var primaryClickExitTap: CFMachPort? = nil

    private func setPrimaryClickExitTapEnabled(_ enable: Bool) {

        if !enable {
            if let tap = primaryClickExitTap { CGEvent.tapEnable(tap: tap, enable: false) }
            return
        }

        if let tap = primaryClickExitTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }

        /// Listen to down *and* up: we swallow the down that exits, so its up must be swallowed too or the app gets
        /// a mouseUp with no matching mouseDown.
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)  | (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in

            let state = HelperState.shared

            /// Decide what to swallow from *state*, never from whether the tap happens to be enabled.
            ///     This is load-bearing: an earlier version returned nil unconditionally, so any moment the tap was
            ///     live while the mode was off swallowed every click and left the mouse unable to click at all.
            ///     macOS disables taps on its own (timeout / user input) and we re-enable them, so "the tap is
            ///     enabled" is never a safe proxy for "this event is ours".

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                /// Only resurrect the tap if we still have a use for it.
                if state.trackballModeIsActive || state.awaitingPrimaryClickUp,
                   let tap = state.primaryClickExitTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .leftMouseDown || type == .rightMouseDown {

                guard state.trackballModeIsActive else {
                    return Unmanaged.passUnretained(event) /// Not ours -> hands off.
                }

                state.setTrackballMode(.off)
                /// setTrackballMode(.off) just disabled this tap, but we still need the matching mouseUp so the
                /// app doesn't get an up without a down. Keep it alive; the up branch below retires it.
                state.awaitingPrimaryClickUp = true
                if let tap = state.primaryClickExitTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return nil /// Swallow: this click only leaves the mode, it doesn't also click.
            }

            if type == .leftMouseUp || type == .rightMouseUp {

                guard state.awaitingPrimaryClickUp else {
                    return Unmanaged.passUnretained(event) /// Not ours -> hands off.
                }

                state.awaitingPrimaryClickUp = false
                if !state.trackballModeIsActive, let tap = state.primaryClickExitTap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                return nil /// Swallow the up belonging to the down we swallowed above.
            }

            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: nil)
        else {
            DDLogError("HelperState: Failed to create the Scroll & Zoom Mode exit tap. MB1/MB2 won't exit the mode.")
            assert(false)
            return
        }

        primaryClickExitTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate var awaitingPrimaryClickUp: Bool = false

    // MARK: Fast user switching
    /// See Apple Docs at: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/FastUserSwitching.html#//apple_ref/doc/uid/20002209-104219-BAJJIFCB

    var userIsActive: Bool = false
    func initUserIsActive() {
        
        /// Init userIsActive
        userIsActive = userIsActive_Manual()
        
        /// Listen to user switches and update userIsActive
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { notification in
            self.userIsActive = true
            assert(self.userIsActive_Manual() == self.userIsActive)
            SwitchMaster.shared.helperStateChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { notification in
            self.userIsActive = false
            assert(self.userIsActive_Manual() == self.userIsActive)
            SwitchMaster.shared.helperStateChanged()
        }
        
    }
    
    private func userIsActive_Manual() -> Bool {
        /// For debugging and stuff
        guard let d = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        guard let result = d.value(forKey: kCGSessionOnConsoleKey) as? Bool else { return false } /// [Mar 2025] why 'kCGSessionOnConsoleKey'? – that's weird... Here's an SO post that also mentions this: https://stackoverflow.com/a/8790102/10601702
        return result
    }
    
    // MARK: Active device
    /// Might be more appropriate to have this as part of DeviceManager
    
    private var _activeDevice: Device? = nil
    @objc var activeDevice: Device? {
        set {
            _activeDevice = newValue
            SwitchMaster.shared.helperStateChanged()
        }
        get {
            if _activeDevice != nil {
                return _activeDevice
            } else { /// Just return any attached device as a fallback
                /// NOTE: Swift let me do `attachedDevices.first` (even thought that's not defined on NSArray) without a compiler warning which did return a Device? but the as! Device? cast still crashed. Using `attachedDevices.firstObject` it doesn't crash.
                return DeviceManager.attachedDevices.firstObject as! Device?
            }
        }
    }
    
    @objc func updateActiveDevice(event: CGEvent) {
        guard let iohidDevice = CGEventGetSendingDevice(event)?.takeUnretainedValue() else { return }
        updateActiveDevice(IOHIDDevice: iohidDevice)
    }
    @objc func updateActiveDevice(eventSenderID: UInt64) {
        guard let iohidDevice = getSendingDeviceWithSenderID(eventSenderID)?.takeUnretainedValue() else { return }
        updateActiveDevice(IOHIDDevice: iohidDevice)
    }
    @objc func updateActiveDevice(IOHIDDevice: IOHIDDevice) {
        guard let device = DeviceManager.attachedDevice(with: IOHIDDevice) else { return }
        activeDevice = device
    }
}
