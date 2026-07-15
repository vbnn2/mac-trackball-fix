# Plan: retarget the scroll engine + actions for the Kensington TB800

Companion to `DEVELOPING.md` (build/run/architecture). Everything below is grounded in the
live device dump and the actual code paths, with file:line references.

## Status [Jul 16 2026]

| # | Feature | State |
|---|---|---|
| 1 | Rewrite the scroll engine for the TB800 | ✅ done — rebuilt around a velocity model + 5 tuning sliders |
| 2 | Smooth horizontal scrolling | ❌ **dissolved** — the premise was false, see Measured |
| 3 | Invert zoom | ✅ done — `Scroll.invertZoom` + a toggle in the Scrolling tab |
| 4 | Shift + click action | ✅ done |
| 5 | Build/run script | ✅ done — `./dev.sh` |
| 6 | Export / import config | ✅ done — buttons in General ⚠️ round-trip never tested |
| 7 | About tab: version only | ✅ done — `FORCE_LICENSED` + header-only |
| 8 | **App-override config** | 📋 planned — see below |
| — | Scroll & Zoom Mode (latched trackball mode) | ✅ done — added mid-flight, not in the original plan |
| — | Enable/logging fixes | ✅ done — see `DEVELOPING.md` §5-6 |

**Open bugs:**
- ~~**"It sticks for a bit, then starts scrolling"** when resuming a scroll.~~ ✅ **fixed
  [Jul 16 2026]** — this was ours, not upstream's: the trailing-detent heuristic was eating the first
  1-2 ticks of any scroll resumed within 400ms (87 of 112 drops in a 1464-event capture). Removed.
  See Feature 1.
- **"Can't scroll until I move the cursor"**, usually after switching apps. A *known upstream*
  bug (`Scroll.m:37`, `DisplayLink.m:189` — "Scroll Stops Working Intermittently", Apr 2025),
  suspected to be a silent `CVDisplayLink` failure. Our angle: `Scroll.m:706` only re-links the
  animator's display when `ScrollUtility.mouseDidMove` — so a stale link stays stale until you
  move the pointer, which fits the symptom exactly. Needs a log capture while stuck: if
  `MFDELTA` lines appear but nothing scrolls, the input path is fine and the display link is the
  culprit.
  - Caveat we introduced: `updateMouseDidMoveWithEvent:` (`Scroll.m:372`) lives inside the
    `if (firstConsecutive)` block, and we raised `consecutiveScrollTickIntervalMax` to 500ms — so
    ticks within 500ms no longer refresh `mouseDidMove`, the display ID, or `_scrollConfig`.
    Shouldn't affect a fresh post-app-switch scroll, but it's a real change in that exact area.

---

## Measured [Jul 15 2026] — read this before the diagnosis below

346 real scroll events captured off the TB800 via temporary instrumentation at `Scroll.m:221`
(logged *before* the early-out, so passed-through events are included too). Slow ring, fast ring,
and the side scroller. This supersedes the inferences below where they conflict.

| Field | Vertical (big ring) | Horizontal (side scroller) |
|---|---|---|
| `isContinuous` | `0` for all 346 | `0` |
| `scrollPhase` | `0` for all 346 | `0` |
| `isDiagonal` | **`0` for all 346** | **`0`** |
| `DeltaAxis` (line) | **1 … 9** | 1 … 9 |
| `PointDeltaAxis` | **1 … 95** | 1 … 95 |
| events | 260 | 86 |

**1. `|delta| > 1` is CONFIRMED — Step 1.1 is real, not a dead end.** Line deltas reach 9,
point deltas reach 95. Only 35 of 260 vertical events were `|line| == 1`; the mode is `|line| == 9`
(91 events). The device is *not* a ±1-per-detent wheel.

**2. Rate does not saturate — but it badly under-represents velocity.** Report rate and magnitude
climb *together*. MMF's curve input (`1/timeBetweenTicks`) spans only ~10x while true scroll
velocity (`rate × |line|`) spans ~110x. **MMF compressed a ~110x velocity range into a ~10x curve
input.** That — not a saturating report rate — is the mechanism behind the "designed for a wheel"
feel. Diagnosis (a) is correct; its stated *reason* is not.

> ⚠️ **Correction [Jul 15 2026].** The "6.2 Hz" and "66.7 Hz" figures first recorded here were
> **not measurements** — they're clamp values, and reading them back as data caused several wrong
> turns:
> - **6.2 Hz = 1/0.160** — the *non-consecutive fallback*. Any tick arriving more than
>   `consecutiveScrollTickIntervalMax` after the last has its real interval **thrown away** and
>   replaced by that max. Every isolated tick therefore reports exactly `units/0.160`.
> - **66.7 Hz = 1/0.015** — the `CLIPLOW` ceiling (`consecutiveScrollTickInterval_AccelerationEnd`).
>   The fastest real gap logged was 7 ms (143 Hz), clipped away.
>
> Always check what a constant *is* before quoting a number off it. The magnitude finding
> (`|line|` 1…9) is real and unaffected.

