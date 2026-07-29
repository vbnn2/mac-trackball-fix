//
// --------------------------------------------------------------------------
// ScrollConfig.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

import Cocoa

@objc class ScrollConfig: NSObject /*, NSCoding*/ {
    
    /// This class has almost all instance properties
    /// You can request the config once, then store it.
    /// You'll receive an independent instance that you can override with custom values. This should be useful for implementing Modifications in Scroll.m
    ///     Everything in ScrollConfigResult is lazy so that you only pay for what you actually use
    /// Derived instances are constructed from the same immutable raw snapshot and
    /// then receive their overrides, so lazy values remain isolated per instance.
    ///
    /// Ideas for improving Smoothness: Regular [Apr 2025]
    ///         (Not sure this belongs here – do we have notes on this somewhere else?)
    ///     - Ease-out too slow on Smoothness: Regular?
    ///         I tested MMF 2 and after going back to MMF 3 the regular scrolling felt a bittt too slow. [Apr 2025]
    ///             One day I was kinda stressed out n angry and wanted to scan pages for something I was looking for. So you make lots of quick, large scrolls, followed by pauses to scan the page visually. The ease-out animation after the quick large scrolls felt a bit too long.
    ///             ... But now that I've used MMF 3 for a while and have calmed down, I don't feel that way anymore. It feels quite nice.
    ///     - Allow Increasing 'speed' for Smoothness: Regular by dynamically increasing animation duration?
    ///         IIRC, the 'speed' (sensitivity/acceleration) gets lower as you lower the smoothness. IIRC, this is because shortAnimations + high 'speed' means content moves so fast that it becomes jarring/disorientating for the eyes.
    ///         However, the lower 'speed' makes scrolling take more physical effort on lower smoothness settings, which I don't like.
    ///         Idea: Dynamically increase animation duration on large 'swipes' such that content doesn't move so fast as to be jarring. Then you could perhaps turn up the 'speed' for 'Smoothness: Regular'.
    
    // MARK: Convenience functions
    ///     For accessing top level dict and different sub-dicts
    
    /// Each instance owns the immutable raw snapshot from which its lazy values are
    /// derived. Reading a process-global raw dictionary made an old animation's config
    /// silently begin resolving values from a newer reload.
    private let scrollConfigRaw: NSDictionary

    private init(raw: NSDictionary) {
        self.scrollConfigRaw = raw
        super.init()
    }

    private func c(_ keyPath: String) -> NSObject? {
        return scrollConfigRaw.object(forCoolKeyPath: keyPath)
    }
    
    // MARK: Static functions
    
    private static let stateLock = NSLock()
    private static var _scrollConfigRaw = NSDictionary()
    private static var _shared = ScrollConfig(raw: _scrollConfigRaw)
    private static var cache = [_HT<MFScrollModificationResult, MFAxis, CGDirectDisplayID>: ScrollConfig]()
    private static var stateGeneration: UInt64 = 0

    @objc static var shared: ScrollConfig {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _shared
    }
    
    @objc static func reload() {
        
        /// Guard not equal
        
        guard let rawConfig = config("Scroll") as? NSDictionary else {
            DDLogError("MFSCROLL_CONFIG: action=reload-rejected reason=missing-scroll-dictionary")
            return
        }
        let newConfigRaw: NSDictionary
        if let encoded = try? PropertyListSerialization.data(
            fromPropertyList: rawConfig,
            format: .binary,
            options: 0),
           let decodedObject = try? PropertyListSerialization.propertyList(
            from: encoded,
            options: [],
            format: nil),
           let decoded = decodedObject as? NSDictionary {
            newConfigRaw = decoded
        } else {
            DDLogError("MFSCROLL_CONFIG: action=reload-deep-copy-failed fallback=shallow-copy")
            newConfigRaw = rawConfig.copy() as! NSDictionary
        }

        stateLock.lock()
        guard !_scrollConfigRaw.isEqual(newConfigRaw) else {
            stateLock.unlock()
            return
        }
        
        /// Notes:
        /// - This should be called when the underlying config (which mirrors the config file) changes
        /// - All the property values are cached in `currentConfig`, because the properties are lazy. Replacing with a fresh object deletes this implicit cache.
        /// - TODO: Make a copy before storing in `_scrollConfigRaw` just to be sure the equality checks always work
        _scrollConfigRaw = newConfigRaw
        _shared = ScrollConfig(raw: newConfigRaw)
        cache.removeAll(keepingCapacity: false)
        stateGeneration &+= 1
        let newShared = _shared
        stateLock.unlock()
//        ReactiveScrollConfig.shared.handleScrollConfigChanged(newValue: shared)
        SwitchMaster.shared.scrollConfigChanged(scrollConfig: newShared)
        /// Cached config instances are intentionally immutable snapshots. End any animation that still owns the
        /// previous snapshot so the next physical report opens with the new direction, curve, and modifier policy.
        DDLogInfo("MFSCROLL_CONFIG: action=reload-reset")
        Scroll.resetState()
    }
    @objc static func devToggles_deleteCache() { /// [May 2025] Added this function as a hack for DevToggles.m
        stateLock.lock()
        _shared = ScrollConfig(raw: _scrollConfigRaw)
        cache.removeAll(keepingCapacity: false)
        stateGeneration &+= 1
        stateLock.unlock()
        DDLogInfo("MFSCROLL_CONFIG: action=dev-cache-reset")
        Scroll.resetState()
    }
    
    // MARK: Overrides
    
    @objc static func scrollConfig(modifiers: MFScrollModificationResult, inputAxis: MFAxis, display: CGDirectDisplayID) -> ScrollConfig {
        
        let key = _HT(a: modifiers, b: inputAxis, c: display)

        stateLock.lock()
        if let fromCache = cache[key] {
            stateLock.unlock()
            return fromCache
        }
        let baseConfig = _shared
        let generation = stateGeneration
        stateLock.unlock()
            
            /// Cache retrieval failed -> Recalculate result
            
            /// Copy og settings
            /// Construct from the same immutable raw snapshot. The old generic
            /// runtime shallow-copy helper instantiates with `init()` and skips
            /// read-only properties, so it cannot preserve `scrollConfigRaw`.
            let new = ScrollConfig(raw: baseConfig.scrollConfigRaw)
            
            /// Declare overridables
            var u_speed = new.u_speed
            var useQuickMod = modifiers.inputMod == kMFScrollInputModificationQuick
            var usePreciseMod = modifiers.inputMod == kMFScrollInputModificationPrecise
            var scaleToDisplay = true
            var animationCurveOverride: MFScrollAnimationCurveName? = nil
            
            ///
            /// Override settings
            ///
            
            /// 1. effectModifications
            if modifiers.effectMod == kMFScrollEffectModificationHorizontalScroll {
                
                
            } else if modifiers.effectMod == kMFScrollEffectModificationZoom {
                
                /// Override animation curve
                animationCurveOverride = kMFScrollAnimationCurveNameTouchDriver
                
                /// Adjust speed params
                scaleToDisplay = false
                
            } else if modifiers.effectMod == kMFScrollEffectModificationRotate {
                
                /// Override animation curve
                animationCurveOverride = kMFScrollAnimationCurveNameTouchDriver
                
                /// Adjust speed params
                scaleToDisplay = false
                
            } else if modifiers.effectMod == kMFScrollEffectModificationCommandTab {
                
                /// Disable animation
                animationCurveOverride = kMFScrollAnimationCurveNameNone
                
            } else if modifiers.effectMod == kMFScrollEffectModificationThreeFingerSwipeHorizontal {
                
                /// Override animation curve
                animationCurveOverride = kMFScrollAnimationCurveNameTouchDriverLinear;
                
                /// Adjust speed params
                if u_speed == kMFScrollSpeedSystem {
                    u_speed = kMFScrollSpeedMedium
                }
                scaleToDisplay = false
                
                /// Turn off inputMods
                useQuickMod = false
                usePreciseMod = false
                
                /// Disable speedup
                new.fastScrollCurve = nil
                
            } else if modifiers.effectMod == kMFScrollEffectModificationFourFingerPinch {
                
                /// Override animation curve
                animationCurveOverride = kMFScrollAnimationCurveNameTouchDriverLinear;
                
                /// Adjust speed params
                if u_speed == kMFScrollSpeedSystem {
                    u_speed = kMFScrollSpeedMedium
                }
                scaleToDisplay = false
                
                /// Turn off inputMods
                useQuickMod = false
                usePreciseMod = false
                
                /// Disable speedup
                new.fastScrollCurve = nil
                
            } else if modifiers.effectMod == kMFScrollEffectModificationNone {
            } else if modifiers.effectMod == kMFScrollEffectModificationAddModeFeedback {
                /// We don't wanna scroll at all in this case but I don't think it makes a difference.
            } else {
                assert(false);
            }
            
            /// 2. inputModifications
            
            if useQuickMod {
                
                /// Set animationCurve
                /// - Only do this if the effectMods haven't set their own curve already. That way effectMod animationCurves override quickMod animationCurve. We want this because the quickMod curve can be super long and inertial which feels really bad if you're e.g. trying to zoom.
                /// - Idea: If we only send the effects while the animationCurve is in the gesturePhase we might not need this? But the gesture phase curve is just linear which would feel non-so-smooth.
                /// - Should we also do this for preciseMod? If we use the linear touchDriver curve and then override it with the eased-out preciseMod curve that might not be what we want. But I think wherever we use the linear touchDriver curve we ignore preciseMod and QuickMod anyways
                
                if animationCurveOverride == nil {
                    animationCurveOverride = kMFScrollAnimationCurveNameQuickScroll
                }
                
                /// Adjust speed params
                scaleToDisplay = false /// Is scaled to windowSize instead
                
                /// Make fastScroll easier to trigger
                new.consecutiveScrollSwipeMaxInterval = 725.0/1000.0
                new.consecutiveScrollTickIntervalMax = 200.0/1000.0
                new.consecutiveScrollSwipeMinTickSpeed = 12.0
                
                /// Amp-up fastScroll
                new.fastScrollCurve = ScrollSpeedupCurve(swipeThreshold: 1, initialSpeedup: 2.0, exponentialSpeedup: 10)
                
            } else if usePreciseMod {
                
                /// Set animationCurve
                /// The idea is that:
                /// - inputMods may only override effectMod animationCurve overrides, if that shortens the animation. Because you don't want long animations during scroll-to-zoom, scroll-to-reveal-desktop, etc.
                /// - The precise input mod should never turn on smoothScrolling.
                if (animationCurveOverride == nil && new.animationCurve != kMFScrollAnimationCurveNameNone)
                    || (animationCurveOverride != nil && animationCurveOverride != kMFScrollAnimationCurveNameNone) {
                    
                    animationCurveOverride = kMFScrollAnimationCurveNamePreciseScroll
                }
                
                /// Adjust speed params
                scaleToDisplay = false
                
                /// Turn off fast scroll
                new.fastScrollCurve = nil
            }
            
            /// Apply animationCurve override
            if let ovr = animationCurveOverride {
                new.animationCurve = ovr
            }
            
            /// Preserve the old speed and modifier meanings inside the true-velocity
            /// model. Do not revive the rejected events/second acceleration curve.
            new.useAppleAcceleration =
                u_speed == kMFScrollSpeedSystem && !usePreciseMod && !useQuickMod

            let speedMultiplier: Double
            switch u_speed {
            case kMFScrollSpeedLow:
                speedMultiplier = 0.65
            case kMFScrollSpeedMedium, kMFScrollSpeedSystem:
                speedMultiplier = 1.0
            case kMFScrollSpeedHigh:
                speedMultiplier = 1.5
            default:
                assertionFailure("Unknown scroll speed")
                speedMultiplier = 1.0
            }

            if useQuickMod {
                let outputIsHorizontal = inputAxis == kMFAxisHorizontal
                    || modifiers.effectMod == kMFScrollEffectModificationHorizontalScroll
                let displayPixels = outputIsHorizontal
                    ? Double(CGDisplayPixelsWide(display))
                    : Double(CGDisplayPixelsHigh(display))
                new.velocityModelDistanceMultiplier =
                    max(1.0, displayPixels * 0.5 / max(new.pxAtRefSpeed, 1.0))
            } else if usePreciseMod {
                new.velocityModelDistanceMultiplier = 0.15
            } else {
                var displayMultiplier = 1.0
                if scaleToDisplay {
                    let outputIsHorizontal = inputAxis == kMFAxisHorizontal
                        || modifiers.effectMod == kMFScrollEffectModificationHorizontalScroll
                    let displayPixels = outputIsHorizontal
                        ? Double(CGDisplayPixelsWide(display))
                        : Double(CGDisplayPixelsHigh(display))
                    let referencePixels = outputIsHorizontal ? 1920.0 : 1080.0
                    displayMultiplier = SharedUtilitySwift.clip(
                        0.9 + 0.1 * (displayPixels / referencePixels),
                        betweenLow: 0.75,
                        high: 1.5)
                }
                new.velocityModelDistanceMultiplier = speedMultiplier * displayMultiplier
            }
            
            /// Cache & return
            stateLock.lock()
            if generation != stateGeneration {
                /// A reload won while this snapshot was being derived. Retry against
                /// the new generation so an obsolete instance is never published.
                stateLock.unlock()
                return scrollConfig(modifiers: modifiers, inputAxis: inputAxis, display: display)
            }
            if let concurrentlyBuilt = cache[key] {
                stateLock.unlock()
                return concurrentlyBuilt
            }
            cache[key] = new
            stateLock.unlock()
            return new
    }
    
