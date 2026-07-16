# Scroll Engine Continuation Plan

## Goal

Make the Kensington Expert Mouse TB800 scroll ring feel:

- immediately responsive to changes in ring speed;
- smooth across irregular hardware reports and 60/120 Hz displays;
- precise when moving slowly or reversing direction;
- free from delayed acceleration, overshoot, and post-input drifting;
- close to the direct, controlled feeling of a Magic Mouse or trackpad.

This file is a handoff for continuing the work in another coding session. Read
`DEVELOPING.md` before changing the input pipeline.

## Repository state

- Branch: `feat/vibe`
- Latest committed scroll milestones:
  - `5593b2def rework scroll engine 1`
  - `79fc6e9f7 rework scroll engine 2`
- At the time this plan was written, the following tuning pass is implemented but
  uncommitted:
  - `Helper/Core/Config/ScrollConfig.swift`
  - `Helper/Core/Scroll/Scroll.m`
  - `DEVELOPING.md`
- `./dev.sh build` succeeds. Existing unrelated compiler warnings remain.
- There is no automated behavioral test suite; final validation requires the real
  TB800.

Run `git status --short` before doing anything. Preserve the current uncommitted
tuning changes.

## Implemented architecture

### Input and acceleration

`ScrollAnalyzer` now estimates actual line-unit velocity rather than treating each
event as one wheel detent:

```text
raw velocity = abs(line delta) / report interval
```

The velocity is filtered with a continuous-time EMA:

```text
alpha = 1 - exp(-dt / tau)
filtered += alpha * (raw - filtered)
```

Scroll distance uses:

```text
pxPerUnit(v) = pxAtRefSpeed * (v / refSpeed)^(gamma - 1)
pixels       = pxPerUnit(v) * unitsInReport
```

Relevant parameters:

- `refSpeed = 50 units/s`
- `pxAtRefSpeed = 10 + sensitivity * 140`
- `gamma = 0.4 + acceleration * 0.8`
- `acceleration = 0.75` gives `gamma = 1.0`, which is proportional input/output
  velocity.
- The current default `acceleration = 1.0` gives `gamma = 1.2`, which intentionally
  makes fast movement accelerate more than the ring.

Fast Scroll defaults to zero and the final output is capped after all acceleration
layers.

### Display-synchronized target follower

The `High Smoothness + Trackpad Simulation` path no longer restarts a finite
TouchAnimator curve for every hardware report.

It uses one display-synchronized critically damped target follower:

- hardware reports add distance to a cumulative target;
- velocity is preserved when the target changes;
- output is coalesced to display frames;
- accepted input distance is preserved exactly through subpixel error accounting;
- release drains only remaining target error;
- settling is monotonic and does not overshoot;
- direction reversal cancels the stale target before accepting the reversing
  report;
- gesture, momentum, end, and cancellation phases are still emitted.

The legacy TouchAnimator remains the fallback for:

- low and regular smoothness;
- High Smoothness without Trackpad Simulation;
- precise and quick-scroll modifications;
- zoom, rotate, pinch, swipe, and other gesture effects.

The hidden config key below can disable the new path:

```plist
Scroll.targetedScrollEngine = false
```

Existing configs that do not contain the key default to `true`.

## Latest user feedback

After the first target-follower implementation:

> It feels much better, but the acceleration of the ring and the acceleration of
> the scroll do not quite match, and it feels a bit like drifting.

Likely causes identified:

1. The velocity estimator used a 20 ms attack but a 40 ms release, so scroll speed
   remained elevated after the ring had already slowed.
2. The target follower used `omega = 65`, which adds approximately `2 / omega`,
   or 31 ms, of steady-motion following lag on top of estimator and display latency.
3. The target follower initially ignored the visible Smoothness and Glide sliders.
4. The default Acceleration slider is `1.0`, producing `gamma = 1.2`, so scroll
   acceleration is deliberately stronger than ring acceleration.

## Current uncommitted tuning pass

The latest changes address the first three causes:

### Velocity filter

The filter is now derived from Smoothness:

```text
attack tau  = 8ms  + smoothness * 16ms   // default 16ms
release tau = 10ms + smoothness * 20ms   // default 20ms
```

This keeps deceleration close to acceleration instead of holding speed twice as
long.

### Active target response

Smoothness now controls the active critical response:

```text
active omega = 110 - smoothness * 40     // 110...70 rad/s
```

At the default Smoothness value of `0.5`, omega is `90`, reducing approximate
steady following lag from 31 ms to 22 ms.

### Release and Glide

Glide now affects the target engine:

```text
release delay = 35ms + glide * 35ms      // 35...70ms
release omega = 44 - glide * 24          // 44...20 rad/s
```

At the current default Glide value of `0.75`:

```text
release delay ≈ 61ms
release omega = 26
```

The release code dynamically increases damping when necessary to guarantee
monotonic settling. Do not reduce that safeguard without testing overshoot and
one-pixel backward corrections.

Numerical checks at 60 and 120 Hz showed:

- no overshoot;
- exact final distance after subpixel accounting;
- single small movement settles in roughly 83 ms;
- repeated/fast sequences settle roughly 90–130 ms after the last report.

These are model checks, not substitutes for hardware testing.

## How to run the development Helper

The installed launchd Helper and the development Helper cannot run together. They
both claim the local CFMessagePort named:

```text
com.pixeption.mac-mouse-fix.helper
```

The easiest workflow:

1. Open the Mac Mouse Fix GUI.
2. Turn off **Enable Mac Mouse Fix**.
3. In the repository, run the Helper in the foreground:

   ```bash
   ./dev.sh run
   ```

4. Do not use `./dev.sh run &`.
5. If `NoMessagePortException` still occurs:

   ```bash
   launchctl bootout "gui/$(id -u)/com.pixeption.mac-mouse-fix.helper"
   ./dev.sh run
   ```

6. Press Ctrl-C when finished, then re-enable the normal Helper in the GUI.

`dev.sh stop` currently only kills processes. Because the installed service is
KeepAlive, launchd can immediately respawn it. Improving this developer experience
is one of the remaining tasks below.

## Immediate test procedure

Restart the Helper after every code change:

```bash
./dev.sh run
```

Begin with the user's existing settings. Change only one slider at a time.

Test in Safari, Chrome, Finder, VS Code, and Xcode:

1. One very small ring movement.
2. Slow continuous movement while reading text.
3. Gradual acceleration from slow to fast.
4. Gradual deceleration from fast to slow.
5. A hard spin followed by an abrupt stop.
6. Immediate direction reversal.
7. Reversal while content is against a scroll boundary.
8. Repeated short flicks.
9. Horizontal scrolling.
10. Start a fresh scroll on each attached display.
11. Rubber-band/overscroll behavior in Safari.
12. Confirm zoom, rotate, and trackball modes still use correct phases and speed.

Record feedback using these terms:

- **start lag**: content begins too late;
- **tracking lag**: content speed follows behind ring speed;
- **drift**: content keeps moving after intended stop/deceleration;
- **overshoot**: content crosses the intended target and corrects backward;
- **grain/jitter**: individual device reports become visible;
- **speed mismatch**: scroll acceleration grows faster or slower than ring
  acceleration;
- **sticky reversal**: old-direction movement resists the reversing report.

## Slider experiments

Use these experiments before changing more code:

### Acceleration mismatch

Set Acceleration to `0.75`.

This produces `gamma = 1.0`, so output velocity is proportional to measured ring
velocity. If this fixes the mismatch, consider changing the repository default
from `1.0` to `0.75` in all three fallback locations:

1. `Shared/Config/default_config.plist`
2. `Helper/Core/Config/ScrollConfig.swift`
3. `App/UI/Main/Tabs/ScrollTabController.swift`

Do not change the default until the proportional setting has been tested on the
real device.

### Remaining drift

Lower Glide from `0.75` toward `0.50`.

This shortens release detection and increases settling strength. If changing Glide
does not noticeably change release behavior, verify that the targeted engine is
active and that config reload reached the Helper.

### Remaining tracking lag

Lower Smoothness slightly, for example from `0.50` to `0.35`.

This both shortens the velocity filter and increases active target response. If
low Smoothness exposes report grain, restore it and change only the active response
mapping in `ScrollConfig.swift`.

## Remaining implementation work

### 1. Hardware-tune the current pass

Priority: highest.

- Test the current uncommitted changes on the TB800.
- Decide whether Acceleration `0.75` should become the default.
- Tune the Smoothness-to-active-response mapping.
- Tune the Glide-to-release mapping.
- Avoid adding another independent smoothing layer.
- Commit the tuning pass once it is clearly better than commit `79fc6e9f7`.

Acceptance criteria:

- gradual ring acceleration produces a matching gradual page acceleration;
- slowing the ring reduces page speed without a delayed tail;
- no visible per-report stepping;
- no overshoot or backward correction;
- reversal feels immediate.

### 2. Add low-overhead motion telemetry

If subjective feedback remains hard to describe, add sampled scalar logs rather
than logging every frame.