**3. Use `DeltaAxis` (line), NOT `scrollDelta`, as the unit count.** `Scroll.m:218` reads
`scrollDelta` from `kCGScrollWheelEventPointDeltaAxis1`, and point delta is **already accelerated
by macOS**: a single `|line| == 1` report yields point deltas of 1, 3, 8, and 13 depending on how
fast you're spinning. Scaling output by `|scrollDelta|` (up to 95) therefore compounds macOS's
acceleration with MMF's own curve *and* the device magnitude. `DeltaAxis` (1…9) is the closer
proxy for the device's own unit count.
> Caveat: we can't tell from `CGEvent` alone whether `DeltaAxis` is raw HID counts or is itself
> lightly accelerated by IOHIDFamily. Confirming that needs an HID-level read
> (`IOHIDDeviceRegisterInputValueCallback`), which is out of scope for now.

**4. No diagonal events — (b) and Step 1.2 look unnecessary.** Zero of 346 events carried both
axes; 260 + 86 with no overlap. Despite Wheel and AC Pan sharing HID Report ID 1, macOS delivers
them as *separate* single-axis events, so the `isDiagonal` bail never fires and the `NSCAssert` is
not at risk. The side scroller already flows through the normal smoothed path — its deltas are
indistinguishable from the ring's.
> Open question: it's unconfirmed whether the capture included *simultaneous* ring + side-scroller
> use. Worth one more test before deleting Step 1.2 outright.

---

## The core diagnosis

Two early-outs and one design assumption in `Scroll.m` are why MMF feels wrong on a TB800.

> ⚠️ Measured [Jul 15 2026]: (a) holds but for a different reason than stated; (b) was **not
> observed at all**. See the measurement section above.

### (a) Scroll magnitude is thrown away — `Scroll.m:426-462`

This is the big one. In the default path (`useAppleAcceleration == false`):

```objc
double scrollSpeed = 1/timeBetweenTicks;            /// In tick/s   ← rate ONLY
pxToScrollForThisTick = [accelerationCurve evaluateAt:scrollSpeed];
```

`scrollDelta`'s **magnitude is never used**. It's consumed only to derive a *direction*
(`Scroll.m:397`), then `llabs`'d at line 409 and dropped. `ScrollAnalyzer` reinforces this —
`updateWithTickOccuringAt:direction:config:` takes a timestamp and a direction, and no
magnitude at all.

That's a correct model for a **notched wheel**, where every detent is exactly ±1 and the only
information is *how fast detents arrive*. It's wrong for the TB800: its Wheel field is 8-bit
(−127…127) and the free-spinning ring emits **multi-unit deltas**. Spin it fast and the device
says "+8"; MMF hears "one tick" and scrolls the same distance as "+1". Worse, the 2.4GHz
receiver caps report rate (~125 Hz), so the *only* signal MMF listens to saturates. That is
precisely the "designed for a wheel" feeling.

> **Note:** the premise that the TB800 does pixel-precise smooth scrolling is *not* what the
> hardware reports — it exposes **no Resolution Multiplier (GD 0x48)**, so macOS marks its
> events line-based (`kCGScrollWheelEventIsContinuous == 0`) and MMF's tap *does* process them.
> The smoothness is MMF's own animator plus a fine-grained ring. So this is a **tuning and
> magnitude problem, not a "MMF ignores my device" problem.** See `DEVELOPING.md` §7.

### (b) Diagonal events bypass MMF entirely — `Scroll.m:221-228`

```objc
bool isDiagonal = scrollDeltaAxis1 != 0 && scrollDeltaAxis2 != 0;
if (isPixelBased != 0 || scrollPhase != 0 || drawingTabletID != 0 || isDiagonal) {
    return event;                                   /// ← passed through RAW, unsmoothed
}
```

The TB800 carries **Wheel and AC Pan in the same HID report (ID 1)**, so one report can hold
both axes. Any diagonal report is handed to macOS untouched — no smoothing, no acceleration —
which reads as intermittent jank rather than a consistent miss.

### (c) One axis wins, and it's a hard assert — `ScrollUtility.m:156-166`

```objc
+ (MFAxis)axisForVerticalDelta:(int64_t)deltaV horizontalDelta:(int64_t)deltaH {
    NSCAssert(deltaV == 0 || deltaH == 0, @"Scroll event is not parallel to an axis.");
    ...
}
```

The whole pipeline downstream is **single-axis**: one `scrollDelta`, one `scrollDirection`, one
`ScrollAnalyzer` tick stream. Note the `NSCAssert` — it is currently unreachable *only* because
of the (b) early-out. **Delete the diagonal bail without addressing this and debug builds will
assert immediately.** These two must be changed together.

---

## Feature 1 — Rewrite the scroll engine for the TB800 ✅ done

Rebuilt around **true velocity**, and exposed as sliders rather than hardcoded curves.

### What shipped

**The model** (`Scroll.m`, acceleration block):

```objc
v         = smoothedUnits / timeBetweenTicks          /// units/s — TRUE velocity, not events/s
pxPerUnit = pxAtRefSpeed * pow(v/refSpeed, gamma-1)
px        = pxPerUnit * unitsForThisTick              /// capped at 12x pxAtRefSpeed
```

- **Units come from `kCGScrollWheelEventDeltaAxis1/2` (the LINE delta), never `scrollDelta`.**
  `scrollDelta` is the *point* delta, which macOS has already accelerated — a single `|line|==1`
  report was measured yielding point deltas of 1, 3, 8 and 13. The plan originally said to scale
  by `fabs(scrollDelta)`; that would compound macOS's acceleration with our curve *and* the device
  magnitude.
- **Units are smoothed on the same window as the interval.** `timeBetweenTicks` is a 3-tick
  rolling average (`ScrollAnalyzer.m:251`); dividing a raw per-event unit count by it mixes time
  bases and reads erratically during a decelerating spin. `ScrollAnalyzer` now averages units over
  the identical window (`unitsPerTick`) and resets both smoothers in lockstep.