    // MARK: ???
    
    @objc static var linearCurve: Bezier = { () -> Bezier in
        
        let controlPoints: [P] = [_P(0,0), _P(0,0), _P(1,1), _P(1,1)]
        
        return Bezier(controlPoints: controlPoints, defaultEpsilon: 0.001) /// The default defaultEpsilon 0.08 makes the animations choppy
    }()
    
//    @objc static var stringToEventFlagMask: NSDictionary = ["command" : CGEventFlags.maskCommand,
//                                                            "control" : CGEventFlags.maskControl,
//                                                            "option" : CGEventFlags.maskAlternate,
//                                                            "shift" : CGEventFlags.maskShift]
    
    // MARK: Derived
    /// For convenience I guess? Should probably remove these
    
    
    @objc var smoothEnabled: Bool {
        /// Does this really have to exist?
        return _animationCurveName != kMFScrollAnimationCurveNameNone
    }
    @objc var useAppleAcceleration: Bool = false
    // MARK: Invert Direction
    
    @objc lazy var u_invertDirection: MFScrollInversion = {
        /// This can be used as a factor to invert things. kMFScrollInversionInverted is -1.

//        if HelperState.shared.isLockedDown { return kMFScrollInversionNonInverted }
        return c("reverseDirection") as! Bool ? kMFScrollInversionInverted : kMFScrollInversionNonInverted
    }()

    // MARK: Tuning sliders (fork)

    /// Raw tuning values. The UI's default ranges remain approachable, but expert users can expand each slider to
    /// the broader supported range. Absent -> the documented default, for the same reason as `u_invertZoom` below:
    /// `_loadAndRepair` is a configVersion migration, not a key-merger, and the Helper doesn't repair at all.

    private func tuningValue(_ key: String,
                             fallback: Double,
                             supportedMinimum: Double,
                             supportedMaximum: Double) -> Double {
        let v = (c("tuning.\(key)") as? NSNumber)?.doubleValue ?? fallback
        guard v.isFinite else { return fallback }
        return SharedUtilitySwift.clip(v, betweenLow: supportedMinimum, high: supportedMaximum)
    }

    /// Fallbacks must match `default_config.plist > Scroll.tuning`. They aren't dead code: `_loadAndRepair` is a
    /// configVersion migration, not a key-merger, so a config written before these keys existed simply won't have
    /// them — and the Helper never repairs at all. These values are what actually runs in that case.
    ///
    /// [Jul 16 2026] Tuned by hand on the TB800 and adopted as the defaults. The shape is: a very low base
    /// sensitivity so slow scrolling moves in small steps rather than lurching, with strong but bounded acceleration
    /// to get distance back on a fast spin. Burst-history-based fastScroll stays off by default because it makes
    /// identical physical input behave differently depending on how reports happen to be grouped.
    @objc lazy var u_sensitivity: Double = {
        tuningValue("sensitivity", fallback: 0.10, supportedMinimum: 0.0, supportedMaximum: 10.0)
    }()
    @objc lazy var u_acceleration: Double = {
        tuningValue("acceleration", fallback: 1.0, supportedMinimum: 0.0, supportedMaximum: 5.0)
    }()
    @objc lazy var u_smoothnessAmount: Double = {
        tuningValue("smoothness", fallback: 0.5, supportedMinimum: 0.0, supportedMaximum: 10.0)
    }()
    @objc lazy var u_slowSmoothnessAmount: Double = {
        tuningValue("slowSmoothness", fallback: 0.90, supportedMinimum: 0.0, supportedMaximum: 10.0)
    }()
    @objc lazy var u_adaptiveSmoothnessEndSpeedRatio: Double = {
        tuningValue("adaptiveSmoothnessEndSpeedRatio", fallback: 0.125,
                    supportedMinimum: 0.001, supportedMaximum: 10.0)
    }()
    @objc lazy var u_maxSpeed: Double = {
        tuningValue("maxSpeed", fallback: 0.5, supportedMinimum: 0.1, supportedMaximum: 10.0)
    }()
    @objc lazy var u_fastScrollAmount: Double = {
        tuningValue("fastScroll", fallback: 0.0, supportedMinimum: 0.0, supportedMaximum: 1.0)
    }()
    @objc lazy var u_glide: Double = {
        tuningValue("glide", fallback: 0.75, supportedMinimum: 0.0, supportedMaximum: 1.1)
    }()

    /// How long the scroll keeps gliding after your finger leaves the ring.
    ///     The legacy animator hands off from the base curve to a drag curve, which models
    ///     `v'(t) = -a*v(t)^b` (DragCurve.swift). `dragExponent` (b) is 1.0 for the scrolling curves, so that's plain
    ///     exponential decay: `v(t) = v0 * e^(-a*t)`, with a time constant of exactly `1/dragCoefficient` seconds.
    ///     0.5 == 22.5 ~= upstream. Higher = less friction = longer glide (a=5 -> a 200ms time constant).
    @objc lazy var dragCoefficientForGlide: Double = { 40.0 - (u_glide * 35.0) }() /// 40 (abrupt) ... 1.5 (floaty)

    /// Derived engine parameters
    ///     The model (see Scroll.m):  pxPerUnit(v) = pxAtRefSpeed * (v/refSpeed)^(gamma - 1),  px = pxPerUnit * units
    ///     ...so that  px/s = pxAtRefSpeed * refSpeed * (v/refSpeed)^gamma, where v is true velocity in units/s.
    ///
    ///     gamma is the knob that decides "is fast scrolling too fast":
    ///       gamma = 1.0 -> output exactly proportional to input velocity (perfectly linear).
    ///       gamma < 1.0 -> compresses the input's ~110x velocity range into less output range. This is roughly
    ///                      what upstream's rate-only curve did by accident.
    ///       gamma > 1.0 -> genuine acceleration; fast spins gain disproportionately.
    ///
    ///     Why anchor at `refSpeed` instead of at v = 1:
    ///       It makes the two sliders orthogonal. pxPerUnit == pxAtRefSpeed at v == refSpeed for *any* gamma, so
    ///       Sensitivity sets the overall scale and Acceleration only tilts the curve around that pivot. Anchoring
    ///       at v = 1 instead means changing Acceleration also changes how fast slow scrolling is, which makes the
    ///       sliders fight each other and the whole thing untunable.

    /// Measured on the TB800: slow steady ~5 units/s, hard spin ~562 units/s. The geometric mean (~53) is the
    /// natural pivot — it's the middle of the actual usable range rather than an arbitrary constant.
    @objc let refSpeed: Double = 50.0

    @objc lazy var pxAtRefSpeed: Double = { 10.0 + (u_sensitivity * 140.0) }()   /// 10...1410
    @objc lazy var gamma: Double = { 0.4 + (u_acceleration * 0.8) }()            /// 0.4...4.4
    /// Explicit scale for the retained Low/Medium/High, Precise, Quick, and
    /// display-size semantics. Applied once, after the true-velocity curve.
    @objc var velocityModelDistanceMultiplier: Double = 1.0

    /// Stable-engine overload control.
    ///
    /// A per-report pixel cap is inherently hardware-dependent: the same cap permits twice the output speed when
    /// reports arrive twice as often. Express the ceiling as pixels/second instead.
    ///
    /// The default UI range is 0.1...1.0 and maps that to 3x...30x the reference output speed. Expert custom ranges
    /// can extend this as far as 10.0. The accepted hardware-tested
    /// baseline is 0.5 == 15x, about 18,000 px/s at the measured default sensitivity. Initial response and retained
    /// distance are capped separately below, so a high sustained maximum does not recreate the old latency queue.
    @objc lazy var stableMaximumOutputSpeed: Double = {
        pxAtRefSpeed * refSpeed * (30.0 * max(0.1, u_maxSpeed))
    }()

    /// Sparse, very slow ring reports need more temporal blending than fast reports. `u_smoothnessAmount` remains
    /// the normal/fast value; below `u_adaptiveSmoothnessEndSpeedRatio` of Maximum Speed, effective smoothness eases
    /// from `u_slowSmoothnessAmount` back to that value. A smoothstep transition avoids a perceptible boundary, and
    /// the slow value never reduces a higher normal value. Both thresholds are exposed in the Scrolling tab.

    /// A new gesture has no cadence measurement, so its first report is deliberately small and cannot yet reveal
    /// whether the ring is accelerating. Keep that report visibly responsive instead of spreading its typical 20px
    /// across the normal ~160ms base curve.
    @objc let stableInitialResponseBaseDurationMax: TimeInterval = 80.0 / 1000.0

    /// Current TB800 captures show a distinct response-shape regression after long wheel idle: the first output is
    /// delivered within one display frame, but the next few hardware reports can remain at one unit long enough for
    /// maximum Slow Smoothness to make the physical wake-up ramp feel stuck. Starts after 4–5 seconds do not show
    /// the reported problem. Arm only after the observed 20-second boundary. Hold the existing opening-duration cap
    /// through the measured 750ms hardware-ramp interval, then continuously fade it away over the following 750ms.
    /// Silence before report two must not consume most of the protection. No input is delayed, and larger/faster
    /// input exits on that report.
    @objc let stableIdleWakeMinimumIdle: TimeInterval = 20.0
    @objc let stableIdleWakeResponseHoldDuration: TimeInterval = 750.0 / 1000.0
    @objc let stableIdleWakeResponseFadeDuration: TimeInterval = 750.0 / 1000.0

    /// Keep enough cadence history to recognize extremely slow same-direction trackball movement even when its
    /// reports cross the 500ms gesture-grouping timeout. Acceleration, clicks, and target changes clear this memory
    /// immediately; a slow reversal can retain its scalar cadence only through the shorter reversal taper below.
    @objc let stableSlowCadenceMemoryMaxInterval: TimeInterval = 1.5
    @objc let stableSlowCadenceEstimateAlpha: Double = 0.5

    /// The HybridCurve's drag portion extends beyond its base duration, so target 75% of the observed cadence here.
    /// The cap limits the tail after a single very sparse report; incoming input always replans it immediately.
    @objc let stableSlowCadenceBaseDurationRatio: Double = 0.75
    @objc let stableSlowCadenceBaseDurationMax: TimeInterval = 900.0 / 1000.0

    /// The three-report tick-time average intentionally smooths steady motion and deceleration, but it must not keep
    /// animation duration slow after the velocity model has already detected acceleration. Use the current raw
    /// interval only when it is materially shorter than the average; smaller timing jitter keeps the smoother.
    @objc let stableAccelerationCadenceRawIntervalRatioMax: Double = 0.75

    /// A very close slow reversal is usually part of careful continuous movement, so preserve its cadence in full.
    /// Past this point, fade cadence influence to zero at `consecutiveScrollTickIntervalMax`: a later reversal is a
    /// fresh deliberate input and must not turn its first ~20px into a long sparse-cadence glide. Same-direction
    /// sparse input keeps the existing full-cadence range through that boundary.
    @objc let stableSlowCadenceReversalFullBlendMaxInterval: TimeInterval = 200.0 / 1000.0

    /// Keep the first report bounded even though the sustained speed ceiling is intentionally high. The first report
    /// has no measured duration, so applying the full pixels/second ceiling to an assumed interval would create a
    /// large initial lurch.
    @objc lazy var stableMaximumInitialDistance: Double = {
        pxAtRefSpeed * 15.0
    }()

    /// Retained distance is a latency budget, not a speed budget. Keep this near the previous pass's ~630px even
    /// when stableMaximumOutputSpeed changes. New input still takes effect immediately; only distance that would
    /// otherwise remain in a growing queue is discarded.
    @objc lazy var stableMaximumCarryDistance: Double = {
        pxAtRefSpeed * refSpeed * 0.525
    }()

