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

@objc class HelperState: NSObject {
    
    // MARK: Singleton & init
    @objc static let shared = HelperState()
    override init() {
        super.init()
        initUserIsActive()
        DispatchQueue.main.async { /// Need to do this to avoid strange Swift crashes when this is triggered from `SwitchMaster.load_Manual()`
            SwitchMaster.shared.helperStateChanged()
        }
    }
    
    // MARK: Scroll & Zoom Mode (fork)

    /// A latched mode for trackballs. While it's on:
    ///     - moving the ball scrolls in any direction, instead of moving the pointer
    ///       (this is upstream's `TwoFingerSwipe` modifiedDrag — the same thing as the "Scroll & Navigate" drag
    ///        effect, just latched on rather than held with a button)
    ///     - the scroll ring zooms, as though Control were held (see Scroll.m)
    ///     - clicking any button exits (see Buttons.swift)
    ///
    /// Lives on HelperState because Scroll.m (objc), Buttons.swift and Actions.m all need to reach it, and
    /// HelperState is already imported by all three. Avoids adding a file to the .xcodeproj.

    @objc private(set) var scrollAndZoomModeIsActive: Bool = false

    @objc func toggleScrollAndZoomMode() {
        setScrollAndZoomMode(!scrollAndZoomModeIsActive)
    }

    @objc func setScrollAndZoomMode(_ active: Bool) {

        if active == scrollAndZoomModeIsActive { return }
        scrollAndZoomModeIsActive = active

        DDLogInfo("HelperState: Scroll & Zoom Mode -> \(active ? "ON" : "OFF")")

        if active {
            /// Latch the two-finger-swipe drag. Its own eventTap then turns ball movement into scrolls.
            ModifiedDrag.initializeDrag(withDict: [kMFModifiedDragDictKeyType: kMFModifiedDragTypeTwoFingerSwipe])
            /// Don't carry a stale 'owed mouseUp' into a new session — it would swallow an unrelated click.
            awaitingPrimaryClickUp = false
        } else {
            ModifiedDrag.deactivate()
        }

        setPrimaryClickExitTapEnabled(active)

        /// The scroll tap has to be on while the mode is active, so the ring can be turned into zoom even with no
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
                if state.scrollAndZoomModeIsActive || state.awaitingPrimaryClickUp,
                   let tap = state.primaryClickExitTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .leftMouseDown || type == .rightMouseDown {

                guard state.scrollAndZoomModeIsActive else {
                    return Unmanaged.passUnretained(event) /// Not ours -> hands off.
                }

                state.setScrollAndZoomMode(false)
                /// setScrollAndZoomMode(false) just disabled this tap, but we still need the matching mouseUp so the
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
                if !state.scrollAndZoomModeIsActive, let tap = state.primaryClickExitTap {
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