- **Anchored at `refSpeed` (50 u/s), not at v=1.** This makes the two sliders orthogonal:
  `pxPerUnit == pxAtRefSpeed` at the pivot for *any* gamma, so Sensitivity sets the scale and
  Acceleration only tilts the curve. Anchored at v=1, changing Acceleration also changes how fast
  slow scrolling is, and the sliders fight each other.
- **Output is capped.** Upstream's acceleration curve was bounded; `pow()` isn't. `ScrollAnalyzer.m:45`
  documents that the input "sometimes randomly" delivers extremely small intervals, and says the
  reason that stopped mattering is that the curve's output was capped. Removing that safety net
  brings the quirk back.

**`consecutiveScrollTickIntervalMax`: 160ms → 500ms** (`trackballSlowScrollWindow`, plain scrolling
curves only). Measured: slow scrolling has a **260ms median gap**, and 34/35 gaps exceeded 160ms —
so *every tick of a deliberate slow scroll* was classified as a separate isolated scroll. All 36
ticks reported the same velocity (6.25 u/s) and the same distance (86px), and
`consecutiveScrollTickCounter` stayed 0, which makes `Scroll.m:715` zero `pxLeftToScroll` and
**hard-reset the animator on every tick**. Result: constant 86px lurches at irregular intervals,
an instantaneous rate swinging 76…859 px/s. That was the "slow scroll stutters".
160ms is right for a notched wheel; a free-spinning ring at reading speed is simply sparser.

**`animationTickStart` (160ms) decoupled from that window.** They were the same constant but answer
different questions. Left coupled, raising the window re-anchors the duration curve and a 260ms tick
gets a *shorter* animation — backwards.

**Trailing-detent suppression — built, then REMOVED [Jul 16 2026]. Don't rebuild it.**

The symptom was real: a settling ring emits one last 1-unit tick a few hundred ms after a spin;
being past the window it counted as a fresh scroll and got a full animation (measured: 267ms later,
a discrete 73px with its own 211ms animation) — the "pause, then it scrolls a bit more", and when
the ring settles *backwards*, the "it scrolls up a bit after I stop".

Two heuristics were tried and both failed:
1. A sentinel test on `consecutiveScrollTickIntervalMax`. Died when that window was raised to 500ms —
   the sentinel only existed *because* the 160ms clamp flattened every isolated tick to 6.25 u/s.
2. A deceleration test (lone ≤1-unit tick, 160-400ms after a tick ≥4x faster). Replaying saved
   captures showed it dropping exactly the right ticks with zero false positives — **and it was still
   wrong.**

**Why it can't work.** Measured over 1464 live events, it dropped 112 ticks of which **87 were the
first tick of a *resumed* scroll**, each followed by 8-11 more events within 500ms. Felt as: "it
sticks for a bit, then starts scrolling." Because `_lastProcessedTickTime` isn't advanced on a
suppression, the *second* tick often died too.

A settling detent and the first tick of a resumed scroll are **identical at the moment they arrive**.
They differ only in what comes *after*, and an event tap cannot see the future. The gap distributions
overlap completely — wrongly-dropped scroll-starts at 179-354ms vs real detents at ~260ms — so no
timing window separates them. Any future attempt would need to *delay* the first tick to see whether
another follows, i.e. trade a guaranteed input latency for a cosmetic fix.

**And it became unnecessary anyway.** It was designed when one unit was a 73-86px lurch. At the tuned
default `sensitivity: 0.10` a detent is **~14px** — versus ~15.7px for a deliberate notch. Lowering
sensitivity solved the problem at its source; the heuristic was curing a symptom that no longer
existed while doing 3.5x more harm than good.

> **Lesson:** replaying a saved capture validated a rule that live use disproved. The captures only
> contained spins that *ended*; they had no examples of a scroll being *resumed*, so the false-positive
> case was literally absent from the test data. Passing a replay is not evidence when the replay can't
> contain the failure mode.

### The sliders (Scrolling tab)

| Slider | Drives | Default |
|---|---|---|
| Sensitivity | `pxAtRefSpeed` (10…150 px/unit) | 0.10 |
| Acceleration | `gamma` (0.4…1.2; 1.0 = linear, >1 accelerates) | 1.0 |
| Smoothness | scales `baseMsPerStepCurve` (0.4…1.6x) | 0.5 |
| Glide | `dragCoefficient` (40 abrupt … 5 floaty) | 0.75 |
| Fast Scroll | scales `exponentialSpeedup` (0 = off/nil) | 0.67 |

Defaults [Jul 16 2026] are hand-tuned on the TB800. The shape: **very low base sensitivity** so slow
scrolling moves in ~14px steps rather than 86px lurches, with **strong acceleration + fastScroll** to
win the distance back on a fast spin.

⚠️ Defaults live in **three** places that must agree — `default_config.plist`, `ScrollConfig`'s
`slider()` fallbacks, and `ScrollTabController`'s spec table. The plist alone is not enough: it only
seeds *fresh* configs (see the configVersion note under Feature 3), so the code fallbacks are what
actually run for any pre-existing config.

Smoothness/Glide deliberately skip the effect-mod curves (TouchDriver, TouchDriverLinear,
PreciseScroll, QuickScroll) — those are zoom/rotate/precise, which upstream tuned deliberately.

