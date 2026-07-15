# Plan: retarget the scroll engine + actions for the Kensington TB800

Companion to `DEVELOPING.md` (build/run/architecture). Everything below is grounded in the
live device dump and the actual code paths, with file:line references.

**Status:** 4 ✅ · 5 ✅ · remaining: 7 → 3 → 6 → 1 (→ 2 probably unnecessary — see the
measurement below).

**Suggested order:** 7 first (it's a build-flag change plus hiding views, and `FORCE_LICENSED`
also stops the trial clock quietly locking down the Helper mid-scroll-work). Then 3 (small,
self-contained). Then 6. Then 1, the risky one. Feature 2 is mostly dissolved by the
measurements — read those before planning it.

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
climb *together*:

| `\|line\|` | median gap | implied rate | median `\|point\|` |
|---|---|---|---|
| 1 | 161 ms | 6.2 Hz | 1 |
| 8 | 29 ms | 34.5 Hz | 87 |
| 9 | 15 ms | 66.7 Hz | 93 |

Fastest gap seen: 7 ms (143 Hz — no ~125 Hz cap observed). So MMF's curve input
(`1/timeBetweenTicks`) spans only ~10x (6→67 Hz), while true scroll velocity (`rate × |line|`)
spans ~97x (6 → 600 units/s). **MMF compresses a ~97x velocity range into a ~10x curve input.**
That — not a saturating report rate — is the measured mechanism behind the "designed for a wheel"
feel. Diagnosis (a) is correct; its stated *reason* is not.

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

## Feature 1 — Rewrite the scroll engine for the TB800

**Goal:** ring velocity, not report rate, drives scroll distance.

### Step 1.1 — Make magnitude flow through the pipeline

Thread `|scrollDelta|` into the tick as a unit count.

- `ScrollAnalyzer.h/.m`: add `units:` to `updateWithTickOccuringAt:direction:config:`, and
  accumulate units alongside ticks.
- `Scroll.m:426-462`: change the speed basis from ticks/s to **units/s**:

  ```objc
  double scrollSpeed = fabs(scrollDelta) / timeBetweenTicks;   /// units/s
  pxToScrollForThisTick = [accelerationCurve evaluateAt:scrollSpeed] * fabs(scrollDelta);
  ```

  Pick **one** of the two (curve-input change vs. output scaling) to start — doing both
  double-counts magnitude and will feel wildly over-accelerated. Recommendation: start with
  output scaling (`* |delta|`), because it leaves the existing curve's shape and tuning intact
  and is trivially revertible.

- **Guard the notched case.** The SlimBlade Pro is also on this machine and *does* send ±1
  per detent. Scaling by `|delta|` is a no-op for ±1, so both devices coexist — verify rather
  than assume.

**Risk:** `accelerationCurve` is defined over a tick/s domain
(`consecutiveScrollTickInterval_AccelerationEnd`, etc., `ScrollConfig.swift:858+`). Changing
the curve's *input* domain to units/s silently invalidates that tuning. This is the main
argument for the output-scaling approach first.

### Step 1.2 — Handle both axes

Choose one:

- **(A) Dominant-axis** *(recommended first)*: replace the `isDiagonal` bail with picking the
  larger-magnitude axis and zeroing the other. Small, local, keeps the single-axis pipeline and
  the `ScrollAnalyzer` model intact. Fixes the passthrough jank. Cost: a true diagonal gesture
  gets quantized to one axis — on a trackball ring that's usually what you want anyway.
- **(B) Full 2-axis**: two `ScrollAnalyzer` instances and two animators. Correct, much larger,
  touches state reset, momentum, and the `_modifications` logic. Only worth it if (A) feels bad.

Either way, relax the `NSCAssert` in `ScrollUtility.m:158`.

### Step 1.3 — Retune

`ScrollConfig.swift` (`speed`, `smooth`, `precise`) is tuned for detents. Expect to retune
after 1.1. `DevToggles.h` (`MF_TEST` + `devToggles_C/_Lo/_Hi`) exists exactly for live-tuning
constants without a rebuild — use it.

### Verify

No test suite exists (`DEVELOPING.md` §3), so this is empirical:
`./dev.sh run`, then compare slow vs. fast ring spins in Safari/Xcode. `Scroll.m` already
`DDLogDebug`s the acceleration curve evaluation and the sending device name per event.

**Before writing any code, log the real deltas.** Everything above rests on the TB800 emitting
`|delta| > 1`. That's inferred from the 8-bit report field, not yet observed. Add a temporary
log of `scrollDeltaAxis1/Axis2` at `Scroll.m:218` and spin the ring. **If deltas are always ±1,
Step 1.1 is pointless** and the real work is Step 1.3 tuning alone. This one measurement
decides how much of this feature is even real — do it first.

---

## Feature 2 — Smooth horizontal scrolling

**This is mostly already implemented.** Worth correcting the assumption up front: horizontal
input is *not* unsmoothed by design. The pipeline is axis-agnostic — `inputAxis ==
kMFAxisHorizontal` (`Scroll.m:302`) flows through the same analyzer, acceleration curve, and
animator as vertical, and `ScrollConfig.swift:888` already picks display *width* for horizontal
acceleration scaling.

Horizontal feels unsmoothed because of **(b)**: the TB800's AC Pan shares a report with Wheel,
so horizontal-ish input frequently trips `isDiagonal` and gets passed through raw.

➡️ **Feature 2 is largely a consequence of Step 1.2.** Do that first, then re-evaluate. Likely
remaining work afterwards:

- Confirm `kMFScrollEffectModificationHorizontalScroll` (Shift+scroll, `modifiers.horizontal =
  131072` = Shift) and *native* AC Pan produce consistent feel — they take slightly different
  paths (the modifier flips direction on a vertical input; native pan sets `inputAxis`).
- Possibly a separate horizontal speed factor in `ScrollConfig`.

---

## Feature 3 — Invert zoom

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

## Feature 6 — Export / import config in General

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

---

## Feature 7 — About tab: version only

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

## Buttons not recognized

`kMFMaxButtonNumber` is **32** (`Constants.h:303`), so MMF has no low button cap — unrecognized
TB800 buttons are a HID-reporting quirk, not an MMF limit. Your **Karabiner** workaround is the
right layer: it sits upstream of MMF's event taps, so MMF sees the already-remapped buttons and
they'll work with all of the above, including Feature 4. No MMF-side work needed.

---

## Cross-cutting risks

1. **No tests, no safety net.** Every change here is verified by feel. Consider capturing a
   short "known-good" checklist (slow spin, fast spin, horizontal, zoom, momentum) to re-run
   after each change.
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
5. **Upstream merges.** `Scroll.m` is the most actively developed file upstream. Keeping
   changes minimal and localized (favoring the dominant-axis approach over a 2-axis rewrite)
   will make future rebases far cheaper.