Suggested log, limited to approximately 10 samples per second:

```text
MFSCROLL_FEEL:
  rawInputVelocity
  filteredInputVelocity
  targetPixels
  outputPosition
  targetError
  outputVelocity
  inputActive
  omega
```

Also keep:

```text
MFSCROLL_LATENCY: inputToFirstOutputMs=... inputQueueMs=... engine=target
```

Do not restore expensive event-description or IOHID property logging to the hot
path.

Use telemetry to answer:

- Is the mismatch already present in filtered input velocity?
- Is target distance correct but output motion late?
- Does error remain after the user has stopped?
- Are release transitions occurring between normal hardware reports?

### 3. Improve release detection

The controller currently infers release from a fixed/config-derived silence
timeout because wheel hardware has no finger-lift signal.

Potential improvement:

- track recent report intervals;
- derive release delay from report cadence, bounded to a safe range;
- keep fast-input release short;
- avoid repeatedly transitioning gesture → momentum → gesture during medium-speed
  reports with gaps near the timeout.

Do this only if testing reveals false momentum transitions or medium-speed
stuttering. A more complex release detector is not automatically better.

### 4. Harden engine transition ordering

Review transitions between target follower and legacy TouchAnimator:

- settings changes while motion is active;
- entering zoom/rotate/precise/quick modes during coast;
- switching axis;
- Helper state reset;
- display re-binding;
- cancellation ordering across the two display-link queues.

`sendScroll()` still reads the global `_modifications` value. If a modification
changes before an asynchronous cancellation callback runs, an old scroll session
could theoretically send its final phase as the new effect type. This behavior
predates the target follower but should be fixed before expanding the new engine.

Likely fix:

- capture the output modification/type with each motion session;
- do not derive an old session's output type from mutable global state.

### 5. Fix `dev.sh run`

Make the script detect a loaded KeepAlive service before launching the direct
Helper.

Safe first improvement:

- check:

  ```bash
  launchctl print "gui/$(id -u)/com.pixeption.mac-mouse-fix.helper"
  ```

- if loaded, stop with a clear explanation and tell the developer to disable the
  GUI Helper;
- do not claim that `pkill` permanently stopped a KeepAlive service.

An automatic bootout/restore flow is possible, but it must not silently leave the
user's normal Helper disabled after a crash or terminal closure.

### 6. Cross-application phase validation

Confirm gesture and momentum phase behavior in:

- Safari rubber-band scrolling;
- Chrome;
- Xcode and VS Code;
- Finder;
- iPad apps on macOS if available.

Look for:

- stuck scroll state;
- application-added momentum;
- missing Ended events;
- rubber-band snapping;
- momentum that cannot be canceled by reversal.

### 7. Decide expansion scope

After the targeted path is stable:

- consider enabling it for High Smoothness without Trackpad Simulation using
  continuous pixel events;
- keep zoom, rotate, pinch, swipe, precise, and quick-scroll paths on the legacy
  animator until separately designed and tested;
- do not remove TouchAnimator merely because plain scrolling no longer needs it.

### 8. Cleanup after stabilization

Only after hardware and application validation:

- move the target follower out of `Scroll.m` into a focused class if doing so does
  not complicate Objective-C/Swift bridging or project-file integration;
- replace hardcoded experimental comments with concise architecture documentation;
- remove obsolete scroll-analysis and animation code only when no fallback uses it;
- update `Readme.md` and `DEVELOPING.md` with final defaults and supported paths;
- decide whether `Scroll.targetedScrollEngine` remains a permanent fallback or can
  be removed.

## Verification commands

Run after each implementation change:

```bash
git diff --check
plutil -lint Shared/Config/default_config.plist
./dev.sh build
```

For live testing:

```bash
./dev.sh run
```

In another terminal:

```bash
./dev.sh logs
```

The build currently emits unrelated warnings about deprecated archiving APIs and
some unused functions/variables. Do not confuse those existing warnings with a
scroll-engine regression.

## Definition of done

The scroll-engine work is complete when:

- the TB800 feels attached to the page during acceleration and deceleration;
- slow scrolling is precise and repeatable;
- fast scrolling covers distance without runaway amplification;
- stopping and reversing are immediate and predictable;
- there is no overshoot, backward correction, or lingering drift;
- behavior remains correct at 60 and 120 Hz;
- Safari, Chrome, Finder, VS Code/Xcode, and multi-monitor testing pass;
- zoom and other gesture effects remain unchanged;
- developer run instructions work reliably;
- defaults, UI fallbacks, runtime fallbacks, README, and developer documentation
  all agree.