### Still open

- Slow scrolling is *better*, not perfect. px is now small so steps are subtle, but ~5 ticks/second
  with irregular gaps is inherently discrete. Smoothness is the lever that bridges them.
- The `MFDELTA` trace is kept permanently (`Scroll.m`) — `DDLogDebug`, so free unless streaming.
  Every fix here came out of it.

---

## Feature 2 — Smooth horizontal scrolling ❌ dissolved

**The premise was false.** The plan assumed the TB800's Wheel and AC Pan share HID Report ID 1, so
one report could carry both axes, trip the `isDiagonal` early-out, and get passed through raw.

**Measured: 0 diagonal events out of 346** (260 vertical + 86 horizontal, no overlap) — logged
*before* the early-out precisely so passed-through events would appear. macOS delivers the two axes
as separate single-axis events. So the `isDiagonal` bail never fires, the `NSCAssert` in
`ScrollUtility.m` is not at risk, and **Step 1.2 (dominant-axis / 2-axis rewrite) was never needed**.

The side scroller already flows through the normal smoothed path — its deltas are indistinguishable
from the ring's (`|line|` 1…9, `|point|` 1…95).
---

## Feature 3 — Invert zoom ✅ done

Shipped as `Scroll.invertZoom` + an **Invert Zoom Direction** checkbox under Reverse Direction in the
Scrolling tab. The negation sits immediately after `eventDelta` is computed and **before** the
Chromium hack, as planned — that block adds asymmetric sign-dependent offsets (`+380/800` vs
`-250/800`), so negating after it makes Chrome zoom lopsided.

> ⚠️ **The plan's config step was a landmine.** It said to add the key to `default_config.plist` and
> read it with `c("invertZoom") as! Bool` like the settings around it. That would have **crash-looped
> the Helper**: `_loadAndRepair` (`Config.m:439`) is a configVersion *migration*, not a key-merger —
> when the versions match (both 24) it takes the `dontReplace` path and adds no keys. And the Helper
> never repairs at all (`loadConfigFromFile` only calls `_loadAndRepair` `#if IS_MAIN_APP`), it reads
> the plist raw. So adding a key to the defaults does nothing for existing configs, and `as!` force-
> unwraps nil. **Every new config key in this fork must be read nil-tolerantly** —
> `(c("key") as? T) ?? default` — and `configVersion` is deliberately not bumped (that triggers the
> migration/replace paths, and `Config.m` documents a whole class of "config reset after update" bugs
> there).

<details>
<summary>Original plan (for reference)</summary>

**Site:** `Scroll.m:1150`

```objc
double eventDelta = (dx + dy)/800.0;
```

then `[TouchSimulator postMagnificationEventWithMagnification:eventDelta phase:eventPhase]`
(line 1187).

**Why a separate toggle is needed:** `dx`/`dy` derive from `scrollDirection`, which already had
`u_invertDirection` (`Scroll.m:320`, config key `Scroll.reverseDirection`, currently `true`)
applied. So zoom direction is *coupled* to scroll direction today — you cannot invert one
without the other. That coupling is the actual feature request.

**Steps:**

1. `Shared/Config/default_config.plist` → add `Scroll.invertZoom` (Bool, default `false`).
2. `ScrollConfig.swift` (next to `u_invertDirection`, line 263) → add
   `@objc lazy var u_invertZoom: Bool = { c("invertZoom") as! Bool }()`.
3. `Scroll.m:1150` → `if (config.u_invertZoom) eventDelta = -eventDelta;`
   `sendOutputEvents(...)` already receives `config` as a parameter (`Scroll.m:880`), so no
   plumbing needed.
4. Apply the negation **before** the Chromium hack at lines 1155-1185 — that block adds
   asymmetric sign-dependent offsets (`+380/800.0` vs `-250/800.0`), so negating after it
   would apply the wrong branch's correction and make Chrome zoom lopsided.

Optionally expose it in the app's Scroll tab; a config-file-only toggle is fine to start.

</details>

---

## Feature 4 — Shift + click action ✅ done

Implemented and confirmed working in the UI [Jul 15 2026]. Shipped as
`kMFActionDictKeyMouseButtonClicksVariantModifierFlags` (`Constants.h`) →
`postMouseButtonClicks:nOfClicks:modifierFlags:` (`ModificationUtility.m`) → `Actions.m:167` →
a **"Shift + Primary Click"** entry in `RemapTableTranslator.m` + `effect.click.primary.shift`
strings. Generalizes for free: the same `flags` key gives Cmd+click, Opt+click, etc.

Three things worth remembering, all found during implementation:

- **The `flags` key is optional, and must stay optional.** `RemapTableTranslator.m:429` matches
  stored effect dicts to menu rows with `isEqualToDictionary:`. Adding `flags: @0` to the
  existing Primary/Secondary/Middle entries would stop them matching configs saved by earlier
  versions — those buttons would silently read as unset.
