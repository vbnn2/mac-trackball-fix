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
  - `Helper/Core/Scroll/ScrollAnalyzer.m`
  - `Helper/Core/Scroll/Scroll.m`
  - `DEVELOPING.md`
  - `Readme.md`
  - `dev.sh`
  - `PLAN.md`
- `./dev.sh build` succeeds. Existing unrelated compiler warnings remain.
- There is no automated behavioral test suite; final validation requires the real
  TB800.

Run `git status --short` before doing anything. Preserve the current uncommitted
tuning changes.

## Accepted stable baseline — 2026-07-17

Real TB800 testing now prefers the Regular/legacy TouchAnimator path. The user described the latest pass as better
after repeated slow, fast, abrupt-stop, and direction-reversal tests. Do not resume tuning from the rejected target
follower unless a new, specific regression is reported.

The accepted stable path adds bounded-overload behavior after the velocity/distance mapping:

- sustained maximum output is report-rate-independent:
  `pxAtRefSpeed * refSpeed * 15` pixels/second;
- the first report remains separately bounded to `pxAtRefSpeed * 15` pixels, so the higher sustained maximum does
  not create a large initial jump;
- overload carry is capped independently near `pxAtRefSpeed * refSpeed * 0.525` pixels instead of growing with the
  speed ceiling;
- fast release friction is raised to at least `32`, while normal-speed Glide behavior remains user-controlled;
- when an animation is still moving at least 800 px/s, the first opposite ring report cancels the coast without
  producing a small rebound. A sustained reversal is accepted from its second report;
- `MFSCROLL_OUTPUT` records the cadence of integer pixel events actually sent to applications, not merely display
  callbacks inside the animator.

Final captured validation:

- visible fast output reached approximately 10,522 px/s;
- active fast output averaged 58.6 events/s on the 60 Hz test display;
- input-to-first-output latency averaged 20.1 ms, with 27.5 ms p95;
- 19 rebound reports were converted into stops;
- the same Helper process remained running and never exited throughout the test.

Next step: keep this baseline and perform normal-use soak testing. If feel regresses, capture telemetry with
`./dev.sh logs-record`, reproduce only the problematic gesture, then run `./dev.sh logs-record-stop`. Change one
behavior at a time and retain the Regular/legacy path as the comparison baseline.

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
- `maximumSpeed = 0.5` caps sustained output at `15 * pxAtRefSpeed * refSpeed`.
  The slider maps `0.1...1.0` to `3x...30x`, so its midpoint preserves the accepted
  hardware-tuned limit and its maximum doubles that limit.

The upstream Fast Scroll setting defaults to zero and is no longer exposed in the UI. It is a
swipe-history multiplier designed for bursts from notched wheels; on a free-spinning ring its
result depends on how reports happen to be grouped. Maximum Speed is the predictable final cap
after acceleration instead.

Regular animated output sends an explicit gesture end before its momentum portion. This lets
macOS perform the native short rubber-band snap-back at a content edge without waiting for the
entire variable-duration MMF animation to finish.

The TB800 cannot report finger presence while its ring free-spins. To avoid treating the entire
spin as a direct finger drag, output above `1.5x` reference speed is promoted to momentum after a
fixed `100ms` direct phase and remains momentum until the animation session ends. Input distance
is preserved; only native edge-resistance behavior changes.

Opposite-direction rebound suppression is limited to reports arriving within `80ms` of the
previous physical input. Later reversals cancel the old coast but keep their first delta; this
prevents the first scroll after switching windows from being mistaken for mechanical rebound.

Continuous direct gestures send `MayBegin` before `Began`. The first physical report after the
frontmost application changes also cancels the previous app's animation session. This prevents a
newly activated browser from ignoring promptly emitted deltas that lack a valid opening phase.