    /// Long glide is pleasant at reading speed, but the same low friction produces a large drift tail after a hard
    /// spin. At the speed ceiling, raise friction to at least this value. The user's Glide setting still wins when
    /// it requests even stronger friction.
    @objc let stableFastDragCoefficient: Double = 32.0

    /// Mark that a gesture reached the fast range so a late mechanical settling report can receive the narrow
    /// one-report tail treatment below. This does not change the phase of continuous wheel output.
    @objc lazy var stableFastGestureSpeed: Double = {
        pxAtRefSpeed * refSpeed * 1.5
    }()

    /// A free-spinning ring can emit one last low-velocity report well after a fast gesture has visually stopped.
    /// Do not discard it: a resumed scroll is indistinguishable at arrival time. Instead, make that one report small
    /// and brief so mechanical settling cannot look like a second gesture while a real resume remains responsive.
    @objc let stableFastTailInputGapMin: TimeInterval = 120.0 / 1000.0
    @objc let stableFastTailRawVelocityMax: Double = 10.0
    @objc let stableFastTailAnimatorSpeedMax: Double = 1000.0
    /// Tail protection fades continuously as existing output motion rises. By this speed the report is part of an
    /// active deceleration and receives full distance plus normal adaptive smoothing.
    @objc let stableFastTailContinuitySpeed: Double = 400.0
    @objc let stableFastTailDistanceScale: Double = 0.25
    @objc let stableFastTailDurationScale: Double = 0.55

    /// After a fast free-spin, the hardware can emit one final one-unit report after the visible motion is already
    /// settling. Captures place that mechanical rebound within 150–320 ms of the last fast input; a later report
    /// is a resumed physical scroll and must take the normal first-report path. Same-direction reports leave a
    /// live glide alone.
    /// When no useful glide exists, emit a short, bounded micro-glide: large enough that a deliberate first report is
    /// visible, but much smaller than the normal accelerated tick so mechanical settling cannot become a second
    /// gesture. A new report cancels/retargets this animator immediately.
    @objc let stableSettlingTailWindowMax: TimeInterval = 320.0 / 1000.0
    @objc let stableSettlingTailPointDeltaMax: Int64 = 1
    @objc let stableSettlingTailResponsiveDistanceMax: Int64 = 10
    @objc let stableSettlingTailResponsiveDistanceMin: Int64 = 4
    @objc let stableSettlingTailResponsiveDuration: TimeInterval = 50.0 / 1000.0

    // MARK: Invert ball scrolling (fork)

    @objc lazy var u_invertBallScroll: Bool = {
        /// Inverts the direction the ball scrolls while Scroll & Zoom Mode is latched.
        ///     Default off == upstream's `TwoFingerSwipe` behaviour, where the content follows the ball like a
        ///     trackpad (`twoFingerScale = 1.0`, see ModifiedDragOutputTwoFingerSwipe.m). On == the content moves
        ///     the opposite way, like dragging a scrollbar.
        ///
        ///     Independent of `u_invertDirection` (which is the scroll *ring*) — they're different physical inputs
        ///     and there's no reason one implies the other.
        ///
        ///     `as?` + fallback, not `as!`: see u_invertZoom below for why every new key in this fork must be read
        ///     nil-tolerantly.
        return (c("invertBallScroll") as? Bool) ?? false
    }()

    // MARK: Invert Zoom

    @objc lazy var u_invertZoom: Bool = {
        /// Inverts zoom independently of `u_invertDirection`.
        ///     Context: zoom's direction is derived from `scrollDirection`, which already has `u_invertDirection`
        ///     applied — so without this the two cannot be set independently.
        ///
        /// Why `as?` + fallback instead of `as! Bool` like the settings around it:
        ///     This key is additive, so configs written before it exists simply don't have it. Nothing backfills it:
        ///     `_loadAndRepair` (Config.m:439) is a configVersion *migration*, not a key-merger — when the versions
        ///     match (both 24) it takes the `dontReplace` path and adds no keys. And the Helper doesn't repair at
        ///     all (`loadConfigFromFile` only calls `_loadAndRepair` `#if IS_MAIN_APP`), it reads the plist raw.
        ///     So `as! Bool` here would crash the Helper against any pre-existing config. Absent == off; the key
        ///     appears in the user's config as soon as the toggle is flipped, and in default_config for fresh ones.
        return (c("invertZoom") as? Bool) ?? false
    }()
    
    // MARK: Old Invert Direction
    /// Rationale: We used to have the user setting be "Natural Direction" but we changed it to being "Reverse Direction". This is so it's more transparent to the user when Mac Mouse Fix is intercepting the scroll input and also to have the SwitchMaster more easily decide when to turn the scrolling tap on or off. Also I think the setting is slightly more intuitive this way.
    
//    @objc func scrollInvert(event: CGEvent) -> MFScrollInversion {
//        /// This can be used as a factor to invert things. kMFScrollInversionInverted is -1.
//
//        if HelperState.shared.isLockedDown { return kMFScrollInversionNonInverted }
//
//        if self.u_direction == self.semanticScrollInvertSystem(event) {
//            return kMFScrollInversionNonInverted
//        } else {
//            return kMFScrollInversionInverted
//        }
//    }
    
//    lazy private var u_direction: MFSemanticScrollInversion = {
//        c("naturalDirection") as! Bool ? kMFSemanticScrollInversionNatural : kMFSemanticScrollInversionNormal
//    }()
//    private func semanticScrollInvertSystem(_ event: CGEvent) -> MFSemanticScrollInversion {
//
//        /// Accessing userDefaults is actually surprisingly slow, so we're using NSEvent.isDirectionInvertedFromDevice instead... but NSEvent(cgEvent:) is slow as well...
//        ///     .... So we're using our advanced knowledge of CGEventFields!!!
//
////            let isNatural = UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection") /// User defaults method
////            let isNatural = NSEvent(cgEvent: event)!.isDirectionInvertedFromDevice /// NSEvent method
//        let isNatural = event.getIntegerValueField(CGEventField(rawValue: 137)!) != 0; /// CGEvent method
//
//        return isNatural ? kMFSemanticScrollInversionNatural : kMFSemanticScrollInversionNormal
//    }
    
    // MARK: Inverted from device flag
    /// Notes:
    /// - This flag will be set on GestureScroll events, as well as DockSwipe, and maybe other events and and will invert some interactions like scrolling to delete messages in Mail
    /// - Why did we decide to always have this off? My guess is that invertedFromDevice is meant to preserve physical relationship between fingers and UI for interactions like delete messages in Mail, but since this physical relationship doesn't exist on the scrollwheel, it makes sense to just set this to a constant value independent of scroll inversion. However, it might be better to always turn *on* invertedFromDevice, instead of keeping it turned *off*, since that's the default setting in macOS, and turning it off leads to bugs when sending pinch type Dock swipes to open Launchpad. We implemented a workaround for this bug, but still should be better to always turn this on. 
    ///     - Edit: Always turning inverted from device **on** now. Seems to work fine so far. It makes the direction of unread-swipes in Mail make more sense.
    
    @objc let invertedFromDevice = true;
    
    // MARK: Analysis
    
    @objc lazy var scrollSwipeThreshold_inTicks: Int = 2 /*other["scrollSwipeThreshold_inTicks"] as! Int;*/ /// If `scrollSwipeThreshold_inTicks` consecutive ticks occur, they are deemed a scroll-swipe.
    
    @objc lazy var scrollSwipeMax_inTicks: Int = 11 /// Max number of ticks that we think can occur in a single swipe naturally (if the user isn't using a free-spinning scrollwheel). (See `consecutiveScrollSwipeCounter_ForFreeScrollWheel` definition for more info)
    
    /// Fork: how sparse a tick stream still counts as ONE continuous scroll.
    ///
    /// Measured [Jul 15 2026], 36 ticks of deliberate slow scrolling on the TB800:
    ///     gaps ran 99...1127ms with a **260ms median**, and 34/35 exceeded upstream's 160ms. So *every* tick of a
    ///     slow scroll was classified as a separate, isolated scroll. Consequences, all bad:
    ///       - `timeBetweenTicks` is discarded and replaced by the max, so all 36 ticks reported the same velocity
    ///         (6.25 u/s) and the same distance (86px). The ring's actual speed was thrown away entirely and the
    ///         acceleration curve had nothing to act on.
    ///       - `consecutiveScrollTickCounter` stays 0, so Scroll.m:715 treats every tick as a swipe-sequence start
    ///         and zeroes `pxLeftToScroll` — hard-resetting the animator and discarding in-flight motion each time.
    ///     Net effect: constant 86px lurches at irregular intervals -> an instantaneous rate swinging 76...859 px/s.
    ///     That is the "slow scroll stutters".
    ///
    /// 160ms is right for a *notched wheel*, where a 160ms silence really does mean you stopped. A free-spinning
    /// ring at reading speed simply emits ticks further apart than that. 500ms covers the measured median (260ms)
    /// with headroom, while the >500ms gaps in that capture (507/509/782/878/1127ms) still read as genuine new
    /// scrolls.
    ///
    /// Note this is deliberately NOT the anchor for the animation-duration curve any more — see `animationTickStart`.
    @objc lazy var trackballSlowScrollWindow: TimeInterval = 500.0/1000.0

    @objc lazy var consecutiveScrollTickIntervalMax: TimeInterval = SharedUtilitySwift.eval {

        switch animationCurve {
        case kMFScrollAnimationCurveNameNone:            trackballSlowScrollWindow
        case kMFScrollAnimationCurveNameVeryLowInertia:  trackballSlowScrollWindow
        case kMFScrollAnimationCurveNameLowInertia:      trackballSlowScrollWindow
        case kMFScrollAnimationCurveNameHighInertia, kMFScrollAnimationCurveNameHighInertiaPlusTrackpadSim: trackballSlowScrollWindow
        /// Leave the effect/input-modification curves alone — they're for zoom, rotate, precise & quick scroll, which
        /// upstream tuned deliberately and which aren't what this fork is fixing.
        case kMFScrollAnimationCurveNameTouchDriver, kMFScrollAnimationCurveNameTouchDriverLinear:          160.0/1000
        case kMFScrollAnimationCurveNamePreciseScroll, kMFScrollAnimationCurveNameQuickScroll:              160.0/1000
        default: { assert(false); return -1.0 }()
        }
    }
    /// ^ Notes:
    ///     If more than `_consecutiveScrollTickIntervalMax` seconds passes between two scrollwheel ticks, then they aren't deemed consecutive.
    ///        other["consecutiveScrollTickIntervalMax"] as! Double;
    ///     msPerStep/1000 <- Good idea but we don't want this to depend on msPerStep
    
    @objc lazy var consecutiveScrollTickIntervalMin: TimeInterval = 1/1000
    /// ^ Notes:
    ///     - This variable is used to cap the observed scrollTickInterval to a reasonable value. We also use it for Math.scale() ing the timeBetweenTicks into a value between 0 and 1. But I'm not sure this is better than just using 0 instead of `consecutiveScrollTickIntervalMin`.
    ///     - 15ms seemst to be smallest scrollTickInterval that you can naturally produce. But when performance drops, the scrollTickIntervals that we see can be much smaller sometimes.
    ///     - Update: This is not true for my Roccat Mouse connected via USB. The tick times go down to around 5ms on that mouse. I can reproduce the 15ms minimum using my Logitech M720 connected via Bluetooth. I guess it depends on the mouse hardware or on the transport (bluetooth vs USB).
    ///         - Action: We're lowering the `consecutiveScrollTickIntervalMax` from 15 -> 1. Primarily to be able to implement the `baseMsPerStepCurve` algorithm better, but also because our assumption that the lowest possible value is 15 is not true for all mice.
    ///         **HACK**: We need to keep the  the `consecutiveScrollTickInterval_AccelerationEnd` at 15ms for now, because lowering that to 5ms would change the behaviour or the acceleration algorithm and make scrolling slower, and we don't have time to adjust the acceleration curves right now.

    /// Fork: the anchor for the animation-duration curve (Scroll.m:768).
    ///     This used to *be* `consecutiveScrollTickIntervalMax`. They were the same 160ms number but answer different
    ///     questions — "how long an animation does a tick this slow deserve" vs "is this still the same scroll" — and
    ///     we've raised the latter to `trackballSlowScrollWindow`. Keeping this at 160ms preserves upstream's tuned
    ///     mapping: a tick at or beyond 160ms samples the curve at 0 and gets the full-length animation.
    @objc lazy var animationTickStart: TimeInterval = 160.0/1000.0