- **`"hideable": @YES` does not mean "can be hidden".** `menuItemFromDataModel:` (~line 605)
  implements it as an **⌥-alternate**: the entry is invisible unless Option is held. That's how
  the plain click actions are tucked away. The Shift entry deliberately omits it. (If you ever
  want Primary/Secondary/Middle Click visible by default, that's a one-line removal each.)
- **Still unverified:** whether target apps honor a Shift flag set on the *mouse* event. Works
  for apps reading `NSEvent.modifierFlags` (Finder-style range-select); apps polling
  `CGEventSourceKeyState` (Electron, games) won't see it. Fallback if one misbehaves: synthesize
  a real Shift `keyDown` → click → `keyUp`, which is more invasive and can leak modifier state
  if interrupted.

<details>
<summary>Original plan (for reference)</summary>

Today `kMFActionDictTypeMouseButtonClicks` carries only a button number and click count
(`Constants.h:198-199`), and `postMouseButtonClicks:nOfClicks:`
(`ModificationUtility.m:154-182`) posts events with **no modifier flags**.

**Steps:**

1. **`Shared/Constants.h`** → add alongside line 199:
   ```objc
   #define kMFActionDictKeyMouseButtonClicksVariantModifierFlags  @"flags"
   ```
2. **`ModificationUtility.h/.m:154`** → add
   `postMouseButtonClicks:nOfClicks:modifierFlags:`, calling `CGEventSetFlags()` on both
   `buttonDown` and `buttonUp` before posting. Keep the existing 2-arg method delegating with
   flags `0` so the ~3 existing call sites (incl. `Actions.m:123-124`) are untouched.
3. **`Helper/Core/Actions/Actions.m:167-171`** → read the flags key (defaulting to 0) and pass
   it through.
4. **`App/UI/.../RemapTableTranslator.m:174-200`** → add an effects-table entry. The table is a
   plain declarative array, so this is genuinely just:
   ```objc
   @{@"ui": MFLocalizedString(@"effect.click.primary.shift", @""),
     @"dict": @{
        kMFActionDictKeyType: kMFActionDictTypeMouseButtonClicks,
        kMFActionDictKeyMouseButtonClicksVariantButtonNumber: @1,
        kMFActionDictKeyMouseButtonClicksVariantNumberOfClicks: @1,
        kMFActionDictKeyMouseButtonClicksVariantModifierFlags: @(kCGEventFlagMaskShift),
     }},
   ```
5. **`Localization/Localizable.xcstrings`** → add the `effect.click.primary.shift` string.

**The known risk — and the reason to build this one first:** setting flags on the *mouse* event
works for AppKit apps that read `NSEvent.modifierFlags` off the event (that covers Finder-style
range-select, most native lists). But apps that poll **global** keyboard state
(`CGEventSourceKeyState`) — common in Electron, games, and some cross-platform toolkits — will
not see the Shift. If a target app misbehaves, the fallback is to synthesize a real Shift
`keyDown` → click → `keyUp` around the click, which is more invasive and can leak modifier
state if the sequence is interrupted. **Test against your actual target apps early**, since
this determines which implementation you need.

Generalizes for free: the same flags key gives Cmd+click, Opt+click, etc.

</details>

---

## Feature 5 — Build/run script ✅ done

`./dev.sh` is written and **verified working**. See `DEVELOPING.md` §1-2. Commands: `build`,
`run`, `app`, `test`, `install`, `logs`, `logs-dump`, `stop`, `clean`.

`logs`/`logs-dump` were rewritten once we learned how MMF logging actually works (the
CocoaLumberjack path is dead code; everything goes to `OS_LOG_DEFAULT` with no subsystem).
See `DEVELOPING.md` §5 — the naive predicate returns an empty stream, or worse, upstream MMF's logs.

---

## Feature 6 — Export / import config in General ✅ done ⚠️ untested

Shipped as **Export Settings… / Import Settings…** at the bottom of the General tab (appended to
`masterStack`, not `mainHidableSection`, so they stay reachable while MMF is disabled). Import
validates with `PropertyListSerialization` and backs up to `config.backup.plist` before replacing.

**⚠️ The round-trip has never actually been exercised.** Worth doing: export → change a setting →
import → confirm the setting reverts *and* the Helper picks it up without a restart. That last part
is the fragile bit — see risk 1.

**Two traps this hit, both worth remembering:**
- **Writing the config file is not enough.** The FSEventStream that would auto-reload external edits
  is **disabled** (`Config.m:262` is `#if 0` — it broke addMode). Import must explicitly call
  `Config.loadFileAndUpdateStates()` *and* message `configFileChanged`, or the Helper keeps running
  the old remaps until it restarts.
- **`CollapsingStackView` overrides `arrangedSubviews`** to unwrap its `NoClipWrapper`s
  (`Collapse.swift:140`), so a view read back from it may not be the real arranged subview that
  `setCustomSpacing(_:after:)` requires — that throws. Pad via the row's own `edgeInsets` instead.

<details>
<summary>Original plan (for reference)</summary>

**Goal:** a pair of buttons in the General tab that write the current config to a file the user
picks, and load one back.

### What already exists

- The config is a single plist at
  `~/Library/Application Support/com.pixeption.mac-mouse-fix/config.plist` — path assembled in
  `Config.m:82-84` (and `Locator.m:97-98` → `Locator.configURL`) from `kMFBundleIDApp`. Since
  it's one self-contained file, export is genuinely just a file copy.
- `commitConfig()` (`Config.h:35`, `Config.m:123-137`) is the "config changed" pathway:
  `writeConfigToFile` → `MFMessagePort sendMessage:@"configFileChanged"` → `updateDerivedStates`.
- `+[Config loadFileAndUpdateStates]` (`Config.m:142-149`) is the reverse: `loadConfigFromFile` →
  `updateDerivedStates`.
- `loadConfigFromFile` calls **`_loadAndRepair`** in the main app (`Config.m:416-424`, impl at
  `:439`), which repairs a config against `default_config.plist`
  (`Contents/Resources/default_config.plist`, `Config.m:118`). This is a gift for import: a
  foreign, older, or partial config gets healed rather than breaking the app.

### Steps

1. **`GeneralTabController.swift`** → two `@IBAction`s, plus buttons in the General scene of
   `Main.storyboard` (lines 391-664). Model them on the existing toggles (outlets at lines 30-43).
2. **Export:** `NSSavePanel` → copy `Locator.configURL` to the chosen URL. Call `commitConfig()`
   first so unsaved UI state is flushed to disk before copying. Suggested default filename
   something like `mac-trackball-fix-config.plist`.
3. **Import:** `NSOpenPanel` (restrict to `.plist`) → **validate before overwriting** (see risks)
   → copy over `Locator.configURL` → `[Config loadFileAndUpdateStates]` →
   `[MFMessagePort sendMessage:@"configFileChanged" withPayload:nil waitForReply:NO]` to tell the
   Helper.
   - `loadFileAndUpdateStates` may not be declared in `Config.h` (only `loadConfigFromFile` is at
     `:29`) — expose it, or call `loadConfigFromFile` + `updateDerivedStates`.
4. **Localization:** add `general.export` / `general.import` strings to `Localizable.xcstrings`.
   Insert alphabetically and keep the file valid — see the note under Feature 7.

### Risks

1. **Writing the file is not enough — nothing will notice.** The FSEventStream that used to
   auto-reload on external edits is **disabled**: `Config.m:262` is `#if 0` ("Disable for now",
   it broke addMode). So import *must* explicitly reload and message the Helper. Don't assume the
   file-watcher will pick it up; it won't.
2. **Validate before you clobber.** Import overwrites the user's live config. Parse the candidate
   with `NSDictionary dictionaryWithContentsOfURL:` and reject non-dictionaries / unparseable
   plists *before* touching `Locator.configURL`. `_loadAndRepair` heals a *structurally valid*
   config; it isn't a defense against arbitrary files. Consider backing up the current config
   next to it first.
3. **A config carries licensing cache.** `GetLicenseState.swift` caches license state in config
   (`deleteLicenseStateFromCache(commitConfig:)`, `:196`/`:231`) and validates it to resist
   hand-editing (`:170`). Importing someone else's config therefore drags their license cache
   along. Mostly moot if Feature 7's `FORCE_LICENSED` lands (the override at `:143` short-circuits
   before the cache), but worth knowing if the two features are ever separated.