Effective Smoothness uses two UI values: **Slow Smoothness** at zero speed and **Smoothness** for
normal/fast movement. **Adaptive Until** controls where the smoothstep blend returns to normal as a
fraction of Maximum Speed (defaults: `90%`, `12.5%`). Smoothness readouts show the corresponding
`0.4×...1.6×` animation-duration multiplier. Slow adaptation continues to follow speed during
deceleration; stopped-state tail protection is handled separately so it cannot distort fast-to-slow tracking.
The first late low-velocity report after a confirmed fast section is reduced and shortened, not dropped. A second
slow report proves intentional continuation and restores adaptive smoothing and full distance; becoming fast again
re-arms the one-report protection. This avoids both the old sticky first-scroll regression and a fast-to-slow latch.
The protected report uses a smoothstep of current output speed (strong at rest, inactive by 400 px/s) so that the
boundary itself does not introduce a pause while the page is visibly decelerating.

### Experimental display-synchronized target follower — disabled by default

An experimental `High Smoothness + Trackpad Simulation` path avoids restarting a finite
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

Hardware testing exposed a fundamental problem with the current position-step design: scroll
reports arrive only when the ring changes and were commonly 20–100 ms apart, while the stiff
follower consumed each report's target distance much sooner. Output therefore stopped between
reports and looked like 15–20 FPS. Keeping a gesture phase open longer did not help because no
distance remained to output.

The hidden config key is now opt-in and defaults to false:

```plist
Scroll.targetedScrollEngine = false
```

Existing configs that do not contain the key also default to `false`. The legacy TouchAnimator is
the safe normal-testing path until the redesign below is complete.

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

After the response/release tuning was enabled, hardware testing showed a larger regression:

> The scroll is not smooth at all; it feels like 15–20 FPS.

The logs confirmed that the target controller repeatedly reached `errorPx=0` and
`outputV=0` between sparse input reports. `inputQueueMs` was normally below 1 ms and
`frameHz=60` matched the tested 60Hz monitor, so neither queue congestion nor display
selection caused the stutter. The position target itself was being drained too quickly.

Reservoir redesign implemented in the current worktree:

1. Accepted pixel distance is kept in `_motionPendingDistance`.
2. The current reservoir is scheduled over 1.25 times the recent real event cadence,
   with a minimum of two display frames and a maximum of 140 ms.
3. Faster cadence updates immediately; slower cadence uses a 60 ms time-based filter.
4. Each display callback transfers only `feedSpeed * dt` from pending distance into
   the spring target, capped by the exact amount remaining.
5. Settling requires both pending distance and spring error to be empty.
6. Direction reversal still cancels stale old-direction state before accepting the
   reversing report.

`MFSCROLL_FEEL` now includes `acceptedPx`, `pendingPx`, `feedV`, and `feedMs` so hardware
logs show whether the reservoir empties between normal reports.