    /// Keep gesture/momentum phase classification independent from input grouping.
    ///     The trackball continuity window is intentionally 500ms, but that does not mean the first 500ms of every
    ///     animation should be forced into the gesture phase. A real direct-manipulation gesture transitions based
    ///     on the animation itself, not on the timeout used to decide whether two hardware reports belong together.
    static let gesturePhaseMinDuration: TimeInterval = 160.0/1000.0

    /// Velocity estimator parameters.
    ///
    /// The estimator is time-based instead of averaging a fixed number of reports. A three-report window represents
    /// hundreds of milliseconds during careful scrolling but only a few dozen milliseconds during a fast spin,
    /// which makes its latency depend on the user's speed. These constants keep the response time stable across
    /// report rates.
    ///
    /// The first report has no measured interval. Treat it as an explicit isolated movement rather than pretending
    /// it arrived after the full 500ms continuity timeout.
    @objc let isolatedTickVelocityInterval: TimeInterval = 200.0/1000.0
    /// Keep velocity measurement independent from the legacy acceleration curve's 15ms extrapolation boundary.
    /// A 750Hz HID poll is 1.33ms; the CGEvent rate is usually much lower, but using a 1ms floor means the estimator
    /// remains correct if macOS does deliver high-rate scroll reports. The final pixel cap still guards bad timestamps.
    @objc let velocityMeasurementIntervalMin: TimeInterval = 1.0/1000.0
    /// Keep acceleration and deceleration similarly responsive. The earlier 20ms attack / 40ms release pair made
    /// output speed continue drifting after the ring had already slowed. Smoothness can still add a small amount of
    /// filtering, but it no longer doubles the release latency.
    @objc lazy var velocityFilterAttackTimeConstant: TimeInterval = {
        (8.0 + (u_smoothnessAmount * 16.0)) / 1000.0
    }() /// 8...24ms; default 16ms
    @objc lazy var velocityFilterReleaseTimeConstant: TimeInterval = {
        (10.0 + (u_smoothnessAmount * 20.0)) / 1000.0
    }() /// 10...30ms; default 20ms

    @objc lazy var consecutiveScrollSwipeMaxInterval: TimeInterval = {
        /// If more than `_consecutiveScrollSwipeIntervalMax` seconds passes between two scrollwheel swipes, then they aren't deemed consecutive.
        
        let result: Double = SharedUtilitySwift.eval {
            
            switch animationCurve {
            case kMFScrollAnimationCurveNameNone:            325.0
            case kMFScrollAnimationCurveNameVeryLowInertia:  375.0 /// Haven't considered this. (Only matters for fastScroll I think, which we've turned off for VeryLow) [Jun 2025]
            case kMFScrollAnimationCurveNameLowInertia:      375.0
            case kMFScrollAnimationCurveNameHighInertia, kMFScrollAnimationCurveNameHighInertiaPlusTrackpadSim: 600.0
            case kMFScrollAnimationCurveNameTouchDriver, kMFScrollAnimationCurveNameTouchDriverLinear:          375.0
            case kMFScrollAnimationCurveNamePreciseScroll, kMFScrollAnimationCurveNameQuickScroll:              0.1234 /// Will be overriden
            default: -1.0
            }
        }
        assert(result != -1.0)
        return result/1000.0
    }()
    
    @objc lazy var consecutiveScrollSwipeMinTickSpeed: Double = {
        /// The ticks per second need to be at least `consecutiveScrollSwipeMinTickSpeed` to register a series of scrollswipes as consecutive
        
        let result: Double = SharedUtilitySwift.eval {
            switch animationCurve {
            case kMFScrollAnimationCurveNameNone:           16.0
            case kMFScrollAnimationCurveNameVeryLowInertia: 16.0 /// Haven't considered this [Jun 2025]
            case kMFScrollAnimationCurveNameLowInertia:     16.0
            case kMFScrollAnimationCurveNameHighInertia, kMFScrollAnimationCurveNameHighInertiaPlusTrackpadSim: 12.0
            case kMFScrollAnimationCurveNameTouchDriver, kMFScrollAnimationCurveNameTouchDriverLinear:          16.0
            case kMFScrollAnimationCurveNamePreciseScroll, kMFScrollAnimationCurveNameQuickScroll:              0.1234 /// Will be overriden
            default: -1.0
            }
        }
        assert(result != -1.0)
        return result
    }()
    
    @objc lazy var consecutiveScrollTickInterval_AccelerationEnd: TimeInterval = 15/1000 //consecutiveScrollTickIntervalMin
    /// ^ Notes:
    ///     - Used to define accelerationCurve. If the time interval between two ticks becomes less than `consecutiveScrollTickInterval_AccelerationEnd` seconds, then the accelerationCurve becomes managed by linear extension of the bezier instead of the bezier directly.
    ///     - This should ideally be equal to `consecutiveScrollTickIntervalMin`. For an explanation why it's different at the moment, see the notes on consecutiveScrollTickIntervalMin
    
    /// Note: We are just using RollingAverge for smoothing, not ExponentialSmoothing, so this is currently unused.
    @objc lazy var ticksPerSecond_DoubleExponentialSmoothing_InputValueWeight: Double = 0.5
    @objc lazy var ticksPerSecond_DoubleExponentialSmoothing_TrendWeight: Double = 0.2
    @objc lazy var ticksPerSecond_ExponentialSmoothing_InputValueWeight: Double = 0.5
    /// ^  Notes:
    ///     1.0 -> Turns off smoothing. I like this the best
    ///     0.6 -> On larger swipes this counteracts acceleration and it's unsatisfying. Not sure if placebo
    ///     0.8 ->  Nice, light smoothing. Makes  scrolling slightly less direct. Not sure if placebo.
    ///     0.5 -> (Edit) I prefer smoother feel now in everything. 0.5 Makes short scroll swipes less accelerated which I like
    
    // MARK: Fast scroll
    
    
    @objc lazy var fastScrollCurve: ScrollSpeedupCurve? = {

        /// Fork: gate fastScroll on the tuning slider.
        ///     fastScroll multiplies pxToScrollForThisTick by an *exponentially* growing factor once you've made
        ///     `swipeThreshold` consecutive scroll swipes (Scroll.m:532-547, clamped only at x100000). It's built
        ///     for notched wheels, where consecutive swipes are deliberate and rare. A free-spinning ring produces
        ///     them constantly, so it compounds with the acceleration curve *and* the multi-unit deltas — measured
        ///     as a major contributor to the runaway fast-scroll. Default is 0 (off); Scroll.m treats nil as
        ///     "disabled", so returning nil here is the whole switch.
        if u_fastScrollAmount <= 0.0 { return nil }

        /// NOTES:
        /// - We're using swipeThreshold to configure how far the user must've scrolled before fastScroll starts kicking in.
        /// - It would probably be better to have an explicit mechanism that counts how many pixels the user has scrolled already and then lets fastScroll kick in after a threshold is reached. That would also scale with the scrollSpeed setting. These current `fastScrollSpeedup` values are chosen so you don't accidentally trigger it at the lowest scrollSpeed, but they could be higher at higher scrollspeeds.
        /// - Fastscroll starts kicking in on the `swipeThreshold + 1` th scrollSwipe
        /// - Edit: Why do we need speedup for kMFScrollAnimationCurveNameTouchDriver and kMFScrollAnimationCurveNameTouchDriverLinear?
        ///
        /// On how we chose parameters:
        /// - The `swipeThreshold` was chosen proportional to the max stepSize of the lowest scrollspeed setting of the respective animationCurve.
        /// - The `exponentialSpeedup` of the unanimated ScrollSpeedCurve is lower and the `initialSpeedup` is higher because without animation you quickly reach a speed where you can't tell how far or in which direction you scrolled. We want to have a few swipes in that window of speed where you can tell that it's speeding up but it's not yet so fast that you can't tell which direction you scrolled and how fast.
        
        
        /// Fork: the slider scales `exponentialSpeedup`, so 1.0 == upstream's behaviour and anything lower is a
        ///     gentler ramp. (0 already returned nil above.)
        let s = u_fastScrollAmount

        switch animationCurve {

        case kMFScrollAnimationCurveNameNone:           return ScrollSpeedupCurve(swipeThreshold: 6, initialSpeedup: 1.4,  exponentialSpeedup: 3.0 * s)
        case kMFScrollAnimationCurveNameVeryLowInertia: return ScrollSpeedupCurve(swipeThreshold: 1, initialSpeedup: 1,    exponentialSpeedup: 7.5 * s) /// Turn off fastScroll, since we want _maximum control_ and linear feeling for this setting.
        case kMFScrollAnimationCurveNameLowInertia:     return ScrollSpeedupCurve(swipeThreshold: 3, initialSpeedup: 1.33, exponentialSpeedup: 7.5 * s)

        case kMFScrollAnimationCurveNameHighInertia, kMFScrollAnimationCurveNameHighInertiaPlusTrackpadSim: return ScrollSpeedupCurve(swipeThreshold: 2, initialSpeedup: 1.33, exponentialSpeedup: 7.5 * s)
        case kMFScrollAnimationCurveNameTouchDriver, kMFScrollAnimationCurveNameTouchDriverLinear:          return ScrollSpeedupCurve(swipeThreshold: 3, initialSpeedup: 1.33, exponentialSpeedup: 7.5 * s)
        case kMFScrollAnimationCurveNamePreciseScroll, kMFScrollAnimationCurveNameQuickScroll:              return nil as ScrollSpeedupCurve? /// Will be overriden

        default:
            assert(false)
            return nil as ScrollSpeedupCurve?
        }
    }()
    
    // MARK: Animation curve
    
    /// User setting
    
    @objc lazy var u_smoothness: MFScrollSmoothness = {
        switch c("smooth") as! String {
        case "off":     return kMFScrollSmoothnessOff
        case "low":     return kMFScrollSmoothnessLow
        case "regular": return kMFScrollSmoothnessRegular
        case "high":    return kMFScrollSmoothnessHigh
        default: fatalError()
        }
    }()
    private lazy var u_trackpadSimulation: Bool = {
        return c("trackpadSimulation") as! Bool
    }()
    
    private lazy var _animationCurveName = {
        
        /// Maybe we should move the trackpad sim settings out of the MFScrollAnimationCurveName, (because that's weird?)
        
        switch u_smoothness {
        case kMFScrollSmoothnessOff:        return kMFScrollAnimationCurveNameNone
        case kMFScrollSmoothnessLow:        return kMFScrollAnimationCurveNameVeryLowInertia
        case kMFScrollSmoothnessRegular:    return kMFScrollAnimationCurveNameLowInertia
        case kMFScrollSmoothnessHigh:       return u_trackpadSimulation ? kMFScrollAnimationCurveNameHighInertiaPlusTrackpadSim : kMFScrollAnimationCurveNameHighInertia
        default: fatalError()
        }
    }()
    
    @objc var animationCurve: MFScrollAnimationCurveName {
        
        set {
            _animationCurveName = newValue
            self.animationCurveParams = tuned(animationCurveParamsMap(name: animationCurve))
        } get {
            return _animationCurveName
        }
    }

    @objc private(set) lazy var animationCurveParams: MFScrollAnimationCurveParameters? = { tuned(animationCurveParamsMap(name: animationCurve)) }() /// Updates automatically to match `self.animationCurveName