4. **Don't hand-roll the sync.** Use `commitConfig()` / `loadFileAndUpdateStates` rather than
   writing the plist directly, or the Helper keeps running the old remaps until restart.

</details>

---

## Feature 7 — About tab: version only ✅ done

Shipped: `FORCE_LICENSED` on both targets + the About tab stripped to its header row (app name, icon,
version, attribution). Verified at runtime — `GetLicenseState.get()` returns
`licenseTypeInfo: <MFLicenseTypeInfoForce>`, which matters because this machine is in a **freeCountry**
and would report `isLicensed: 1` either way; only the `Force` type proves the flag fired.

**Gotcha:** hiding the rows blew the window to **99999pt wide**. `TabViewController.resizeWindowToFit`
(`:551-566`) measures a tab by temporarily setting the window to 99999×99999 and reading the frame
back; the About tab's width was pinned by the widest `LinkRow`, and the header's content is
centre-aligned and constrains nothing. Fixed with an explicit width constraint. **That 99999 probe
claimed a second victim** in the General tab (a code-built row with default hugging got stretched to
99999pt *tall*) — any view added programmatically to a `distribution=fill` stack here needs
`setHuggingPriority`/`setContentHuggingPriority` set, or the tab measures as nonsense.

**Goal:** no pay button, no trial section, no links. Just the version.

### The important part: do NOT just hide the pay button

`License.checkAndReact` (`License.swift:33-70`) is what "**locks down the helper**" (its own
words, `:37`) once the trial expires. It early-returns *only* when `licenseState.isLicensed`
(`:47-50`). Hiding the pay UI does nothing to that check — you'd get an app that locks itself
down on trial expiry **and no longer offers any way to unlock it**. Strictly worse than today.

So the licensing state must be fixed first; the UI cleanup is cosmetic follow-up.

### There's already a supported switch for this

`GetLicenseState.swift:140-145`:

```swift
#if FORCE_LICENSED
return MFLicenseState(isLicensed: true, freshness: kMFValueFreshnessFresh, licenseTypeInfo: MFLicenseTypeInfoForce())
#endif
```

It's a documented, first-class flag (`License.swift:12-16`, alongside `FORCE_EXPIRED` /
`FORCE_NOT_EXPIRED`), and it's checked in `licenseStateFromOverrides()` *before* any cache or
network path. With it set:

- `AboutTabController.updateUI_WithIsLicensedTrue` (`:167`) runs, so
  `updateUI_WithIsLicensedFalse` (`:346`) never executes — and that's the **only** place the
  `PayButton` is constructed (`:424`, wired to `LicenseUtility.buyMMF` at `:425`). The pay button
  stops existing rather than being hidden.
- `License.checkAndReact` returns at `:47` → no lockdown, no trial notifications from the Helper
  (`Helper/UI/TrialNotifications/TrialNotificationController.swift`).
- No licensing network requests.

### Steps