The deterministic model in `Tests/ScrollReservoirModel.swift` covers isolated input,
95 ms sparse input, 50 ms input, 20 ms input, and acceleration at 60/120/144 Hz. It
currently passes exact-distance, monotonicity, no-overshoot, no-active-gap, and settling
checks in all 15 combinations. Run it with:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/mac-trackball-fix-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/mac-trackball-fix-swift-cache \
xcrun swift Tests/ScrollReservoirModel.swift
```

The experimental engine remains disabled by default until real TB800 testing passes.
Use `./dev.sh run-target` to select and launch it, and `./dev.sh run-stable` to return
to Regular + legacy scrolling.

### Reservoir hardware result — rejected as the normal engine

Real TB800 testing failed despite the deterministic model passing:

- slow scrolling still felt like multiple short bursts;
- fast scrolling remained responsive but looked low-frame-rate;
- fast direction reversal left the scroll subsystem inert while the Helper process
  remained alive.

This demonstrates that the model's no-gap scalar criterion is not a sufficient proxy
for perceived smoothness. More importantly, the hardware ambiguity remains: after a
sparse report, the engine cannot know whether another slow report is coming or the user
has stopped. A short feed horizon creates bursts; a long horizon creates drift.

The default remains the stable legacy animator. Do not promote `targetedScrollEngine`
without a substantially different model and another explicit hardware test.

Reversal hardening added after this test:

- experimental reversal now cancels/reset its session in place without stopping and
  restarting CVDisplayLink;
- the primary scroll event tap now re-enables itself for both timeout and user-input
  disable notifications, preventing a live Helper with permanently inert scrolling;
- `MFSCROLL_LEGACY` records stable-engine velocity, retained distance, base/total
  duration, and glide coefficient for the next evidence-based tuning pass.

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

Numerical checks of the position follower at 60, 120, and 144 Hz showed:

- no overshoot;
- exact final distance after subpixel accounting;
- single small movement settles in roughly 83 ms;
- repeated/fast sequences settle roughly 90–130 ms after the last report.

Those checks verified settling math but did not model sparse hardware reports. They therefore
missed the event-rate bursting found on the real TB800.

### Polling rate versus scroll-event rate

Velocity measurement now uses its own 1ms minimum interval instead of the legacy
acceleration curve's 15ms extrapolation boundary. This avoids imposing an artificial
66.7 reports/s ceiling if events do arrive faster.

The TB800's 750Hz value is its USB polling rate, not a promise of 750 scroll changes per
second. The ring sends a signal only when it changes. The captured `MFSCROLL_FEEL`
cadence was commonly 20–100 ms. Algorithms must use actual event timestamps and must
remain smooth across those sparse, uneven reports.

## How to run the development app

Use the normal GUI-managed lifecycle:

```bash
./dev.sh run
```

This builds the complete app, opens its GUI, and asks that app to unregister the old
Helper and register the newly built embedded Helper through SMAppService. The command
returns immediately; use `./dev.sh logs` in another terminal when logs are needed.

The old direct-Helper workflow is available as `./dev.sh run-helper`. Only that advanced
mode requires disabling **Enable Mac Mouse Fix** first and keeping the command in the
foreground.

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

### 2. Add low-overhead motion telemetry — implemented

Sampled scalar logs are implemented at approximately 10 samples per second rather
than every frame.

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
  cadenceMs
  releaseMs
  frameHz
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

### 3. Improve release detection — implemented, needs hardware validation

The controller infers release from a slider-derived base timeout plus recent input
cadence because wheel hardware has no finger-lift signal.

Implemented behavior:

- track recent report intervals with a time-based 60ms filter;
- derive release delay from report cadence, bounded to 140ms;
- keep fast-input release short;
- avoid repeatedly transitioning gesture → momentum → gesture during medium-speed
  reports with gaps near the timeout.

Hardware testing must confirm this avoids false momentum transitions without
reintroducing drift. A more complex release detector is not automatically better.

### 4. Harden engine transition ordering — partially implemented

Review transitions between target follower and legacy TouchAnimator:

- settings changes while motion is active;
- entering zoom/rotate/precise/quick modes during coast;
- switching axis;
- Helper state reset;
- display re-binding;
- cancellation ordering across the two display-link queues.

Each target and legacy animation session now snapshots its modification and config.
`sendScroll()` no longer derives an old session's output type or inversion from
mutable `_modifications` / `_scrollConfig` state.

Still to validate:

- cancellation ordering across the target and legacy display-link queues;
- settings/effect changes during active gesture and momentum phases.

### 5. Fix `dev.sh run` — implemented

The default run command now launches the complete app and delegates Helper replacement
to the app's existing SMAppService lifecycle. It automatically rebuilds and relaunches
both GUI and Helper, leaves the enable switch usable, and does not occupy the terminal.

The conflict check and foreground restrictions now apply only to `run-helper`, which is
kept as an explicit low-level debugging mode.

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
- behavior remains correct at 60, 120, and 144 Hz;
- Safari, Chrome, Finder, VS Code/Xcode, and multi-monitor testing pass;
- zoom and other gesture effects remain unchanged;
- developer run instructions work reliably;
- defaults, UI fallbacks, runtime fallbacks, README, and developer documentation
  all agree.