    /// Fork: apply the Smoothness slider to whichever animation curve was selected.
    ///     Overrides the step duration only; everything else is copied from what upstream chose.
    private func tuned(_ p: MFScrollAnimationCurveParameters?) -> MFScrollAnimationCurveParameters? {

        guard let p = p else { return nil }  /// kMFScrollAnimationCurveNameNone -> no animation

        /// Only tune the *plain scrolling* curves.
        ///     TouchDriver/TouchDriverLinear (zoom, rotate, four-finger-pinch, ...), PreciseScroll and QuickScroll
        ///     are effect/input-modification curves that upstream tuned deliberately for those gestures. The
        ///     Smoothness slider is about how plain scrolling feels; it has no business reshaping zoom.
        switch animationCurve {
        case kMFScrollAnimationCurveNameTouchDriver, kMFScrollAnimationCurveNameTouchDriverLinear,
             kMFScrollAnimationCurveNamePreciseScroll, kMFScrollAnimationCurveNameQuickScroll:
            return p
        default:
            break
        }

        /// SCALE the step duration; don't replace it. On the stable Regular path, Scroll.m applies a second relative
        /// adjustment whose very-slow endpoint and transition speed are controlled by `u_slowSmoothnessAmount` and
        /// `u_adaptiveSmoothnessEndSpeedRatio`.
        ///     `baseMsPerStepCurve` is speed-adaptive: Scroll.m:743 maps timeBetweenTicks onto 0...1 and samples it,
        ///     so the animation shortens (180 -> 110ms on LowInertia) as ticks arrive faster, letting the animator
        ///     keep up with fast scrolling. An earlier version of this pinned a single fixed duration and dropped
        ///     the curve, which flattened that adaptation and made fast scrolling animate over a long fixed step.
        ///     Keep the shape upstream tuned; just stretch or squash it.
        ///
        ///     0.5 (the default) == 1.0x == exactly upstream. 0 -> 0.4x (snappy), 1 -> 1.6x (smooth/laggy).
        let factor = 0.4 + (u_smoothnessAmount * 1.2)

        var scaledCurve: Curve? = nil
        var scaledMs: Int = -1
        if let c = p.baseMsPerStepCurve {
            scaledCurve = Curve(rawCurve: CurveTools.transformCurve({ x in c.evaluate(at: x) }, { y in y * factor }))
        } else {
            scaledMs = Int(Double(p.baseMsPerStep) * factor)
        }
        /// ^ The inits assert `(baseMsPerStep == -1) ^ (baseMsPerStepCurve == nil)` — exactly one may be set — so
        ///   whichever one `p` used, we keep using.

        /// Pick the initialiser that MATCHES how `p` was built.
        ///     `init(justBaseCurve:)` sets useDragCurve=false and fills dragExponent/dragCoefficient/stopSpeed with
        ///     -1 sentinels. The full init hardcodes useDragCurve=true. So rebuilding a justBaseCurve params object
        ///     through the full init silently turns the sentinels into *real* drag parameters (coefficient -1) and
        ///     switches the drag simulation on — which is exactly how this broke zoom.
        if p.useDragCurve {
            return MFScrollAnimationCurveParameters(baseCurve: p.baseCurve,
                                                    speedSmoothing: p.speedSmoothing,
                                                    baseMsPerStep: scaledMs,
                                                    baseMsPerStepCurve: scaledCurve,
                                                    dragExponent: p.dragExponent,
                                                    dragCoefficient: dragCoefficientForGlide, /// Fork: the Glide slider
                                                    stopSpeed: p.stopSpeed,
                                                    sendGestureScrolls: p.sendGestureScrolls,
                                                    sendMomentumScrolls: p.sendMomentumScrolls)
        } else {
            return MFScrollAnimationCurveParameters(justBaseCurve: p.baseCurve,
                                                    speedSmoothing: p.speedSmoothing,
                                                    baseMsPerStep: scaledMs,
                                                    baseMsPerStepCurve: scaledCurve,
                                                    sendGestureScrolls: p.sendGestureScrolls)
        }
    }
    
    // MARK: Acceleration
    
    /// User settings
    
    @objc lazy var u_speed: MFScrollSpeed = {
        switch c("speed") as! String {
        case "system":  return kMFScrollSpeedSystem /// Ignore MMF acceleration algorithm and use values provided by macOS
        case "low":     return kMFScrollSpeedLow
        case "medium":  return kMFScrollSpeedMedium
        case "high":    return kMFScrollSpeedHigh
        default: fatalError()
        }
    }()
    // MARK: Keyboard modifiers
    
    /// Event flag masks
    @objc lazy var horizontalModifiers = CGEventFlags(rawValue: c("modifiers.horizontal") as! UInt64)
    @objc lazy var zoomModifiers = CGEventFlags(rawValue: c("modifiers.zoom") as! UInt64)
    
}

// MARK: - Helper stuff

/// Storage class for animationCurve params

@objc class MFScrollAnimationCurveParameters: NSObject {
    
    /// Notes:
    /// - I don't really think it make sense for sendGestureScrolls and sendMomentumScrolls to be part of the animation curve, but it works so whatever
    
    /// baseCurve params
    @objc let baseCurve: Bezier?
    @objc let speedSmoothing: Double        /// `speedSmoothing` replaces `baseCurve`. If it is active, the baseCurve will be dynamically calculated, such that the animation speed doesn't jump after a scrollwheel-tick occurs.
    @objc let baseMsPerStep: Int            /// Duration of the baseCurve || When using dragCurve, that will make the actual msPerStep longer
    @objc let baseMsPerStepCurve: Curve?    /// If this is not nil, the duration of the baseCurve will be controlled by this curve. The point at which this curve is sampled will increase from 0 to 1 as the time between physical scrollWheel ticks decreases.
    /// dragCurve params
    @objc let useDragCurve: Bool /// If false, use only baseCurve, and ignore dragCurve
    @objc let dragExponent: Double
    @objc let dragCoefficient: Double
    @objc let stopSpeed: Int
    /// Other params
    @objc let sendGestureScrolls: Bool  /// If false, send simple continuous scroll events (like MMF 2) instead of using GestureScrollSimulator
    @objc let sendMomentumScrolls: Bool /// Only works if sendGestureScrolls and useDragCurve is true. If true, make Scroll.m send momentumScroll events (what the Apple Trackpad sends after lifting your fingers off) when scrolling is controlled by the dragCurve (and in some other cases, see TouchAnimator). Only use this when the dragCurve closely mimicks the Apple Trackpads otherwise apps like Xcode will behave differently from other apps during momentum scrolling.
    
    /// Init
    init(baseCurve: Bezier?, speedSmoothing: Double, baseMsPerStep: Int, baseMsPerStepCurve: Curve?, dragExponent: Double, dragCoefficient: Double, stopSpeed: Int, sendGestureScrolls: Bool, sendMomentumScrolls: Bool) {
        
        /// Init for using hybridCurve      [(baseCurve + dragCurve) or (speedSmoothingCurve + dragCurve)]
        
        if sendMomentumScrolls { assert(sendGestureScrolls) }
        assert((baseCurve == nil)     ^ (speedSmoothing == -1))
        assert((baseMsPerStep == -1)  ^ (baseMsPerStepCurve == nil))
        
        self.baseCurve = baseCurve
        self.speedSmoothing = speedSmoothing
        self.baseMsPerStepCurve = baseMsPerStepCurve
        self.baseMsPerStep = baseMsPerStep
        
        self.useDragCurve = true
        self.dragExponent = dragExponent
        self.dragCoefficient = dragCoefficient
        self.stopSpeed = stopSpeed
        
        self.sendGestureScrolls = sendGestureScrolls
        self.sendMomentumScrolls = sendMomentumScrolls
    }
    init(justBaseCurve baseCurve: Bezier?, speedSmoothing: Double, baseMsPerStep: Int, baseMsPerStepCurve: Curve?, sendGestureScrolls: Bool) {
        
        assert((baseCurve == nil)     ^ (speedSmoothing == -1))
        assert((baseMsPerStep == -1)  ^ (baseMsPerStepCurve == nil))
        
        /// Init for using just baseCurve
        
        self.baseCurve = baseCurve
        self.speedSmoothing = speedSmoothing
        self.baseMsPerStepCurve = baseMsPerStepCurve
        self.baseMsPerStep = baseMsPerStep
        
        self.useDragCurve = false
        self.dragExponent = -1
        self.dragCoefficient = -1
        self.stopSpeed = -1
        
        self.sendGestureScrolls = sendGestureScrolls
        self.sendMomentumScrolls = false
    }
}