1. **Set `FORCE_LICENSED`** in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for **both** the app and
   Helper targets (`project.pbxproj` — app configs at ~8947/8989, Helper nearby; the existing
   values look like `"$(inherited) IS_MAIN_APP"`). Note `License.swift:16`: **clean the build
   folder** after changing the flag or it won't take effect.
2. **Suppress the FORCE_LICENSED banner.** `AboutTabController.swift:255-258` prints
   *"The app will appear to be licensed due to the FORCE_LICENSED flag"* into the money cell for
   `MFLicenseTypeInfoForce`. That's a debug affordance and directly contradicts "version only" —
   hide `moneyCell` / `moneyCellLink` / `moneyCellImage` (outlets at `:20-22`) instead.
3. **Hide the rest in `viewDidLoad`** (`:80-128`) rather than deleting from the storyboard —
   keeps the diff small and upstream merges cheap. Targets: `trialSectionContainer` (`:26`),
   and the `Hyperlink` text fields in the About scene (`Main.storyboard` lines 1919-2639):
   Submit Feedback, Check It Out on GitHub, Help Translate, Visit the Website, Send Me an Email
   (wired to `sendEmail:`, `AboutTabController.swift:40`), Get Help, Acknowledgements, and
   Buy Me a Milkshake (`moneyCellLink`).
   - Most of those have no outlets — add them, or give the enclosing stack view one outlet and
     hide it wholesale. Prefer the latter if the layout allows.
4. Keep `versionField` (`:18`, storyboard id `7TJ-vr-aAK`) and its `app-version` formatting
   (`:95-98`) exactly as-is.

### Risks

1. **`trialSectionContainer` has a hard-coded 400pt min-width constraint** (`:108`) and
   `TrialSectionManager` is initialized against `trialCell` at `:102` — both run in `viewDidLoad`
   regardless of license state. Hiding the container without addressing the constraint may leave
   the tab oddly wide. Check whether the parent stack view uses `detachesHiddenViews`
   (the storyboard sets it on some stacks) — if not, hidden views still occupy space.
2. **`updateUIToCurrentLicense()` re-runs on every `viewDidAppear`** (`:132-140`), so anything
   hidden once in `viewDidLoad` can be un-hidden by a later update pass. `:197-198` explicitly
   un-hides `moneyCellLink`. Hide at the end of the update path, not only at load.
3. **Licensing, honestly:** the MMF License permits doing anything with the source **privately**;
   its restrictions bite on *publishing a compiled program* (`DEVELOPING.md` license note). This
   fork is private and `FORCE_LICENSED` is upstream's own flag, so this is fine as-is — but it is
   exactly the thing that must not ship. If this is ever published, re-read `License` first.

---

## Feature 8 — App-override config

**Goal:** per-app settings — e.g. a different scroll speed in Xcode than in Safari, or a button that
does one thing in Chrome and another everywhere else.

### Most of this already exists and is half-wired

MMF 2 had app-specific settings. MMF 3 dropped the *feature* but kept the *machinery*, and one part
of it is still live:

- **`kMFConfigKeyAppOverrides`** = `@"AppOverrides"` (`Constants.h:122`). The shape is
  `config[AppOverrides][<bundleID>]["Root"]` → a partial config tree.
- **`-[Config loadOverridesForApp:]`** (`Config.m:215`) looks that up and merges it over the base
  config with `+[SharedUtility dictionaryWithOverridesAppliedFrom:to:]` (`SharedUtility.h:68`),
  storing the result in **`configWithAppOverridesApplied`** (`Config.h:46`).
- **`-[Config loadOverridesForAppUnderMousePointerWithEvent:]`** (`Config.m:181`) resolves the app
  under the pointer and calls the above, but only when the bundleID actually changed.
- **`PointerConfig.swift:50` already reads `configWithAppOverridesApplied`** — so pointer settings
  would honour overrides *today* if anything populated the key.
- There's even a dormant UI: `App/UI/Unused/Overrides/OverridePanel.m` + `ScrollOverridePanel.xib`.

So this is less "build a feature" and more "re-connect three wires".

### What's actually missing

1. **Nothing calls the resolver.** `Scroll.m:375` is `if ((NO)) { ... }` — literally disabled with
   the comment *"Unused in MMF 3"*. That block is what calls
   `loadOverridesForAppUnderMousePointerWithEvent:` and `resetState_Unsafe()` on change.
2. **`ScrollConfig` reads the wrong config.** `ScrollConfig.swift:47` does `config("Scroll")`, which
   is the *base* config — not `configWithAppOverridesApplied`. Same for `GeneralConfig`. Only
   `PointerConfig` uses the override-applied one. So even with the key populated, scroll settings
   would ignore it.
3. **No `AppOverrides` key** in `default_config.plist` (top-level keys are Scroll, License, General,
   Pointer, Remaps, State, Constants).
4. **No UI.**

### Steps

1. **Populate the key by hand first.** Add an `AppOverrides` dict to your config with one app and
   one obviously-visible override (e.g. `Scroll.tuning.sensitivity`), and confirm the merge works
   before touching any UI. This is a config-file-only feature until it's proven.
2. **Re-enable the resolver** at `Scroll.m:375`: drop the `if ((NO))`. Note it's inside the
   `if (firstConsecutive)` block and gated on `mouseDidMove || frontMostAppDidChange` — with
   `consecutiveScrollTickIntervalMax` now at 500ms, that block runs less often than upstream
   assumed (see Open Bugs).
3. **Point `ScrollConfig` at `configWithAppOverridesApplied`** instead of `config("Scroll")`, and
   make sure `ScrollConfig.reload()`'s equality check still fires when only the override changes.
4. **UI** — likely a table of `bundleID → overridden keys` in a sheet. `OverridePanel.m` is a
   starting reference, but it's MMF 2-era and unused; expect to rewrite rather than revive.

### Risks

1. **"App under the pointer" ≠ "frontmost app".** `loadOverridesForAppUnderMousePointerWithEvent:`
   keys off the *pointer*, which is right for scrolling (you scroll what you point at) but wrong for
   buttons/keyboard. Don't assume one resolver fits all triggers.
2. **This runs on every scroll tick.** The resolver calls `HelperUtility appUnderMousePointer`, which
   is an AX/CG lookup — that's why upstream gated it behind `mouseDidMove || frontMostAppDidChange`.
   Calling it unguarded on the scroll hot path will cost real latency.
3. **`resetState_Unsafe()` on every app change** means scroll momentum dies when you cross a window
   boundary mid-scroll. Upstream did this deliberately (config changed → state is invalid), but it
   will be felt on a free-spinning ring where momentum is long.
4. **Overrides are a partial tree merged over the base**, so `repairIncompleteAppOverrideForBundleID:
   relevantKeyPaths:` (`Config.h:38`) exists to heal them. Any UI must produce trees that survive
   that, and the configVersion migration will not backfill new keys into existing overrides (see
   Feature 3's note) — an override written today keeps working, but won't gain new keys.
5. **`PointerConfig` already honours overrides.** The moment the key is populated, pointer settings
   start reacting — possibly before you've built any UI to see or unset them.

---

## Buttons not recognized

`kMFMaxButtonNumber` is **32** (`Constants.h:303`), so MMF has no low button cap — unrecognized
TB800 buttons are a HID-reporting quirk, not an MMF limit. Your **Karabiner** workaround is the
right layer: it sits upstream of MMF's event taps, so MMF sees the already-remapped buttons and
they'll work with all of the above, including Feature 4. No MMF-side work needed.

---

## Cross-cutting risks

1. **No tests, no safety net — but there IS a measurement loop, and it works.** Every scroll fix in
   this fork came from capturing real events and replaying them, not from reasoning:

   ```bash
   ./dev.sh logs > /tmp/spin.log     # in a spare tab; scroll; Ctrl-C
   grep -E "MFDELTA|tuning v=" /tmp/spin.log
   ```

   `MFDELTA` gives raw input (line/point deltas, phase, diagonal); `tuning v=` gives what the engine
   made of it (velocity, units, dt, px). **Capture before theorising.** Guesses that the data killed:
   "the ring jitters backwards" (0 short runs in 13 direction runs), "random short gaps spike the
   acceleration" (0 caps hit; px climbed monotonically), and two of the constants quoted as
   measurements were clamp values. Replaying a saved capture against a proposed rule — before
   shipping it — caught a threshold that was 25 u/s when it needed to be 7.5.
2. **Feel is the only acceptance test.** The numbers confirm a mechanism fires; they say nothing
   about whether it feels right. Keep a checklist: slow spin, fast spin, the spin *tail*, horizontal,
   zoom (⌃+scroll), Scroll & Zoom Mode, and clicking (MB1/MB2 especially — see Feature 8's neighbours
   in `HelperState`, where a stuck tap once ate every click).
2. **SteerMouse is installed and launchd-registered** (`jp.plentycom.boa.SteerMouse`). It has
   its own event taps and is a prime suspect for confusing scroll results. **Quit it before
   testing** or you'll debug the wrong driver.
3. **Two Kensington devices are connected** (TB800 + SlimBlade Pro, `DEVELOPING.md` §7). They
   have different scroll hardware. `HelperState.shared.updateActiveDeviceWithEvent:` tracks the
   active device — make sure you know which one you're testing.
4. ~~**Bundle ID drift** is latent, not fatal.~~ **Wrong — it was fatal, and it's now fixed.**
   The `com.nuebling.*` constants made `FileMonitor` resolve the main app to nil and call
   `uninstallCompletely()`, so the Helper disabled itself on every rebuild. That was the
   "can't enable it" bug. See `DEVELOPING.md` §6. Nothing to do here beyond staying aware that
   `Constants.h` must track `PRODUCT_BUNDLE_IDENTIFIER`.
5. **Upstream merges just got more expensive.** `Scroll.m` is upstream's most actively developed
   file, and this fork now replaces its acceleration block outright, changes
   `consecutiveScrollTickIntervalMax`, adds a param to `ScrollAnalyzer`, and post-processes
   `animationCurveParams`. Every fork change in there is comment-marked `Fork:` — keep it that way.
6. **The same constant often serves two masters.** Repeatedly the cause of trouble here:
   `consecutiveScrollTickIntervalMax` was both "is this the same scroll" *and* the animation-duration
   anchor (now split via `animationTickStart`); `MFScrollAnimationCurveParameters` has two
   initialisers where the `justBaseCurve` one fills drag fields with `-1` sentinels that the full one
   treats as real values (this broke zoom). Before reusing a constant, check what else reads it.
7. **Config defaults live in three places** (`default_config.plist`, `ScrollConfig`'s `slider()`
   fallbacks, `ScrollTabController`'s spec table) and must be changed together. The plist alone only
   seeds *fresh* configs.