fileprivate func animationCurveParamsMap(name: MFScrollAnimationCurveName) -> MFScrollAnimationCurveParameters? {
    
    /// Map from animationCurveName -> animationCurveParams
    /// For the origin behind these curves see ScrollConfigTesting.md
    /// @note I just checked the formulas on Desmos, and I don't get how this can work with 0.7 as the exponent? (But it does??) If the value is `< 1.0` that gives a completely different curve that speeds up over time, instead of slowing down.
    
    switch name {
        
    /// --- User selected ---
        
    case kMFScrollAnimationCurveNameNone:
        
        return nil
        
    case kMFScrollAnimationCurveNameNoInertia:
        
        fatalError()
        
        let baseCurve =
        Bezier(controlPoints: [_P(0, 0), _P(0, 0), _P(0.66, 1), _P(1, 1)], defaultEpsilon: 0.001)
//            Bezier(controlPoints: [_P(0, 0), _P(0.31, 0.44), _P(0.66, 1), _P(1, 1)], defaultEpsilon: 0.001)
//            ScrollConfig.linearCurve
//            Bezier(controlPoints: [_P(0, 0), _P(0.23, 0.89), _P(0.52, 1), _P(1, 1)], defaultEpsilon: 0.001)
        return MFScrollAnimationCurveParameters(justBaseCurve: baseCurve, speedSmoothing: -1, baseMsPerStep: 250, baseMsPerStepCurve: nil, sendGestureScrolls: false)
    
    case kMFScrollAnimationCurveNameVeryLowInertia:
        /// Added [Jun 4 2025] to support a new "Smoothness: Low" option in the MMF interface.
        ///     (kMFScrollAnimationCurveNameLowInertia) currently supports the "Smoothness: Regular" option.)
        ///     (Maybe we should move this code into kMFScrollAnimationCurveNameNoInertia, buit I don't wanna delete any code right now)
        ///     Context: [May 2025]
        ///         Recently I felt like Option 3 (in kMFScrollAnimationCurveNameLowInertia) is way too unresponsive. I'm doing a lot of 'scanning' of large text recently – quickly scrolling back and forth, and Option 3 feels wayy to 'gooey', so I'm experimenting with a new curve.
        ///         I also felt like one design goal of the previous curves – making text visible during scroling – didn't matter to me much right now? I feel like super fast movement is fine – you can still follow it, as long as your eyes have some context clues through animation. Plus once you're used to the scrolling, your brain anticipates where things end up.
        ///     Inspiration:
        ///         [May 17 2025] CLion's smooth scrolling looked quite good in this YouTube video: https://youtu.be/nnt5_qWX0eg. The CLion animation curve can be customized. The default might be https://cubic-bezier.com/#.17,.67,.83,.67 (those values are mentioned in the docs) ... But in the CLion Bezier editor it looks like the default settings are (0.25, 0.5, 0.5, 0.5). It's also possible that the default settings are different under Linux/Windows – the docs mention differences. The YouTuber might also have been using non-default settings. (Docs: https://www.jetbrains.com/help/clion/settings-appearance.html#ui?)
        ///         [Jun 4 2025] Linux Firefox scrolling looked good in this Tscoding video: https://www.youtube.com/watch?v=G9piTswOQZY
        ///             I have a theory that Firefox and Chrome might have different smoothing on macOS (compared to LInux/Window).
        ///                 - This would sort of make sense since the default acceleration curves are totally different on macOS, which makes the smoothing feel different, too.
        ///                 - Smooth scrolling not available in Chrome on macOS (?) https://www.reddit.com/r/chrome/comments/153tfev/smooth_scrolling_not_available_on_mac/
        ///         [Jun 4 2025] SmoothFox.js for Firefox – I've seen this recommended. I should try it.
        ///         [Jun 4 2025] I saw some Logitech Mouse have nice scrolling recently and some MMF user asked for less smoothing on GitHub recently after coming from Logitech's Driver. I remember I used to hate Logi Options scrolling but maybe they improved it or my tasted have changed?
        
        #if false /// [Jul 2025] Would like to use `MF_TEST 0` here, but not sure how in Swift
        if _1 {
            var baseCurve:          Bezier?          = nil
            var baseSpeedupCurve:   Curve?           = nil
            
            if (_1) {
                /// Option 3
                ///     Context: [Jun 2] I like the 6.2 values and have been using them over the last weeks.
                ///         Only issues I noticed:
                ///             - Things can feel a tad big abrupt at some points  ––– but I feel like it's a necessary tradeoff for having very short, responsive, predictable animations. (?)
                ///             - Animations feel like they 'match' finger speed when moving finger slowly or quickly, but animations 'lag behind' finger movement a bit at medium speeds ––– 6.3 is trying to address that
                ///         Plan 1:
                ///             Add curvature to make animation higher at medium finger speed.
                ///             Conclusion: [Jun 2 2025]|(Possibly premature) Not sure curve great here. Higher-medium speeds feel good now, but lower-medium speeds still feel too slow. We usually used the BezierCappedAccelerationCurveto scale animation *distance* relative to user input speed. (I found it nice for pointer acceleration and scroll acceleration) But here, we're scaling animation *duration* instead. It feels more sound to scale animation duration linearly relative to input speed. I feel like adjusting the lo-end and hi-end of when we start and stop to apply the linear acceleration might be more appropriate. Alternatively we could use a Cubic Bezier instead of BezierCappedAccelerationCurve to boost animation speed at lower-medium finger-speeds
                ///         Plan 2:
                ///             Adjust the `consecutiveScrollTickIntervalMax` up. [Jun 4 2025]
                ///     Sidequest: (Maybe move these notes somewhere else) [Jun 2 2025]
                ///         Looked into what 'defaultEpsilon' values to use for the BezierCappedAccelerationCurve here. I tested 0.001 and 300. Surprisingly, both were effectively the same in both speed and accuracy. Even though 300 basically turns off the entire algorithm after it makes its 'first guess', while 0.001 demands very high accuracy, and should cause the algorithm to run several newton/bisection iterations.
                ///             It seems that  that the "initialGuess" of the newton algorithm is so good that doesn't ever need any further iterations even with epsilon 0.001. I'm not sure why this is. I think it might have to do with the range of x-values being small (0,1) while the range of y values is large (250,100) (The algorithm we're talking about tries to find a 't' for a given x value, and apparently the x and t values are (almost?) exactly equal here, which makes the 'initialGuess' of the algorithm highly accurate.)
                ///             I've used CurveVisualizer.swift to test this (I built it for this purposes)
                ///             Conclusion: You can use 0.001 as the 'defaultEpsilon'. it has no overhead and might make things more robust than a higher value if we change things later.
                ///     Experiences: [Jun 7 2025]
                ///         Over the last few days I have been using the old 'LowInertia' in the mornings since the new 'VeryLowInertia' felt too harsh and unsmooth, and then during the day after I really woke up and got into work I wanted the 'VeryLowInertia' since it gives more control.
                ///         Over the last 1-2 days I've noticed that
                ///             for slow and medium finger-speed the 'LowInertia' is actually nice. I especially like that you can make small-but-fast 2-tick scroll-swipes, without having the animation speed become too fast. This is nice since that's is the lowest-effort way to scroll small distances IMO – Inputting single ticks at a time requires more finger-tension (Pretty sure I wrote about this finger-tension-thing before but can't remember where.)
                ///             However, for fast-and-large swipes, the 'LowInertia' scrolling is very annoying since it feels like the page is sliding around when you want it to stop. A an examples is when you quickly go up and down 3/4 of a page to cross-examine the content. Having to wait for the animation there is very annoying.
                ///                 Idea: We might want to control the scroll-tick-smoothing in ScrollAnalyzer.m based on the ScrollConfig. That would let us influence how those small-but-fast two-tick-swipes are handled. With higher inertia, those swipes are somewhat smoothed out naturally, but with very-low inertia it can feel more erratic and I think more scroll-tick-smoothing could help.
                ///             Thought: This makes me think that instead of introducing a new 'VeryLowInertia' setting it might be better to first try to tweak the 'LowInertia' animations. I think the  'LowInertia' animations would be pretty usable for me if they weren't so 'slidey' for the fast-and-large swipes.
                var curv: Double = 0.85
                baseCurve = Bezier(controlPoints: [_P(0, 0), _P(0, 0), _P(curv, 1), _P(1, 1)], defaultEpsilon: 0.001)
                var tup: (Double, Double) = ((1000.0/60)*15, (1000.0/60)*6)
                var animationSpeedupCurvature: Double = -1
                if (_0) { animationSpeedupCurvature = 1.0 } /// Makes for unpredictable, jerky speedup when trying to scroll slowly but then accidentally producing 2 wheel ticks that are a bit closer together [Jun 3 2025]
                if (_1) { animationSpeedupCurvature = 0.00 } /// Turn off curvature, now that we've increased consecutiveScrollTickIntervalMax from 160 -> 200 ms
                
                baseSpeedupCurve = BezierCappedAccelerationCurve(xMin: 0, xMax: 1, yMin: tup.0, yMax: tup.1, curvature: animationSpeedupCurvature,
                                                                 reduceToCubic: false, defaultEpsilon: 0.001)
                
                
                /// DEBUG
                if #available(macOS 15.0, *) {
                    CurveVisualizer.setCurveTrace1(baseSpeedupCurve!.traceAsPoints(startX: 0.0, endX: 1.0, nOfSamples: 1000))
                }
            }
            
            if (_0)  {
                /// Option 2
                ///     Context: [May 10] A few days later, I wanted a bit more fluid, less unnatural/abrupt animations, so we added an ease-out instead of a linear curve
                ///     Update [May 12] I liked 0.95, but a few days later, the abrupt stops feel offputting while scrolling slowly and continuously to scan for text in small IDA Output window. I scrolled at a speed right at the edge of where the animation becomes continuous - Solution idea: Maybe we could have a stronger ease-out while scrolling slowly but keep the mostly linear curve for faster movements? I generally prefer slower animation today and am Happy with Option 3. - Perhaps cause I'm more tired/relaxed than the last days. Update: Actually using 0.85 seems to solve the problem without making other stuff feel weird I think ... Update2: Nah 0.85 makes the speed feel 'inconsistent'. Update3: I played around with Firefox today and it also feels 'inconsistent'. The mostly linear animation curve is good because it keeps the animations speed steady and directly tied to the speed of the user's finger movement. But perhaps a hybrid solution where we have a smooth ease-out for slow finger movements but become close-to-linear at medium and fast finger movements would solve this.
                ///         Update: [May 20] Setting the lo speed lower (20 frames is nice but I haven't tested much) Makes the problem with slow, continuous scrolling go away! ... But it makes medium-speed scrolls feel sluggish. This suggests that we could make this feel really great by keeping a linear animation curve but refining the speedup curve. Update 2: Actually with 15 frames it feels even better. Maybe we can keep the linear speedup curve like that.
                var curv: Double = .nan
                if (_0) { curv = 0.9 }
                if (_0) { curv = 0.95 } /** I like 0.95. It's very subtle, might be placebo.  With 0.75 if felt the speed was too 'fluctuating' and inconsistent. But with 1.0 I felt the animation stop looks abrupt. */
                if (_0) { curv = devToggles_C }
                if (_1) { curv = 0.85 } /**[May 20 2025] I accidentally got used to this over the last few days and I like it now. Stops feel less abrupt than 0.95  */
                print("ScrollConfig: DevToggles: curvature: \(curv)")
                baseCurve = Bezier(controlPoints: [_P(0, 0), _P(0, 0), _P(curv, 1), _P(1, 1)], defaultEpsilon: 0.001)
                var tup: (Double, Double) = (-1, -1)
                if (_0) { tup = ((1000.0/60)*12, (1000.0/60)*6) }
                if (_0) { tup = ((1000.0/60)*Double(devToggles_Lo), (1000.0/60)*Double(devToggles_Hi)) }
                if (_1) { tup = ((1000.0/60)*15, (1000.0/60)*6) }
                baseSpeedupCurve = Curve(rawCurve: { x in Math.scale(x, (0,1), tup) })
            }
            
            if (_0)  {
                /// Option 1
                baseCurve = ScrollConfig.linearCurve
                var tup: (Double, Double) = (-1, -1)
                if (_0) { tup = (160, 90)                          }
                if (_0) { tup = ((1000.0/60)*3,  (1000.0/60)*3)    }
                if (_0) { tup = ((1000.0/60)*12, (1000.0/60)*3)    }
                if (_0) { tup = ((1000.0/60)*12, (1000.0/60)*5)    }
                if (_1) { tup = ((1000.0/60)*12, (1000.0/60)*6)    }
                if (_0) { tup = ((1000.0/60)*12, (1000.0/60)*12)   }
                baseSpeedupCurve = Curve(rawCurve: { x in Math.scale(x, (0,1), tup) })
            }
            if (_0) {
                /// Option 0
                baseCurve = ScrollConfig.linearCurve
                let curvature = 4.0
                let baseMsPerStepCurveMax = 200.0
                let baseMsPerStepCurveMin = 90.0
                if curvature == 0.0 {
                    let e = { x in Math.scale(x, (0, 1), (baseMsPerStepCurveMax, baseMsPerStepCurveMin)) }
                    baseSpeedupCurve = Curve(rawCurve: e)
                } else {
                    
                    let e1 = { x in exp(x * curvature) - 1 }
                    let e2 = { x in e1(x) / e1(1) }
                    let e3 = CurveTools.transformCurve(e2) { y in Math.scale(y, (0, 1), (baseMsPerStepCurveMax, baseMsPerStepCurveMin)) }
                    baseSpeedupCurve = Curve(rawCurve: e3)
                }
            }
            return MFScrollAnimationCurveParameters(justBaseCurve: baseCurve!, speedSmoothing:-1, baseMsPerStep:-1, baseMsPerStepCurve: baseSpeedupCurve!, sendGestureScrolls: false)
        }
        
        #endif
        
        fatalError()
        
    case kMFScrollAnimationCurveNameLowInertia:

        /// Option 5: Higher baseMsPerStep
        if _0 {
            return MFScrollAnimationCurveParameters(baseCurve: nil, speedSmoothing: -1, baseMsPerStep: -1, baseMsPerStepCurve: Curve(rawCurve: { x in Math.scale(x, (0,1), (90, 160)) }), dragExponent: 1.0, dragCoefficient: 23, stopSpeed: 30, sendGestureScrolls: false, sendMomentumScrolls: false)
        }
        
        /// Option 4: Combination of previous 2 (below I think)
        if _0 {
            return MFScrollAnimationCurveParameters(baseCurve: nil, speedSmoothing: -1, baseMsPerStep: -1, baseMsPerStepCurve: Curve(rawCurve: { x in Math.scale(x, (0,1), (90, 140)) }), dragExponent: 1.05, dragCoefficient: 15, stopSpeed: 30, sendGestureScrolls: false, sendMomentumScrolls: false)
        }
        
        /// Option 3: This tries to 'feel' like MMF 2.
        ///     (Update: [May 2025] This shipped with the latest version of MMF (3.0.3 and 3.0.4 Beta 1) – IIRC we tried Option 4 and Option 5 but went back to Option 3 before shipping)
        ///     - For medium and large scroll swipes it feels similarly responsive snappy to MMF 2 due to the 90 baseMsPerStepMin. (In MMF 2 the baseMsPerStep was 90)
        ///     - For single ticks on default settings, the speed feels similar to MMF 2 due to the 140 baseMsPerStep and due to the step size being larger than MMF 2.
        ///     - In MMF 2, exponent is 1.0 and coeff is 2.3. Here the coeff is 23. Not sure if that's the same but feels similar.
        ///     - Update:
        ///         - We've now replaced baseMsPerStepMin with baseMsPerStepCurve and changed all the parameters around. (See below for more info on that) Not sure this feels like MMF 2 anymore. But it feels really good.
        
        /// Define curve for the baseMsPerStepCurve speedup
        ///
        /// Notes:
        ///
        /// - The reason why we introduced a curve, is that when we tried linear interpolation for the baseMsPerStepMin, we found that little 2-3 tick swipes were too fast, but larger/faster swipes were too slow. Initially, we tried to fix that by adding additional smoothing inside ScrollAnalyzer by initializing the `_tickTimeSmoother` with a value. However, this messed up the scroll distance acceleration, so we turned that back off. This curve is our second attempt at making the 2-3 tick swipes animate slower while making the larger or faster swipes animate faster. In contrast to the previous ScrollAnalyzer-based approach, this approach doesn't have a time component, where if you scroll at the same speed for a longer time it speeds up more. Not sure if this is a good or bad thing.
        /// - The curve we're using (at the time of writing) is basically just a shifted and scaled exponential function. I designed it using this desmos page: https://www.desmos.com/calculator/l8plcdlpmn. I first tried using a Bezier curve, but it didn't get curved enough. I thought about using a curve based on 1/x instead of e^x, but they looked very similar in desmos and e^x is simpler to deal with.
        /// 
        /// - Sidenotes:
        ///     - It's overall a little messy that we have these hybrid curves whose duration we can't directly control, but then we create complex curves for the duration of the baseCurve of the HybridCurve to gain back some control of the overall duration. It's sort of messy and confusing. All in the name of having the deceleration feel 'physical'. (That's the purpose of the HybridCurves) I mean this is still the best feeling scrolling algorithm I know of so I guess it works, but I really wonder if it wouldn't have been possible to design something more elegant. Maybe we could've done a sort of spring animator and then dynamically chose the starting speed such that the animation covers a certain distance in a certain time. That's the thing we really want to have explicit control over: The distance. But we also want to have control over the feel and over the duration. However, if you want to have a 'physical' feel it's complicated to also control the distance and duration. And actually in case of the high smoothness curves I think I'm pretty happy not having to explicitly control the duration. The duration just falls out of the physics in a nice way. Update: Stared at Desmos for a while and came to the conclusion that our current idea is the best and with spring animations we'd have more or less the same problem. (Can't easily control both duration and distance while keeping consistent physics)
        ///
        /// - **Ideaaa**: It seems that what I'm currently trying to to when designing these curves is 1. Make the animations speed for fastest scrollwheel movements as fast as possible without becoming disorientating to look at 2. Adjust the animation speed for lower scrollwheel speed to feel 'the same' or 'consistent' with the fastest scrollwheel speed - because the 'consistent' feel makes it easier to control. (I'm not sure what consistent means, it's just a feeling) --- Maybe we could do this stuff explicitly somehow. Like explicitly cap the animation speed. Update: Just measured the overall animation duration (including drag) after finding a `baseMsPerStepCurve` that feels 'consistent' to us and I found the duration is relatively close to being constant! It's currently between 260 and 300 ms - This gives me the idea that what we were subconsciously doing with the `baseMsPerStepCurve` was to try and make the overall animation duration constant. Maybe that's what made it feel 'consistent' to us. Update: Also did some testing for curves that feel 'inconsistent' to us and the variation in overall animation duration wasn't thatt much more as I thought. I think what I observed was like 240 to 340 ms. Maybe this means that the 'consistent' feel has other aspects aside from low variation in overall animation duration.
        ///     - **Implementation Ideas**: These thoughts give me two concrete ideas for potentially improving our scrolling algorithms:
        ///         1. Idea: Make a way to create a `HybridCurve` with a fixed duration along with a fixed distance. The HybridCurve should then automatically figure out what the baseCurve should be / how fast the baseMsPerStep should be. Having explicit control over the duration might allow us to create better, more 'consistent' feeling and more controllable curves. I don't think we'd want to use this for High Smoothness scrolling, since there we want a large variability in animation duration, and the way the current algorithms behave feels very natural and predictable to me already. But for the regular smoothness setting (Which uses this code right here), this could potentially be nice. But on the other hand, maybe the bit of variability in animation duration is good? I'm not sure. Butt, if we implemented a system for explicitly controlling the animation duration, we could still vary the animation duration with the animation distance or with the scrollwheel speed. We'd simply have more control over it, which I think really couldn't hurt?
        ///             - Conclusion: This idea is interesting. I think it would be good to try at some point. But to really ship this, we'd have to be careful and dedicate a lot of time to testing. I think for now, the current approach of defining a `baseSpeedupCurve` to get some control over the scroll animation duration seems like it's good enough. Maybe it's even inherently better than this idea. I'm not sure. That's why I should test it at some point. But not now.
        ///         2. Idea: Make a way to explicitly specify a maxAnimationSpeed(Target) which is the highest speed where your eyes can follow scrolling content on the screen (This probably depends on screen refresh rate and other stuff, but we can assume our own screen as a heuristic I think). The duration of the animation curve could then be dynamically determined to be such that, when the user does a scroll swipe at max speed, the resulting animation has a max speed of maxAnimationSpeed(Target). Note that this means we'd choose different animation durations for different "Scrolling Speed" user settings that the user might choose (These user settings really determine sensitivity to be precise) . As a simpler-to-implement stand-in for such a mechanism, we could simply scale the baseMsPerStep with the accelerationCurve. E.g. we could desing the baseMsPerStep around the mediumSpeed accelerationCurve, then sample both the mediumSpeed accelerationCurve and the currentSpeed accelerationCurve at let's say 80% of the maximum scrollwheel speed that the user can input, and then get the scaling factor `s` between the 80% values of those two curves. Then we could multiply the baseMsPerStep with `s`. That way we only have to find a suitable baseMsPerStep for the mediumSpeed accelerationCurve and the rest would be adjusted such that the user can produce an animation speed of *up to* maxAnimationSpeed(Target) no matter what "Scrolling Speed" setting they choose.
        ///             - Sidenote: I'm putting "Target" in `maxAnimationSpeed(Target)` because it's not supposed to be a hard cap for the animation speed it's more like a heuristic saying: if the user inputs the fastest scroll they can, then the movement on the screen should be about this fast.
        ///             - Conclusion: I think this is an idea worth exploring, especially when we introduce more options for the user to choose a "Scrolling Speed".  However, this would need a lot of testing to make sure we're getting it right, and I should only do it if I have time to dedicate to this. So not now.
        ///
        /// - Idea:
        ///     - What's interesting is that the animationDuration is influenced by both the baseMsPerStep speed up mechanism as well as by the Drag physics inside the HybridCurve. But at the time of writing, the baseMsPerStep speed up is applied purely based on timeBetweenscrollwheelTicks, while the animationDuration modification from the drag physics is applied based on how many pixels are left to scroll. (Which is also a result of the timeBetweenscrollwheelTicks but with an additional time component I think). This is quite messy to think about. Based on these thoughts, I would think that the animationDuration is very unpredictable. But in practise it doesn't feel that way. 
        ///
        /// - Finding parameters:
        ///     - I liked 4.0, 140.0, 60.0 for a while - It feels super direct and immediate. And still smoother than Chrome. However I found that it's hard to follow scrolling movements with your eyes at least on my displays.
        ///     - I liked 4.0, 180.0, 110.0
        ///         - Notes:
        ///             - 110 feels like MMF 2 on fast swipes, it's slow enough that  you can still see the content well. 110 is the lower end for clear visibiliy during scrolling I think. Setting the max to 180 makes the speed feel 'consistent' for slow and fast swipes which helps controllability.
        ///             - I have played around with small changes to this a bit. E.g. using 170 instead of 180. I had the impression that 4.0, 180.0, 110.0 is close to a local optimum.
        ///                 - I also tried 200.0, 120.0 - I thought 120 feelt less grating and confusing to eyes, but that made it feel a bit too unresponsive
        ///             - The max animation speed of this feels similar to the pre 3.0.1 algorithm. We did this whole baseMsPerStepCurve (and the predecessor baseMsPerStepMin) stuff because we thought that things felt too unresponsive and now it feels like we've arrived at something similar to the starting point. But, I really think this is at the upper end of animation speed that is nice to use, and the responsiveness is noticably better than pre 3.0.1. Controllability is also better I think.
        ///             - You'd think that the whole baseCurveSpeedup and curvature stuff would make the scrolling less predictable/controllable. Not totally sure, but I feel like for this curve if we turn the speedup off it becomes harder to control/predict. Update: I looked at the overall animation duration (including DragCurve and BaseCurve) and there's less variation in that with this speedup mechanism. Maybe decreased variability makes things more predictable / easy to control. See **Ideaaa** above for more on this.
        
        if _1 {
            let curvature = 4.0                  /* 5.0   4.0 */ /// Should be >= 0.0
            let baseMsPerStepCurveMax = 180.0    /* 140.0 150.0  180.0  200.0 */
            let baseMsPerStepCurveMin = 110.0    /* 60.0  90.0    110.0  120.0 */ /// MMF 2 feels more like 110 not 90 or 60
            
            let baseSpeedupCurve: Curve
            
            if curvature == 0.0 {
                let e = { x in Math.scale(x, (0, 1), (baseMsPerStepCurveMax, baseMsPerStepCurveMin)) }
                baseSpeedupCurve = Curve(rawCurve: e)
            } else {
                
                let e1 = { x in exp(x * curvature) - 1 }
                let e2 = { x in e1(x) / e1(1) }
                let e3 = CurveTools.transformCurve(e2) { y in Math.scale(y, (0, 1), (baseMsPerStepCurveMax, baseMsPerStepCurveMin)) }
                baseSpeedupCurve = Curve(rawCurve: e3)
            }
            
            return MFScrollAnimationCurveParameters(baseCurve: ScrollConfig.linearCurve, speedSmoothing: -1, baseMsPerStep: -1, baseMsPerStepCurve: baseSpeedupCurve, dragExponent: 1.0, dragCoefficient: 23, stopSpeed: 30, sendGestureScrolls: false, sendMomentumScrolls: false)
        }
        
        /// Option 2: Pre 3.0.1 curve (I think)
        /// - I don't like this curve atm. It's still too slow. I'm currently 'tuned into' liking the MMF 2 algorithm and it's much quicker than this.
        /// - MMF 2 has baseMsPerStep 90, this makes medium and large scroll swipes feel much more responsive. But single scroll ticks feel too fast. Maybe we could implement an algorithm where the baseMSPerStep is variable and it shrinks on consecutive scroll swipes or as the scroll speed gets higher, or sth like that. Ideas:
        ///    - Add a cap to the base scroll speed.
        ///    - Make the msPerStep a mix between baseMSPerStep and the actual msPerStep of the scrollwheel. Maybe as soon as `scrollWheelMsPerStep < baseMSPerStep` we use `scrollWheelMsPerStep` or do an interpolation between the 2
        ///         Update: Implemented this with the `baseMsPerStepMin`param (Update: Now changed to `baseMsPerStepCurve`)
        
        if _0 {
            return MFScrollAnimationCurveParameters(baseCurve: ScrollConfig.linearCurve, speedSmoothing: -1, baseMsPerStep: 140, baseMsPerStepCurve: nil, dragExponent: 1.05, dragCoefficient: 15, stopSpeed: 30, sendGestureScrolls: false, sendMomentumScrolls: false)
        }
        
        /// Option 1: I think I like this curve better. Still super responsive and much smoother feeling. But I'm not sure I'm 'tuned into' what the lowInertia should feel like. Bc when I designed it I really liked the snappy, 'immediate' feel, but now I don't like it anymore and wanna make everything much smoother. So I'm not sure I should change it now. Also we should adjust the speed curves if we adjust the feel of this so much.
        if _0 {
            return MFScrollAnimationCurveParameters(baseCurve: nil,                      speedSmoothing: 0.15, baseMsPerStep: 175, baseMsPerStepCurve: nil, dragExponent: 0.9, dragCoefficient: 25, stopSpeed: 30, sendGestureScrolls: false, sendMomentumScrolls: false)
        }
        
        fatalError()
        
    case kMFScrollAnimationCurveNameMediumInertia:
        
        fatalError()
        
        return MFScrollAnimationCurveParameters(baseCurve: ScrollConfig.linearCurve, speedSmoothing: -1, baseMsPerStep: 200, baseMsPerStepCurve: nil, dragExponent: 1.05, dragCoefficient: 15, stopSpeed: 30, sendGestureScrolls: false, sendMomentumScrolls: false)
        
        return MFScrollAnimationCurveParameters(baseCurve: ScrollConfig.linearCurve, speedSmoothing: -1, baseMsPerStep: 190, baseMsPerStepCurve: nil, dragExponent: 1.0, dragCoefficient: 17, stopSpeed: 50, sendGestureScrolls: false, sendMomentumScrolls: false)
        
    case kMFScrollAnimationCurveNameHighInertia:
        
        /// - This uses the snappiest dragCurve that can be used to send momentumScrolls.
        ///    If you make it snappier then it will cut off the built-in momentumScroll in apps like Xcode
        /// - We tried setting baseMsPerStep 205 -> 240, which lets medium scroll speed look slightly smoother since you can't tell the ticks apart, but it takes longer until text becomes readable again so I think I like it less. Edit: In MOS's scrollAnalyzer, 240 is the lowest baseMSPerStep where the animationSpeed is constant for low medium scrollwheel speed. Edit: But 215 - 220 is also almost perfect for medium speeds, and in AB testing it's barely different-feeling than 205. In AB testing, I liked 220 slightly more than 240, but the difference is small.
        /// - Speed smoothing prevents the slightly unsmooth look at medium and low scroll speeds, but it can also make scrolling feel less responsive and direct. From my testing, at 0.4 it becomes sluggish feeling. Edit: From more testing, I think 0.15 makes especially single ticks a bit smoother, and doesn't noticably impact responsiveness. I did some performance testing, since with speedSmoothing, the BezierCurves can't be optimized into simple straight lines anymore. Scrolling to the bpm of a song the CPU usage went from 1.2% -> 1.6% percent. That's a 30% increase, but it's still very fast. Currently we're using an epsilon of 0.01 for the BezierCurves. If we lower that we might get even better performance, but it already gives slightly different curves in MOS scroll analyzer with this epsilon compared to more accurate epsilon, so I don't think we should make it lower.
        /// Update: Turned speedSmoothing from 0.15 -> 0.00 rn for more responsive/predictable feel.
        ///     - This is an experiment. I thought it made it easier to use the 'scrollStop' feature where you scroll one tick in the opposite direction to stop the scroll animation. 'Throwing' the page and then stopping it felt more predictable with speedSmoothing off.
        ///     - I also heard some reports from people that scrolling in 3.0.1 is worse / performs worse than before. (I'm fairly sure we introduced speedSmoothing in 3.0.1) So maybe the performance issues could also have to do with speedSmoothing? (I don't think it should be performance intensive enough to make a difference though, but who knows?)
        ///     - However I also found that scrolling felt refreshingly responsive after turning speed smoothing off. Might be placebo, but I think I like it better.
        
        return MFScrollAnimationCurveParameters(baseCurve: nil/*ScrollConfig.linearCurve*/, speedSmoothing: /*0.15*/0.0, baseMsPerStep: 220, baseMsPerStepCurve: nil, dragExponent: 0.7, dragCoefficient: 40, stopSpeed: /*50*/30, sendGestureScrolls: false, sendMomentumScrolls: false)
        
    case kMFScrollAnimationCurveNameHighInertiaPlusTrackpadSim:
        /// Same as highInertia curve but with full trackpad simulation. The trackpad sim stuff doesn't really belong here I think.
        return MFScrollAnimationCurveParameters(baseCurve: nil/*ScrollConfig.linearCurve*/, speedSmoothing: /*0.15*/0.0, baseMsPerStep: 220, baseMsPerStepCurve: nil, dragExponent: 0.7, dragCoefficient: 40, stopSpeed: /*50*/30, sendGestureScrolls: true, sendMomentumScrolls: true)
        
    /// --- Dynamically applied ---
        
    case kMFScrollAnimationCurveNameTouchDriver:
        /// v Note: At the time of writing, this curve is equivalent to a BezierCappedAccelerationCurve with curvature 1.
        let baseCurve = Bezier(controlPoints: [_P(0, 0), _P(0, 0), _P(0.5, 1), _P(1, 1)], defaultEpsilon: 0.001)
        return MFScrollAnimationCurveParameters(justBaseCurve: baseCurve,                   speedSmoothing:-1, baseMsPerStep: /*225*/250/*275*/, baseMsPerStepCurve:nil, sendGestureScrolls: false)
        
    case kMFScrollAnimationCurveNameTouchDriverLinear:
        return MFScrollAnimationCurveParameters(justBaseCurve: ScrollConfig.linearCurve,    speedSmoothing:-1, baseMsPerStep: 180/*200*/, baseMsPerStepCurve:nil, sendGestureScrolls: false)
    case kMFScrollAnimationCurveNameQuickScroll:
        
        /// - Almost the same as `highInertia` just more inertial. Actually same feel as trackpad-like parameters used in `GestureScrollSimulator` for autoMomentumScroll.
        /// - Should we use trackpad sim (sendMomentumScrolls and sendGestureScrolls) here?
        return MFScrollAnimationCurveParameters(baseCurve: ScrollConfig.linearCurve, speedSmoothing: -1, baseMsPerStep: /*220*/300, baseMsPerStepCurve: nil, dragExponent: 0.7, dragCoefficient: 30, stopSpeed: 1, sendGestureScrolls: true, sendMomentumScrolls: true)
        
    case kMFScrollAnimationCurveNamePreciseScroll:
        
        /// Similar to `lowInertia`
//        return MFScrollAnimationCurveParameters(baseCurve: ScrollConfig.linearCurve, baseMsPerStep: 140, dragExponent: 1.0, dragCoefficient: 20, stopSpeed: 50, sendGestureScrolls: false, sendMomentumScrolls: false)
        return MFScrollAnimationCurveParameters(baseCurve: ScrollConfig.linearCurve, speedSmoothing: -1, baseMsPerStep: 140, baseMsPerStepCurve: nil, dragExponent: 1.05, dragCoefficient: 15, stopSpeed: 50, sendGestureScrolls: false, sendMomentumScrolls: false)
        
    /// --- Testing ---
        
    case kMFScrollAnimationCurveNameTest:
        
        return MFScrollAnimationCurveParameters(justBaseCurve: ScrollConfig.linearCurve, speedSmoothing:-1, baseMsPerStep: 350, baseMsPerStepCurve: nil, sendGestureScrolls: false)
        
    /// --- Other ---
    
    default:
        fatalError()
    }
}

/// Retained only as historical tuning documentation. The event-rate input domain
/// was rejected for the true-velocity engine; make accidental restoration a
/// compile-time error unless the model is deliberately redesigned and revalidated.
@available(*, unavailable, message: "Use the true-velocity output model")
fileprivate func getAccelerationCurve(forSpeed speedArg: MFScrollSpeed, smoothness: MFScrollSmoothness, animationCurve: MFScrollAnimationCurveName, inputAxis: MFAxis, display: CGDirectDisplayID, scaleToDisplay: Bool, modifiers: MFScrollModificationResult, useQuickModSpeed: Bool, usePreciseModSpeed: Bool, consecutiveScrollTickIntervalMax: Double, consecutiveScrollTickInterval_AccelerationEnd: Double) -> Curve {
    
    /// Notes:
    /// - The inputs to the curve can sometimes be ridiculously high despite smoothing, because our time measurements of when ticks occur are very imprecise
    ///     - Edit: Not sure this is still true since we switched to using CGEvent timestamps instead of CACurrentMediaTime() time at some point. I think we also made some changes so the timeBetweenTicks is always reported to be at least `consecutiveScrollTickIntervalMin` or `consecutiveScrollTickInterval_AccelerationEnd`, which would mean we don't have to worry about this here.
    /// - `_n` stands for 'normalized', so the value is between 0.0 and 1.0
    /// - Before we used the `BezierCappedAccelerationCurve` we used `capHump` / `accelerationHump` curvature system. The last commit with that system (commented out) is 1304067385a0e77ed1c095e39b8fa2ae37b9bde4
    
    /**
     
     General thoughts / explanation on how our BezierCappedAccelerationCurve class works in this context:
     
      Define a curve describing the relationship between the inputSpeed (in scrollwheel ticks per second) (on the x-axis) and the sensitivity (In pixels per tick) (on the y-axis).
      We'll call this function y(x).
      y(x) is composed of 3 other curves. The core of y(x) is a BezierCurve *b(x)*, which is defined on the interval (xMin, xMax).
      y(xMin) is called yMin and y(xMax) is called yMax
      There are two other components to y(x):
      - For `x < xMin`, we set y(x) to yMin
      - We do this so that the acceleration is turned off for tickSpeeds below xMin. Acceleration should only affect scrollTicks that feel 'consecutive' and not ones that feel like singular events unrelated to other scrollTicks. `self.consecutiveScrollTickIntervalMax` is (supposed to be) the maximum time between ticks where they feel consecutive. So we're using it to define xMin.
      - For `xMax < x`, we lineraly extrapolate b(x), such that the extrapolated line has the slope b'(xMax) and passes through (xMax, yMax)
      - We do this so the curve is defined and has reasonable values even when the user scrolls really fast
      - (Our uses of tick and step are interchangable here)
     
      HyperParameters:
      - `curvature` raises sensitivity for medium scrollSpeeds making scrolling feel more comfortable and accurate. This is especially nice for very low minSens.
     */

    var screenSize: size_t = -1
    if useQuickModSpeed || scaleToDisplay {
        
        if inputAxis == kMFAxisHorizontal
            || modifiers.effectMod == kMFScrollEffectModificationHorizontalScroll {
            screenSize = CGDisplayPixelsWide(display);
        } else if inputAxis == kMFAxisVertical {
            screenSize = CGDisplayPixelsHigh(display);
        } else {
            fatalError()
        }
    }
    
    let speed_n: Double = SharedUtilitySwift.eval {
        switch speedArg {
        case kMFScrollSpeedLow: 0.0
        case kMFScrollSpeedMedium: 0.5
        case kMFScrollSpeedHigh: 1.0
        case kMFScrollSpeedSystem: -1.0
        default: -1.0
        }
    }
    
    let minSend_n = speed_n
    let maxSens_n = speed_n
    let curvature_n = speed_n
    
    var minSens: Double
    var maxSens: Double
    var curvature: Double
    
    if useQuickModSpeed {
        
        let windowSize = Double(screenSize)*0.85 /// When we use unanimated line-scrolling this doesn't hold up, but I think we always animate when using quickMod
        
        minSens = windowSize * 0.5 //100
        maxSens = windowSize * 1.5 //500
        curvature = 0.0
        
    } else if usePreciseModSpeed {

        minSens = 1
        maxSens = 20
        curvature = 2.0
        
    } else if animationCurve == kMFScrollAnimationCurveNameTouchDriver
                || animationCurve == kMFScrollAnimationCurveNameTouchDriverLinear {
        
        /// At the time of writing, this is an exact copy of the `regular` smoothness acceleration curves. Not totally sure if that makes sense. One reason I can come up with for adjusting this to the user's scroll speed settings is that the user might use the scroll speed settings to compensate for differences in their physical scrollwheel and therefore the speed should apply to everything they do with the scrollwheel
        
        minSens =   CombinedLinearCurve(yValues: [45.0, 60.0, 90.0]).evaluate(atX: minSend_n)
        maxSens =   CombinedLinearCurve(yValues: [90.0, 120.0, 180.0]).evaluate(atX: maxSens_n)
        curvature = CombinedLinearCurve(yValues: [0.25, 0.0, 0.0]).evaluate(atX: curvature_n)

        
    } else if smoothness == kMFScrollSmoothnessOff { /// It might be better to use the animationCurve instead of smoothness in these if-statements
        
        minSens =   CombinedLinearCurve(yValues: [20.0, 30.0, 40.0]).evaluate(atX: minSend_n)
        maxSens =   CombinedLinearCurve(yValues: [40.0, 60.0, 80.0]).evaluate(atX: maxSens_n)
        curvature = CombinedLinearCurve(yValues: [4.25, 3.0, 2.25]).evaluate(atX: curvature_n)

    } else if smoothness == kMFScrollSmoothnessLow { /// kMFScrollAnimationCurveNameVeryLowInertia

        minSens =   CombinedLinearCurve(yValues: [30.0, 60.0, 120.0]).evaluate(atX: minSend_n)
        maxSens =   CombinedLinearCurve(yValues: [90.0, 120.0, 180.0]).evaluate(atX: maxSens_n)
        curvature = CombinedLinearCurve(yValues: [0.25, 0.0, 0.0]).evaluate(atX: curvature_n)

    } else if smoothness == kMFScrollSmoothnessRegular {

        minSens =   CombinedLinearCurve(yValues: [/*20.0, 40.0,*/ 30.0, 60.0, 120.0]).evaluate(atX: minSend_n)
        maxSens =   CombinedLinearCurve(yValues: [/*60.0, 90.0,*/ 90.0, 120.0, 180.0]).evaluate(atX: maxSens_n)
        curvature = CombinedLinearCurve(yValues: [0.25, 0.0, 0.0]).evaluate(atX: curvature_n)
        
    } else if smoothness == kMFScrollSmoothnessHigh {
        
        minSens =   CombinedLinearCurve(yValues: [/*30.0,*/ 60.0, 90.0, 150.0]).evaluate(atX: minSend_n)
        maxSens =   CombinedLinearCurve(yValues: [/*90.0,*/ 120.0, 180.0, 240.0]).evaluate(atX: maxSens_n)
        curvature = 0.0
        
    } else {
        fatalError()
    }
    
    /// Screen height
    
    if scaleToDisplay {
        
        /// Get screenHeight factor
        let baseScreenSize = inputAxis == kMFAxisHorizontal ? 1920.0 : 1080.0
        let screenSizeFactor = Double(screenSize) / baseScreenSize
        
        let screenSizeWeight = 0.1
        
        /// Apply screenSizeFactor
        
        maxSens = (maxSens * (1-screenSizeWeight)) + ((maxSens * screenSizeWeight) * screenSizeFactor)
    }
    
    /// vv Old screenSizeFactor formula
    ///     Replaced this with the new formula without in-depth testing, so this might be better
    
//    if screenHeightFactor >= 1 {
//        screenHeightSummand = 20*(screenHeightFactor - 1)
//    } else {
//        screenHeightSummand = -20*((1/screenHeightFactor) - 1)
//    }
//    maxSens += screenHeightSummand
    
    /// Get Curve
    /// - Not sure if 0.08 defaultEpsilon is accurate enough when we create the curve.
    
    let xMin: Double = 1 / Double(consecutiveScrollTickIntervalMax)
    let yMin: Double = minSens
    
    let xMax: Double = 1 / consecutiveScrollTickInterval_AccelerationEnd
    let yMax: Double = maxSens
    
    let curve = BezierCappedAccelerationCurve(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax, curvature: curvature, reduceToCubic: false, defaultEpsilon: 0.05)
    
    /// Debug
    
//    DDLogDebug("Recommended epsilon for Acceleration Curve: \(curve.getMinEpsilon(forResolution: 1000, startEpsilon: 0.02/*0.08*/, epsilonEpsilon: 0.001))")
    
    /// Return
    return curve
    
}
