# TB800 ring scroll engine rewrite plan

Status: Phases 0–4 complete; Phase 5 independent-axis renderer implemented behind a Debug-only gate, physical
acceptance pending.

Last updated: 2026-09-05

Implementation snapshot:

- The legacy engine remains the only output authority.
- Sanitized baseline fixtures, a fixed-capacity pure input correlator, deterministic tests, and a non-seizing TB800
  HID sidecar are checked in locally.
- `MFSCROLL_RING_HID` and `MFSCROLL_RING_INPUT` expose raw/CG pairing without delaying a CG report.
- The deployed exact-collection sidecar paired 240/240 reports in one helper session across 204 vertical and 36
  horizontal reports, both directions, with matching registry IDs, zero sign mismatches, and zero overflow. The
  TB800 Wheel element requires vertical polarity normalization; Consumer Pan does not.
- A 21.025-second-idle capture proves the opposite baseline originates in raw HID: one raw count was followed 28 ms
  later by the real opposite ramp. Report ID, element, and magnitude provide no discriminator on arrival, so the
  rewrite must give genuine and artifact one-count starts the same immediate calibrated response.
- `RingMotionModel` provides the Phase 2 pure leaky-impulse core with explicit units, asymmetric speed filtering,
  adaptive sparse decay, analytic frame integration, atomic reversal/reset, and independent initial, velocity, and
  remaining-area bounds. Deterministic, randomized, refresh-schedule, packetization, and JSONL replay tests run from
  `./dev.sh scroll-tests` across captured sparse, active/paused reversal, rebound-shaped resume, horizontal, long-idle
  baseline, and target-reset traces.
- Phase 3 routes eligible TB800 Regular custom-acceleration reports to a separately owned `ring-shadow` diagnostics
  queue after target/config/modifier resolution. It predicts the first frame, velocity envelope, signed total/stop,
  reversal response, and maximum remaining area. It has no event-posting or animator API; legacy remains authoritative.
- The full project builds and the legacy engine remains the only output authority.

This document defines the replacement for the Regular smooth-scroll path used by the Kensington Expert Mouse TB800
free-rotating scroll ring. It is intentionally a trackball-ring design, not a generic mouse-wheel smoother.

The canonical behavioral history remains [SCROLL_REGRESSION_LOG.md](SCROLL_REGRESSION_LOG.md). If this plan and the
ledger disagree, the ledger wins until a new evidence-backed ledger entry explicitly changes the contract.

## Executive decision

Replace the current per-report finite-animation pipeline with one continuous, bounded velocity system driven by
physical ring counts.

The proposed engine has four essential properties:

1. Read the TB800's raw signed HID Wheel/Pan values when available; use the CGEvent line delta only as an immediate
   fallback. Never use the already-accelerated CGEvent point delta as physical distance or velocity.
2. Treat each ring count as a velocity impulse. Integrate one velocity state at display cadence with an analytic
   exponential decay. Do not construct a new HybridCurve or target-distance animation for every report.
3. Let the physical free-spinning ring provide the long inertia. Software supplies only bounded interpolation between
   quantized ring reports, with more overlap for established sparse motion and less for fast motion.
4. Migrate behind replay, shadow-mode, and runtime-selection gates. Reuse the proven display-link, routing, reset,
   synthetic-event, and output compatibility work instead of replacing the whole scroll stack at once.

The intended core is a leaky impulse integrator, not a spring, target follower, delayed distance reservoir, or
mouse-style report counter.

## Why a rewrite is justified

### Recent captured slow start

The latest candidate in macOS unified logs came from helper PID `1800` on 2026-09-01:

- `23:16:59.565`: after `284,017.6 ms` without physical wheel input, the TB800 delivered
  `line=(1,0) point=(1,0)`.
- The queue took `0.52 ms`, the display link started successfully, and first nonzero output arrived in `6.85 ms`.
- The long-idle baseline policy changed the normal `32 px` opening to `10 px`, with a `50 ms` base and `123.4 ms`
  total response.
- `23:16:59.842`: the next physical report was the same direction and same `line=1 point=1` signature, `277 ms`
  later. The previous response had stopped. This report received the normal approximately `31 px`, `80 ms` opening
  and reached output in `13.47 ms` with `0.43 ms` queued.
- There was no event-tap disable, display recovery, display start failure, target change, rate limit, or dropped
  carry around the sequence.

The perceived delay was therefore an amplitude false positive followed by hardware silence, not processing latency.
The long-idle workaround introduced on 2026-08-21 correctly bounded captured wrong-sign wake reports, but this trace
shows the admitted inverse ambiguity: the same signature can be a genuine start.

For comparison, the ordinary start at `23:12:15.215` used `32 px` and an `80 ms` base, with healthy `14.45 ms`
first-output latency. The meaningful behavioral difference was the idle classifier, not the delivery pipeline.

### Structural failure pattern

The regression ledger repeatedly found healthy queue/display latency while response-shape classifiers selected weak
openings. Fixes accumulated around combinations of:

- first versus measured report;
- stopped versus live animator;
- same direction versus reversal;
- remembered versus new cadence;
- wake, fast, settling, sharp-deceleration, and point-collapse tails;
- short, gesture-boundary, and memory-horizon gaps;
- line-unit velocity versus macOS point amplification.

The 2026-08-17 consolidation removed six stopped-opening caps by recognizing one underlying invariant: slow-duration
inflation cannot preserve continuity after the animation has stopped. The current long-idle false positive shows the
larger problem remains: the engine still tries to infer physical intent from ambiguous isolated packets so it can
choose a finite response duration and distance.

### Current architectural mismatch

The current Regular engine:

1. converts one physical report to a finite pixel distance;
2. retrieves distance left from the previous TouchAnimator curve;
3. combines new distance and bounded carry;
4. derives a base duration from cadence and several response policies;
5. constructs a new HybridCurve;
6. retargets it while trying to preserve live velocity;
7. relies on classifications to decide when duration/carry should or should not survive.

That model is workable for a notched mouse wheel, where reports are deliberate isolated impulses. It is a poor fit
for a mechanically inertial ring whose report magnitude and cadence jointly describe angular motion and whose
receiver can emit sparse, aggregated, settling, or wake packets.

## Goals

### Behavioral goals

- A physical report affects the next available output frame. No confirmation count or input quarantine.
- The first report uses a bounded, normal response because cadence is unknown.
- The first real measured continuation may establish sparse-motion smoothing.
- Faster input changes the response on that same report.
- Same-direction reports add energy without resetting output velocity.
- Reversal cancels old-direction output immediately and processes the reversing report.
- Established extremely slow rotation remains visually continuous across sparse encoder reports.
- Fast physical coasting does not acquire a second long software coast.
- A stopped ring cannot leave a large distance queue that drains later.
- Behavior is stable across report packetization and 60/120/variable-refresh displays.
- Target, app, window, modifier, config, click, and display changes cannot inherit old motion.

### Engineering goals

- One authoritative motion state instead of per-symptom flags.
- A pure deterministic model that can be replayed without AppKit, CoreVideo, or a physical device.
- Explicit units throughout: ring counts, counts/second, pixels/count, pixels/second, seconds, and pixels.
- Separate limits for initial response, instantaneous output velocity, and remaining carry area.
- Versioned telemetry that explains every state transition without reconstructing hidden flags.
- A runtime fallback to the legacy engine during migration.

## Non-goals

- Do not redesign zoom, rotate, Dock gestures, Command-Tab, or other phase-sensitive effects in the first migration.
- Do not replace the hardened DisplayLink implementation or its liveness watchdog.
- Do not switch ordinary Regular scrolling to synthetic trackpad gestures. Keep phase-less pixel-wheel output.
- Do not create a second target follower or distance reservoir.
- Do not seize the HID device; the ball, buttons, and native system clients must keep receiving input.
- Do not tune around a single application, display, or refresh rate.
- Do not remove the legacy path before the new path passes physical and replay gates.

## Non-negotiable invariants carried from the ledger

1. Never wait for a timer or a fixed number of reports before handling physical input.
2. A new report can accelerate or retarget live motion immediately without throwing away same-direction velocity.
3. Reversal cancels old-direction motion and keeps the reversing report.
4. Missing cadence on the first report is not evidence of extremely slow input.
5. Slow smoothing may start from the first actual interval; acceleration invalidates stale slow cadence immediately.
6. Any mechanical-settling protection must be narrow, one-shot, non-deferred, and must not mutate accepted motion
   history before the report is accepted.
7. Requested-running is not proof that display callbacks are alive.
8. Every synthetic gesture path that begins a phase must send a terminal phase.
9. Session changes cannot carry velocity, subpixels, phases, cadence, or prediction into the new target.
10. Maximum output velocity, initial response, and remaining carry are independently bounded.
11. Regular pixel-wheel output remains phase-less for Chromium/Telegram compatibility.

## Device facts and input choice

### Locally observed TB800 descriptor

Device descriptor inspection on 2026-09-01 identified the attached ring device as:

- Product: `Expert Mouse TB800 EQ 2.4GHz`
- Vendor ID: `1149`
- Product ID: `33129`
- Input report ID: `1`
- Generic Desktop Wheel usage: `0x38`
- Wheel logical range: signed relative 8-bit, `-127...127`
- Consumer Pan usage: `0x0238`, also signed relative 8-bit
- Advertised input report interval: `1 ms`

USB HID defines Wheel as Generic Desktop usage `0x38`. Apple exposes interrupt-driven element values through
`IOHIDDeviceRegisterInputValueCallback`; `IOHIDValue` includes both the integer value and its timestamp.

References:

- [USB HID Usage Tables](https://www.usb.org/sites/default/files/hut1_21_0.pdf)
- [IOHIDDeviceRegisterInputValueCallback](https://developer.apple.com/documentation/iokit/1588672-iohiddeviceregisterinputvaluecal)
- [IOHIDValue](https://developer.apple.com/documentation/iokit/iohidvalue_h)
- [kHIDUsage_GD_Wheel](https://developer.apple.com/documentation/iokit/1592534-anonymous/khidusage_gd_wheel)

### Why raw HID is preferred

The existing telemetry shows one line unit becoming point magnitudes such as `1`, `6`, `20`, and much larger values
as macOS acceleration changes. Point magnitude is useful evidence about the downstream ramp, but it is not a stable
physical unit. Apple documents separate line/fixed/point scroll fields, with PointDelta representing pixel-based
scroll data.

Reference: [CGEvent scroll fields](https://developer.apple.com/documentation/coregraphics/cgeventfield)

Raw HID gives the engine:

- the signed physical count before WindowServer scroll acceleration;
- the device identity;
- the report timestamp closest to the receiver;
- vertical Wheel and horizontal Pan as separate physical elements;
- a way to determine whether long-idle baseline/wake artifacts originate in hardware/receiver reports or later.

### Non-seizing sidecar design

Open the TB800 using `kIOHIDOptionsTypeNone`. Do not use `kIOHIDOptionsTypeSeizeDevice`; Apple documents that seizure
prevents the system and other clients from receiving events.

Reference: [kIOHIDOptionsTypeSeizeDevice](https://developer.apple.com/documentation/iokit/1556660-anonymous/kiohidoptionstypeseizedevice)

The HID callback is a measurement sidecar, not the suppression/routing owner:

1. The HID callback records a compact immutable raw sample into a small timestamped buffer.
2. The existing HID CGEvent tap receives the corresponding event, identifies target window/app/display and current
   modifications, suppresses the original event, and looks up the already-arrived raw sample.
3. If an exact device/time/value match is present, the engine uses the raw count.
4. If no raw match is immediately available, it processes the CGEvent line delta on the same callback path and logs
   `source=cg-line-fallback`. It never waits for the raw callback.
5. Point/fixed deltas remain telemetry for correlation and platform diagnosis; they do not drive the ring model.

This preserves the immediate-input invariant while allowing a clean physical signal whenever the system exposes it.

## Proposed architecture

```text
TB800 interrupt report
        |
        v
RingHIDSource ---- timestamped raw-sample buffer
                                      |
                                      v
CGEvent tap -> routing/modifiers -> RingInputCorrelator -> immutable RingReport
                                                        |
                                                        v
                                                RingMotionModel
                                                        |
                                                one velocity state
                                                        |
                                                        v
                                               DisplayLink renderer
                                                        |
                                                        v
                                          phase-less pixel-wheel output
```

The new components should be small and have single responsibilities.

### 1. `RingHIDSource`

Responsibilities:

- match only the intended TB800 device/collection;
- register Wheel and Pan input-value callbacks without seizing;
- normalize timestamps to the timebase used by CGEvent/CACurrentMediaTime;
- publish signed count, axis, report ID, device registry ID, and timestamp;
- use a fixed-capacity buffer and explicit overflow telemetry;
- detach cleanly on device removal and reattach on receiver reconnect.

It must not:

- suppress events;
- resolve targets/modifiers;
- run the motion model;
- post synthetic events;
- retain unbounded samples.

### 2. `RingInputCorrelator`

Responsibilities:

- pair one handled CGEvent with the nearest compatible raw sample;
- reject already-consumed, wrong-axis, wrong-sign, or implausibly distant samples;
- emit one `RingReport` for every physical report handled by the engine;
- fall back immediately to CGEvent line units when pairing is unavailable;
- record raw/line/point agreement so assumptions remain observable.

Suggested `RingReport` fields:

```text
timestamp
deviceRegistryID
source = hid | cg-line-fallback
axis = vertical | horizontal
signedUnits
cgLineDelta
cgPointDelta
cgFixedDelta
targetBundleID
targetWindowID
displayID
modificationSnapshot
configGeneration
```

### 3. `RingMotionModel`

This is a pure deterministic module. It owns no dispatch queue, CoreVideo object, CGEvent, application lookup, or
logging framework. Given timestamped reports and frame times, it returns output deltas and structured diagnostics.

Suggested state:

```text
direction
lastAcceptedReportTime
rawSpeed
filteredSpeed
cadenceEstimate
cadenceConfidence
velocityPxPerSecond
decayTime
subpixelRemainder (or keep this in the renderer)
generation
```

There should be no state named for wake, tail, close reversal, stopped continuation, point collapse, app, or a
specific symptom. Input anomalies may be sanitized before the model only when raw evidence supplies a reliable
signature.

### 4. `RingScrollRenderer`

Responsibilities:

- own the model on one serial queue shared with display callbacks;
- bind the existing DisplayLink to the routed display;
- enqueue accepted reports and ordered resets;
- analytically integrate velocity for each real frame interval;
- keep independent velocity/cadence and signed subpixel state for the device's
  Wheel and Consumer Pan controls while advancing both from one frame clock;
- combine both integer components into one routed wheel event per callback;
- stop the display link when velocity and subpixel output are exhausted;
- preserve the current cold-start watchdog and stalled-link recovery contract.

### 5. Existing session/output layer

Reuse current behavior for:

- app/window target reset;
- click reset;
- modifier/config generation reset;
- display selection and reconfiguration;
- synthetic source marking and early tap bypass;
- phase-less continuous pixel-wheel event construction;
- output rate/cadence telemetry;
- zoom/effect lifecycle while those paths remain legacy.

## Motion model

### Units

Use these meanings consistently:

- `u`: signed raw ring counts in the current report.
- `dtReport`: seconds between relevant accepted reports.
- `omega`: absolute physical ring speed in counts/second.
- `D(omega)`: pixels of total response per physical count.
- `tau`: seconds of exponential response decay.
- `v`: signed current output velocity in pixels/second.
- `dtFrame`: actual display callback interval in seconds.

### Speed estimator

For a measured same-session report:

```text
omegaRaw = abs(u) / dtReport
```

Use a continuous-time asymmetric filter:

```text
alpha = 1 - exp(-dtReport / timeConstant)
omega = omega + alpha * (omegaRaw - omega)
```

- Use a short attack constant when `omegaRaw >= omega`.
- Use a longer release constant for ordinary deceleration noise.
- Material acceleration may use the current raw estimate directly for response calculation on that report, while
  the filtered estimate remains the stable state.
- Multi-unit reports must affect both numerator and distance; never treat one event as one count.
- Reset the signed estimator on reversal before processing the reversing report.

The first report after a true session reset has no measured cadence. It uses a bounded configured start speed and
normal decay. It must not divide by the preceding idle gap.

### Sensitivity and acceleration transfer

Retain the current explicit physical semantics, subject to replay retuning:

```text
D(omega) = pixelsAtReferenceSpeed
           * (omega / referenceSpeed)^(gamma - 1)
           * modeAndDisplayScale
```

Then:

```text
modeledOutputSpeed = D(omega) * omega
```

- Sensitivity controls `pixelsAtReferenceSpeed`.
- Acceleration controls `gamma` around the reference-speed pivot.
- Maximum Speed caps final output velocity after every multiplier.
- Precise/Quick and display scaling remain explicit one-time multipliers.
- The first report has a separately bounded `Dstart`; it cannot consume the sustained speed ceiling.

### Adaptive decay for a free ring

`tau` controls interpolation, not simulated wheel inertia.

- Fast physical motion: use a short `tau`. Frequent reports already keep velocity alive, and the ring itself supplies
  physical coast.
- Established sparse motion: let `tau` approach a bounded fraction of measured cadence so output overlaps the next
  likely encoder report.
- Unknown first report: use normal `tauStart`, not maximum slow `tau`.
- Acceleration: shorten/update `tau` on the accelerating report.
- Cadence confidence: decay continuously as information becomes stale instead of switching at an event count.

A candidate continuous mapping is:

```text
tauSparse = clamp(cadenceEstimate * overlapRatio, tauSlowMin, tauSlowMax)
slowBlend = smoothstep(slowSpeedEnd, 0, omega)
tau = mix(tauFast, tauSparse, slowBlend * cadenceConfidence)
```

Exact constants are not accepted by this plan. They must come from replay plus physical AB testing. The model shape,
units, monotonicity, and bounds are accepted; tuning values are a later deliverable.

Cadence rules:

- Report one after reset uses no preceding silence.
- Report two supplies the first actual interval and may establish sparse overlap immediately.
- A report crossing a confidence/expiry boundary opens with bounded normal behavior and may update cadence only for
  later reports.
- Faster or larger input reduces slow cadence confidence on that same report.
- A small reversal clears signed velocity but may reuse only scalar cadence confidence when still genuinely recent.

### Velocity impulse

For each accepted report, after choosing `D` and `tau`:

```text
impulseVelocity = signedUnits * D(omega) / tau
```

Same direction:

```text
v = v + impulseVelocity
```

Reversal:

```text
v = 0
v = impulseVelocity
```

The integral of an isolated exponential impulse is its requested distance:

```text
integral((D / tau) * exp(-t / tau), t=0...infinity) = D
```

This distributes each physical count smoothly without creating a target position or restarting a finite curve.
Same-direction input naturally retains live velocity. A reversal cannot retain old-sign area because it zeroes `v`
before applying the new impulse.

### Exact frame integration

Do not use Euler integration. For a frame interval `dtFrame`:

```text
decay = exp(-dtFrame / tau)
frameDistance = v * tau * (1 - decay)
v = v * decay
```

This makes total response independent of whether callbacks arrive at 60 Hz, 120 Hz, 144 Hz, or with modest variable
refresh jitter.

### Carry and overload bounds

The remaining exponential area is explicit:

```text
remainingDistance = abs(v) * tau
```

Apply separate safety limits:

1. `maximumInitialDistance`: bounds `Dstart` when cadence is unknown.
2. `maximumOutputVelocity`: caps `abs(v)` after every impulse/multiplier.
3. `maximumRemainingDistance`: caps `abs(v) * tau`; excess is discarded and logged on the current report.

Do not store discarded excess elsewhere. There is no delayed reservoir.

### Stopping

Stop the display link when all are true:

- `abs(v)` is below a velocity epsilon chosen relative to pixel visibility;
- the subpixel accumulator cannot produce another nonzero pixel under the remaining bounded area;
- no ordered report/reset is pending on the owner queue.

Regular output is phase-less, so stopping does not owe a scroll terminal phase. Phase-sensitive effect paths retain
their existing explicit terminal lifecycle.

## State transitions

The motion core needs only a small state machine:

### `Idle`

- No visible velocity and no live display callbacks requested.
- The first report uses bounded normal start parameters.
- The report starts the display link immediately.

### `Active`

- Display callbacks integrate current velocity.
- Same-direction reports add impulses.
- Faster reports update speed/decay immediately.
- Slow measured reports update cadence confidence without a confirmation counter.

### `Reversing`

This is an atomic transition, not a persistent waiting state:

1. discard old-sign velocity/subpixel sign state;
2. end/cancel any phase-sensitive legacy effect if applicable;
3. apply the current opposite report;
4. return to `Active`.

### `Resetting`

This is also atomic:

1. stop/cancel output for the old generation;
2. clear velocity, cadence, direction, subpixels, correlation ownership, and target snapshot;
3. send terminal phases for any active effect gesture;
4. increment generation so old callbacks are rejected;
5. let the same new physical report open the new session when the reset was report-triggered.

No state waits to discover whether an input was intentional.

## Ambiguous hardware artifacts

### Long-idle baseline

Phase 1 raw capture must answer:

1. Does the isolated long-idle `+/-1` baseline exist in the raw HID Wheel value?
2. Does its HID report contain any unique report ID, companion element, timing, receiver status, or sequence marker?
3. Is the later real ramp distinguishable before its second report?

If raw data contains a reliable distinction, implement it in a tiny `RingInputSanitizer` before motion history is
updated. The rule must be device-specific, one-shot, immediate, and directly tested from captured raw reports.

If raw data is identical to a genuine isolated tick, software cannot causally infer intent. In that case:

- do not add a timer, confirmation gate, delayed replay, or direction vote;
- give both reports the same calibrated low-speed response;
- prefer consistent honest behavior over idle-dependent suppression;
- document the remaining wrong-sign versus weak-start tradeoff in the ledger;
- optionally expose a user choice only if physical testing shows no acceptable common response.

### Mechanical settling/rebound

Apply the same evidence standard. First determine whether raw HID timing/value sequences distinguish actual ring
settling from a deliberate resume. If not, the core model should not classify intent. Its low-speed impulse and
remaining-area bounds must make an isolated artifact tolerable without making a real report invisible.

During migration, the existing narrow compatibility guard may remain only around the legacy engine. It must not be
copied into the new core by default.

## Concurrency and ownership

### Queues

- HID callback: capture immutable raw samples only; no UI lookup, model update, or event posting.
- Existing scroll queue: preserve physical event order, resolve routing/config/modifiers, pair raw/CG samples, and
  enqueue immutable reports/resets.
- Renderer/display-link queue: sole owner of motion state, subpixel state, display-link generation, and output
  integration.

Every reset and report leaving the scroll queue receives a monotonically increasing sequence number. The renderer
applies them in order. Display callbacks may occur between reports, but an older generation may never emit after a
reset for a new target/config.

### Snapshots

Every `RingReport` carries an immutable config/modification/target generation. The renderer must not read mutable
global configuration while applying an old report.

### Callback safety

- Never carry borrowed `CGEventRef` or `IOHIDValueRef` objects across an asynchronous boundary.
- Copy required scalar fields synchronously.
- Reuse the existing DisplayLink callback-admission and lifecycle generations.
- Keep at most the existing bounded callback backlog; stale display timestamps do not accumulate work.

## Output compatibility

The first rewrite stage keeps the proven ordinary output format:

- `CGEventCreateScrollWheelEvent(..., kCGScrollEventUnitPixel, ...)`;
- two independently reported physical axes may remain active together, with
  both components combined into one display-paced event when their tails overlap;
- synthetic 64-bit source marker;
- phase and momentum phase unset;
- line/fixed fields derived from the emitted pixel delta using the existing pixelator semantics;
- post at the HID tap so normal target routing remains intact;
- MMF-marked output bypasses physical-input decoding/telemetry on re-entry.

Do not alter Chromium/Telegram phase behavior as part of motion-model migration.

## Configuration strategy

### Reuse user-facing controls

Initially retain the current visible controls:

- Sensitivity
- Acceleration
- Maximum Speed
- Smoothness
- Slow Smoothness
- Adaptive Until
- Glide

Map them to explicit new-engine quantities rather than legacy curves:

- Sensitivity -> `pixelsAtReferenceSpeed`
- Acceleration -> `gamma`
- Maximum Speed -> `maximumOutputVelocity`
- Smoothness -> normal/fast decay time
- Slow Smoothness -> maximum sparse overlap ratio/decay
- Adaptive Until -> speed where sparse decay fades to normal
- Glide -> bounded release scaling, with a deliberately small effect at fast free-ring speed

Do not expose raw time constants until physical testing proves the existing semantic mapping insufficient.

### Engine selector

Add a development-only selector during migration:

```text
legacy
ring-shadow
ring-live
```

The selector must be captured in the immutable config snapshot and telemetry. Release builds keep legacy as the
fallback until ring-live passes all gates.

## Telemetry contract

Introduce versioned records instead of overloading `MFSCROLL_LEGACY`.

### `MFSCROLL_RING_INPUT`

One record per handled physical report:

```text
engineVersion
sequence
generation
source=hid|cg-line-fallback
device
axis
units
hidToCGMs
cgLine
cgPoint
cgFixed
target
window
display
```

### `MFSCROLL_RING_MODEL`

One record per report after the pure model update:

```text
sequence
direction
directionChanged
dtMs
rawOmega
filteredOmega
cadenceMs
cadenceConfidence
pxPerUnit
tauMs
velocityBefore
impulseVelocity
velocityAfter
remainingPx
velocityLimited
carryDroppedPx
```

### `MFSCROLL_RING_FRAME`

Aggregate frames over a short active window rather than logging every callback:

```text
generation
display
frameHz
maxFrameGapMs
nonzeroEventHz
outputPx
peakVelocity
remainingPxAtEnd
```

### Existing records retained

- `MFSCROLL_LATENCY`
- `MFSCROLL_CONTEXT`
- `MFSCROLL_TARGET`
- `MFSCROLL_DISPLAY`
- `MFSCROLL_TAP`
- effect-specific lifecycle records

### Required observability

Telemetry must make these questions answerable without inference from aggregate gaps:

- Was the physical value raw HID or CG fallback?
- Did input reach the model on time?
- What speed and decay were selected, and from which measured interval?
- Did a report preserve, add, cancel, or cap velocity?
- How much remaining area existed after the update?
- Was any carry discarded?
- Did a reset/generation change reject a late callback?
- Was a display recovery justified by stale callbacks?

## Replay and automated testing

### Trace format

Create sanitized fixtures under a dedicated test-data directory. Each fixture contains:

```text
metadata: device, source build, capture date, expected scenario
physical reports: timestamp, axis, signed raw units, CG line/point/fixed
session events: target/config/modifier/display/reset
display callbacks: timestamp/display, or a generated refresh schedule
expected invariants: first-output bound, sign, carry bound, terminal state
```

Do not require private application titles, pointer coordinates, or serial numbers in checked-in fixtures.

### Required captured fixtures

At minimum include representative traces for:

1. 2026-07-17 unknown-cadence delayed opening.
2. Sparse slow reports that previously burst.
3. Slow-to-fast acceleration with stale three-report cadence.
4. Active same-direction retarget.
5. Active reversal.
6. Paused slow reversal near `200–500 ms`.
7. Fast stop with same-direction settling report.
8. Fast stop with opposite rebound report.
9. Expired tail followed by genuine continuation.
10. Long-idle low-unit hardware ramp.
11. 2026-08-21 wrong-sign baseline followed by real opposite ramp.
12. 2026-09-01 same-sign long-idle baseline/real start false positive.
13. App/window target switch.
14. Display reconfiguration and callback-less cold start.
15. Horizontal Wheel/Pan input.

### Deterministic model tests

- First report uses bounded normal parameters.
- Second measured report may increase sparse overlap immediately.
- Current acceleration is not delayed by an interval smoother.
- Reversal produces no old-sign output after the reversing report is applied.
- Same-direction impulse preserves live velocity.
- Equivalent physical motion packetized as `1+1+1` versus `3` remains within an accepted output tolerance.
- Exact integration produces equivalent total output at 60, 120, and 144 Hz.
- Variable frame intervals do not change total response beyond integer quantization.
- Output velocity and remaining area respect independent caps.
- Reset clears velocity, cadence, direction, generation, and subpixels.
- A stale generation cannot emit.
- HID mismatch falls back without delaying or dropping the CG report.
- No NaN, infinity, negative time constant, sign inversion, or unbounded state for supported expert settings.

### Property/fuzz tests

Generate random timestamped signed-count sequences and assert:

- finite state after every report/frame;
- output sign equals current motion sign except for zero terminal/reset output;
- reversal cannot retain old-sign area;
- caps always hold;
- time never moves backward silently;
- duplicate/stale generation input is rejected deterministically;
- no state grows merely because display callbacks pause;
- packet aggregation changes do not create unbounded amplification.

## Physical regression matrix

Run the complete ledger matrix on the live TB800, not only the trigger symptom.

### Core motion

1. Fresh isolated slow report after short idle.
2. Fresh isolated slow report after at least 20 seconds idle.
3. Deliberately extremely slow repeated reports.
4. Ordinary slow-to-fast ramp.
5. Abrupt fast start.
6. Fast-to-slow gradual deceleration.
7. Hard spin and release.
8. Stop with captured same-direction settling.
9. Stop with captured opposite rebound.
10. Same-direction resume while output is live.
11. Same-direction resume after output stops.
12. Active reversal.
13. Slow reversal after short and boundary-length pauses.

### Routing and lifecycle

14. App switch.
15. Same-app window switch.
16. Content boundary and transient panel.
17. Mouse-down reset.
18. Live modifier/config change.
19. Helper/config reload.
20. Each attached display without moving the pointer first.
21. Display reconfiguration while idle and active.
22. Genuinely parked/callback-less display recovery.

### Compatibility

23. Horizontal scrolling.
24. Safari rubber-banding.
25. Chromium page and embedded/PDF content.
26. Telegram.
27. Finder.
28. VS Code and Xcode.
29. Control zoom and release.
30. Latched Scroll & Zoom / Zoom modes and exit.
31. Rotate, pinch, Dock swipe, and Command-Tab legacy effect paths.
32. System/Apple acceleration and non-Regular presets remain unaffected while migration is scoped to Regular.

## Quantitative acceptance gates

Exact tuning may change, but the following gates must be fixed before enabling ring-live by default:

### Responsiveness

- First nonzero output within one or two callbacks of the routed display.
- Scroll-queue time remains in the established healthy range and shows no new long-tail class.
- No physical report waits for HID correlation; fallback is immediate.
- Every accepted isolated report creates visible output under supported normal settings.

### Direction and state

- No old-sign pixel after the reversal update has reached the renderer.
- No output belonging to an old target/config/display generation.
- No phase-sensitive effect session left without a terminal event.

### Boundedness

- `abs(v) <= maximumOutputVelocity` after every update.
- `abs(v) * tau <= maximumRemainingDistance` after every update.
- Initial response is independently bounded.
- No discarded distance is stored for later replay.

### Consistency

- Equivalent raw count/time traces produce materially equivalent total output across packetization variants.
- Equivalent traces produce materially equivalent total output across 60/120/144 Hz schedules, within defined
  subpixel/integer tolerance.
- A one-unit physical start has no idle-dependent amplitude change unless raw HID supplies a proven distinct signal.
- Slow-to-fast input raises response on the first materially faster report.
- Established slow input has no report-three activation step.

### Liveness

- No unexplained `MFSCROLL_TAP` disable.
- Display recovery records occur only after measured stale callbacks.
- Callback-less cold-start retries end in a true stopped state.
- A later physical report can always cold-start after an aborted display session.

## Migration phases

### Phase 0 — freeze behavior and preserve evidence

Deliverables:

- Keep the current engine as the legacy baseline.
- Add this plan to the repository.
- Preserve the current dirty worktree; do not fold unrelated changes into rewrite commits.
- Snapshot/export the 2026-09-01 unified-log candidate into a sanitized replay fixture if still available.
- Record exact current config/defaults and helper build identity used for baseline comparisons.

Exit gate:

- The latest slow-start sequence and adjacent healthy start can be replayed or are fully transcribed with expected
  decisions.

### Phase 1 — raw HID observation only

Deliverables:

- `RingHIDSource` with non-seizing Wheel/Pan capture.
- `RingInputCorrelator` in telemetry-only mode.
- HID/CG timestamp, sign, magnitude, and device-identity telemetry.
- Reconnect/removal/overflow handling.
- No change to output behavior.

Required physical captures:

- normal slow and fast rotation;
- multi-unit aggregation;
- long idle then genuine isolated tick;
- long idle then amplified ramp;
- wrong-sign baseline if reproducible;
- fast stop and rebound;
- vertical and horizontal ring motion.

Exit gate:

- Raw/CG pairing reliability is measured, fallback behavior is proven, and the origin/distinguishability of baseline
  artifacts is documented.

Completed 2026-09-02: the current helper session paired 240/240 raw and CG reports with no overflow. A prior build
proved immediate CG fallback when the raw vertical polarity was incompatible. The corrected capture covered slow,
fast, multi-unit CG aggregation, stop/reversal, vertical, horizontal, and a 21-second-idle opposite baseline. The
baseline exists in the raw Wheel stream and is causally indistinguishable from a deliberate isolated count when it
arrives; the later opposite ramp cannot justify delaying the first report.

### Phase 2 — pure motion core and replay harness

Deliverables:

- Pure `RingMotionModel` with explicit units and analytic integration.
- Deterministic trace runner.
- Captured fixture suite and generated refresh schedules.
- Unit/property tests for response, direction, packetization, refresh independence, reset, and bounds.
- Initial parameter mapping from current UI settings.

Exit gate:

- All deterministic invariants pass, and no captured ledger trace exposes an unexplained sign, responsiveness, or
  unbounded-carry failure.

Completed 2026-09-02: the pure core, deterministic test suite, randomized boundedness checks, generated 60/120/144 Hz
and variable-refresh schedules, current-UI parameter mapping, and JSONL replay runner are implemented. Sanitized raw
fixtures cover sparse slow input, active and paused reversals, rebound-shaped resume, horizontal Pan, the long-idle
opposite baseline, and target resets. Replay now asserts immediate sign replacement on reversal, visible same-sign
first-frame output, reset clearing, and the remaining-area bound. All deterministic invariants pass. The older
ordinary healthy-start fixture remains a legacy-observation comparator because its historical record lacks physical
unit values; it is not counted as a model replay.

### Phase 3 — live shadow mode

Deliverables:

- Route every handled TB800 Regular report through both engines.
- Legacy output remains authoritative.
- Ring engine produces diagnostics only.
- Comparison records include first-frame prediction, velocity envelope, total output, stop time, reversal timing,
  and maximum remaining area.

Exit gate:

- Extended normal use covers the required core matrix without a new classifier proposal; discrepancies are explained
  by model/tuning rather than hidden state.

Progress 2026-09-02: runtime shadow routing, generation-ordered resets, immutable config/report snapshots, model and
comparison telemetry, and non-authoritative ownership are implemented. Automated tests and the full app build pass.
The first physical shadow capture retained 266/266 paired raw reports and 206 eligible model updates, including 18
atomic reversals and 12 horizontal reports; 61 consecutive reports belonged to Rotate/Zoom effect paths and correctly
remained legacy-only. It exposed a parameter-domain error rather than hidden runtime state: the initial acceleration
pivot was inherited from accelerated CG line units, while raw HID delivers one-count reports whose speed is encoded
by report interval. Slow response already matched, but legacy fast requested distance averaged 7.87x the shadow
impulse. The candidate mapping is now recalibrated around captured raw slow/free-spin rates (5/50 reports per second),
and comparison telemetry separates session-net output from current-direction output. The phase remains open for a
second physical capture, tuning review, additional displays, and the wider compatibility matrix. That second run
restored the raw-distance curve but exposed the next independent constraint: 129/278 updates hit the remaining-area
budget and the shadow envelope stopped near 8.2k px/s while legacy reached 15.7k px/s. The model now ramps toward a
35 ms decay above 20 raw reports/s, preserving retained area exactly as decay changes. This keeps the same bounded
post-stop area while allowing the explicit velocity ceiling to govern free-spin speed. A third shadow capture is the
current gate; ring-live remains disabled. The third run removed carry drops entirely and moved saturation to the
explicit velocity limit, but also exposed eight extremely sparse updates whose first 144 Hz two-callback area could
remain below one integer pixel. A final response-time bound now shortens only those tiny impulses enough to cross one
pixel within two 144 Hz callbacks without changing their total distance.

Completed 2026-09-02 after four physical shadow passes: the final sparse run paired 41/41 raw reports, applied the
response-time bound to 15 updates, and produced at least `1.000461 px` within two 144 Hz callbacks for every accepted
report. Across the full shadow campaign, slow/fast/sparse motion, active and paused reversals, target resets,
horizontal input, and effect exclusion exposed no unexplained hidden-state or classifier requirement. All captured
discrepancies were resolved as explicit raw-unit calibration, fast decay versus tail-area ownership, or integer-sink
responsiveness. Phase 3 is complete. Phase 4 may implement the vertical renderer behind a development selector;
legacy remains the default and immediate rollback path.

### Phase 4 — gated vertical live output

Scope:

- TB800 vendor/product match only.
- Regular custom-acceleration vertical path only.
- Existing output sink, target routing, display link, and resets.
- Legacy fallback switch remains available.

Deliverables:

- `ring-live` development selector.
- A/B capture procedure.
- Full vertical physical regression pass.
- Updated telemetry tooling/snapshot filters.

Implementation progress 2026-09-02:

- `RingScrollRenderer` owns `RingMotionModel`, signed subpixel state, real-frame analytic integration, stop decisions,
  generation rejection, cold-start retry/abort, parked-frame discard, and aggregate `MFSCROLL_RING_FRAME` telemetry on
  the existing `TouchAnimator` display-link queue. Sharing that queue serializes legacy cancellation, display rebinding,
  callback replacement, and fallback startup; there is never an intentionally concurrent second output producer.
- The live gate accepts only the exact correlated TB800, vertical axis, Low Inertia/Regular custom acceleration, and no
  effect modification. Horizontal, Apple acceleration, other devices, and effect paths reset live state and continue
  through the unchanged legacy path on the same report.
- Debug helpers read `MFRingScrollEngine` once at startup (`legacy`, `ring-shadow`, or `ring-live`). Missing/invalid
  values and all Release builds select `legacy`. `./dev.sh ring-engine MODE` manages the development value; a helper
  restart applies it.
- `ring_capture_analyzer.py` now separates legacy/ring-live latency, model bounds/rejects/reversals, frame cadence,
  parked/stall discards, and display/tap lifecycle failures. The HID source reports `role=observer` independently of
  output selection. Automated model/replay and full-build validation pass.

A/B progress 2026-09-02: the legacy physical baseline is preserved at
`/tmp/mac-trackball-fix-scroll-phase4-legacy.log`. It contains 390/390 paired vertical reports on display 3, both
directions, Browser/kitty target transitions, zero fallback/sign mismatch/overflow, `0.38–4.34 ms` queue time, and
`5.86–14.38 ms` first-output latency. All 54 display starts succeeded, with no tap disable or recovery. The Debug
helper has now been restarted with `selected=ring-live` as PID `54090`; the identical candidate matrix and the
telemetry-confirmed rollback remain open.

#### Phase 4 A/B capture procedure

Use the same app, window, display, pointer position, scroll settings, and test order for both runs. Change only the
startup engine selector.

1. Select the baseline with `./dev.sh ring-engine legacy`, run `./dev.sh run`, start `./dev.sh logs-record`, and
   exercise fresh short-idle and `>=20 s` starts, sparse slow input, slow-to-fast, abrupt fast, fast-to-slow, hard
   stop, same/opposite rebound, live/stopped continuation, active/paused reversal, target/window switches, and every
   attached display without first moving the pointer.
2. Refresh the recorder with `./dev.sh logs-record-snapshot`, copy the snapshot to a baseline filename outside the
   rolling path, and run `./dev.sh ring-capture-report BASELINE_FILE`.
3. Select the candidate with `./dev.sh ring-engine ring-live`, restart using `./dev.sh run`, and repeat the identical
   vertical matrix. Confirm the startup record says `selected=ring-live`; horizontal, zoom/rotate, Apple acceleration,
   and non-TB800 checks must continue to log/use legacy.
4. Snapshot and run `./dev.sh ring-capture-report CANDIDATE_FILE`. Compare input pairing/fallback, queue and
   first-output distributions, reversal count/sign, cap/drop totals, remaining area, active frame cadence/gaps,
   display recovery, and tap disable records alongside subjective control.
5. Immediate rollback is `./dev.sh ring-engine legacy` followed by `./dev.sh run`. Verify the next startup selection
   record says `selected=legacy` before treating rollback as tested.

Do not advance the phase from implementation-complete to accepted until the candidate passes the full vertical
physical matrix and the rollback restart has been observed in telemetry.

Completed 2026-09-02: helper PID `54090` completed the live physical pass with 301/301 paired reports, including
275 vertical and 26 horizontal reports, both directions, slow/fast/sparse motion, 10 atomic reversals, a long-idle
start, Browser/kitty/Safari target changes, and three zoom sessions. The 240 eligible vertical reports used
`ring-live`; the remaining 61 reports used the legacy fallback, accounting for every physical input without overlap.
Live first output had `4.82 ms` median and `11.87 ms` p95 latency, queue time averaged `1.04 ms`, and all 3,040
renderer callbacks ran at `120 Hz` with an `8.333 ms` maximum frame gap. There were no correlation failures, model
rejects, carry drops, parked/stall discards, failed display starts, recoveries, or tap disables. The explicit velocity
limit handled 24 fast reports while retained area remained at or below `582.195 px`. No subjective failure was
reported when the physical pass was completed.

Rollback is also complete: the next successful Debug helper startup, PID `56505` at `22:39:23.159`, recorded
`requested=legacy selected=legacy`. The exact candidate capture is preserved at
`/tmp/mac-trackball-fix-scroll-phase4-ring-live.log`, the legacy capture remains at
`/tmp/mac-trackball-fix-scroll-phase4-legacy.log`, the full automated scroll matrix passes, and Phase 4 is complete.
Only runtime display `3` was available; another physical display must still be checked if one is attached later.

Exit gate:

- Quantitative gates and subjective feel pass across fresh, sparse, fast, stopped, reversed, long-idle, target, and
  multi-display cases.

### Phase 5 — horizontal and compatibility expansion

Deliverables:

- Raw Pan/horizontal integration.
- Safari/Chromium/Telegram/Finder/VS Code/Xcode passes.
- System acceleration and non-Regular paths verified unchanged.
- Zoom/effect paths explicitly verified through the legacy TouchAnimator lifecycle.

Implementation progress 2026-09-03:

- `ring-live` now accepts the exact TB800 Consumer Pan axis in addition to Wheel. The renderer carries an explicit
  vertical/horizontal axis through model, frame, latency, and output ownership; positive canonical motion maps to
  up/right and negative motion maps to down/left through the unchanged two-axis continuous-wheel sink.
- Initial implementation treated axis as session identity and reset on every vertical/horizontal transition.
  Physical telemetry on 2026-09-04 rejected that assumption: the device has separate Wheel and Consumer Pan
  controls, and released Wheel packets can overlap new Pan packets. The renderer now owns one bounded model and
  subpixel accumulator per physical axis under one target/config generation, one DisplayLink, and one event sink.
  Axis reports never reset the other axis; same-axis reversal remains atomic and resets only that axis's subpixels.
  Point and line subpixel bias are reset selectively for the reversed axis. When both axes produce pixels on a
  callback, they are combined into one phase-less two-axis wheel event.
- Exact-TB800 reports now emit `MFSCROLL_RING_ROUTE action=live|fallback`. Fallback reasons distinguish effect,
  System acceleration, non-Regular curve, display, timestamp, and model/config exclusions. Capture analyzer schema
  v3 reports live model/route/frame counts plus first-output and queue distributions by axis, and verifies observed
  System/non-Regular/effect fallback coverage.
- The startup selector remains Debug-only and immutable. Release and missing/invalid values still select legacy;
  zoom, rotate, other effects, System acceleration, non-Regular curves, other devices, and correlation failure still
  enter the existing legacy path on the current report.

The first gated candidate was deployed as helper PID `66968`, whose startup record says
`selected=ring-live verticalOnly=0 horizontalPan=1`. Its physical capture preserved at
`/tmp/mac-trackball-fix-scroll-phase5-axis-stutter.log` contains 248/248 paired reports and healthy queue/display
telemetry, but also proves the reset design was wrong: at `09:08:21.578–.657`, reports interleaved
`vertical -> horizontal -> vertical -> horizontal -> vertical`, producing four `reason=axis-change` generation
resets and repeated display-link restarts. The two-axis ownership correction passes the automated regression suite,
including a pure interleaved-axis test, analyzer schema v4, Xcode project validation, shell validation,
`git diff --check`, and the full Debug build. Phase 5 remains open for physical acceptance of the replacement build.
The first deployment attempt encountered the repository's known no-active-display `CVDisplayLink` startup assertion
before renderer initialization; the launchd crash loop was stopped, and the built candidate remains ready to restart
when macOS enumerates a display.

Physical overlap progress 2026-09-04: helper PID `29474` selected the exact `ring-live` build with
`independentAxes=1` and captured 126/126 paired reports (96 vertical, 30 horizontal) with zero fallback, sign
mismatch, overflow, model rejection, carry drop, display recovery/start failure, or tap disable. Interleaved runs
retained one generation with zero `reason=axis-change` resets; 11 renderer windows emitted mixed-axis output at
120 Hz with an 8.333 ms maximum callback gap. Six horizontal and five vertical reversals remained same-update and
axis-local. The capture is preserved at `/tmp/mac-trackball-fix-scroll-phase5-independent-axes.log`. This closes the
specific axis-reset/stutter regression in telemetry, but Phase 5 remains open for explicit subjective acceptance,
compatibility fallbacks/effects, the wider application matrix, and every additionally available display.

Stopped-opening response progress 2026-09-04: telemetry separated a reported slow start from delivery latency.
Pre-fix sequence `2020` reached the queue in `1.107 ms` and produced its first integer pixel in `9.02 ms`, but spread
an isolated `11.347 px` count over `150.543 ms` after output had stopped. The initial correction raised only the
response rate needed to expose `2 px` in the existing visibility window when both pre-report velocity and retained
distance were effectively exhausted; live sparse responses retained the prior `1 px` rule and total distance was
unchanged. Helper PID `83100` physically exercised four such openings with healthy HID/CG pairing, queue latency,
`120 Hz` callbacks, and no renderer/tap/display failure. The post-fix capture is preserved at
`/tmp/mac-trackball-fix-scroll-phase5-stopped-opening-fix.log`; the full automated matrix and Debug build pass.
Subjective acceptance and the remaining compatibility matrix are still open.

Nearly-exhausted-tail progress 2026-09-05: recent helper PID `83100` sequence `4766` reached first output in
`1.18 ms` with `0.729 ms` queued, but spread an `18.267 px` report over `145.229 ms`. Only about `0.648 px` of old
motion remained, yet its short tau represented that subpixel area as `8.831 px/s`, causing the old combined
remaining-area/velocity predicate to misclassify the visibly fresh report as live. Stopped-output classification now
uses the one-pixel visible-area floor alone; the existing two-pixel response cap then limits this captured shape to
approximately `119.776 ms` without adding distance. The full automated matrix and Debug build pass, and helper PID
`5399` is deployed with ring-live selected. A physical recurrence and subjective verdict remain pending.

Stopped-opening tuning progress 2026-09-05: helper PID `5399` physically confirmed the nearly-exhausted classifier
on sequence `1071`, but sequence `1085` still made the accepted two-pixel floor feel weak: after a `4.800 s` stopped
pause it mapped one count to only `8.142 px` over `49.268 ms`, then accelerated to a `145.268 px` report `41.979 ms`
later. Delivery remained healthy at `7.24 ms` total and `0.670 ms` queued. The stopped-only visibility floor is now
`3 px`, reducing that exact response to approximately `30.220 ms` without adding distance; live sparse motion stays
on the one-pixel rule. The full automated matrix and Debug build pass. Helper PID `33989` then physically captured
47/47 paired reports, including two `8.142 px` stopped one-count openings at `30.218 ms`, with healthy latency,
120 Hz callbacks, and no model/display/tap failure. The preserved capture is
`/tmp/mac-trackball-fix-scroll-phase5-three-pixel-stopped-opening-2026-09-05.log`; subjective acceptance remains
pending.

Stopped-opening amplitude progress 2026-09-05: on the physically verified three-pixel build, helper PID `33989`
sequence `194` was correctly classified and reached output in `13.19 ms`, but a `1.106 reports/s` opening still
mapped to only `8.924 px` before sequence `195` jumped to `131.121 px` after `46.988 ms`. A stopped-only distance
mapping floor of `1.5 reports/s` now raises that shape to approximately `12.1 px`; it does not change measured
raw/filtered speed or apply over visible motion. This is intentionally far below the rejected unconditional
`32–35 px` opening because the wrong-sign long-idle baseline remains indistinguishable. The full automated matrix,
`git diff --check`, and Debug build pass. Deployed helper PID `46699` physically exercised three floored openings:
each logged raw/filtered omega `1.000`, distance omega `1.500`, `11.769 px`, healthy queue/first-output timing, and no
model/display/tap failure across 24/24 paired reports. Captures are preserved at
`/tmp/mac-trackball-fix-scroll-phase5-amplitude-notch-2026-09-05-2318.log` and
`/tmp/mac-trackball-fix-scroll-phase5-stopped-amplitude-floor-2026-09-05.log`; subjective acceptance remains open.

Stopped-opening invariant progress 2026-09-06: helper PID `46699` proved the recent threshold strategy incomplete.
Reset openings began at `439.419 px/s`, while non-first stopped openings clustered around `233–255 px/s`; 13
distance-floor and 19 three-pixel-cap activations did not prevent recurrence. Sequence `1329` exposed the threshold
gap directly: its stopped `17.719 px` reversal naturally cleared three pixels and exceeded `1.5 reports/s`, yet
opened at only `249.961 px/s` before the next packet jumped to `2,346 px/s`. The `1.5 reports/s` distance floor has
therefore been removed. Every visually stopped non-first report now retains its honest raw-derived distance but caps
decay to the normal first-report opening velocity. The full automated matrix, `git diff --check`, and Debug build
pass. Deployed helper PID `19326` physically exercised three stopped openings across raw omega `1.362–2.907`; their
distances remained `10.784–21.473 px`, all opened at `439.419 px/s`, first output stayed `6.45–11.51 ms`, and 32/32
reports had healthy model/display/tap telemetry. Captures are preserved at
`/tmp/mac-trackball-fix-scroll-phase5-recurrent-opening-velocity-notch-2026-09-06.log` and
`/tmp/mac-trackball-fix-scroll-phase5-opening-velocity-invariant-2026-09-06.log`; subjective acceptance remains
open.

Direction-aware opening progress 2026-09-06: the next retained helper PID `19326` window verified healthy transport
and 24 activations of the stopped-opening velocity invariant, but sequence `2842` exposed one remaining semantic
escape. A reversal after `363.983 ms` had about `1.026 px` of old-sign area, barely above the fixed one-pixel visible
floor, so it was classified live and opened the new sign at only `287.783 px/s`. Atomic reversal discarded all of
that old-sign area on the same update; it could not provide any new-direction continuity. Stopped-output
classification is now direction-aware: every direction change is a fresh opening regardless of discarded old-sign
residue, and therefore receives the same minimum opening-velocity invariant without added distance. Exact replay
preserves the captured `20.400 px`, zero carry, and immediate sign replacement while raising its opening to the
normal `439.419 px/s` envelope. The full automated matrix, `git diff --check`, and Debug build pass. Deployed helper
PID `15664` then captured 34/34 paired reports with healthy 120 Hz output and no model/display/tap failure.
Reversals `7` and `23` arrived with roughly `4–5 px` of old-sign area, discarded it, logged both direction-aware
opening flags, and opened at exactly `439.419 px/s`; reversal `14` naturally exceeded the floor. The physical trace
is preserved at `/tmp/mac-trackball-fix-scroll-phase5-direction-aware-opening-2026-09-06.log`; subjective acceptance
and the remaining Phase 5 matrix stay open.

#### Phase 5 physical acceptance procedure

1. On native Pan, exercise both horizontal directions: isolated slow counts, repeated sparse motion, slow-to-fast,
   hard free-spin, fast-to-slow, hard stop, active reversal, and paused reversal. Confirm output is horizontal and
   the analyzer reports horizontal live routes, model updates, nonzero frame events, normal latency, and no rejects.
2. Release vertical and begin horizontal while the vertical hardware tail is still reporting; repeat horizontal to
   vertical. Interleaved axis reports must retain one generation, produce zero `reason=axis-change` resets, keep
   independent cadence/velocity/subpixel state, and avoid display-link stop/start churn. When both axes still have
   visible motion, frame telemetry may report `axis=mixed` and must account for each component. Reverse each ring
   during overlap and verify that only the reversed axis cancels its old sign.
3. In Safari and Chromium, test ordinary content, top/bottom boundaries, horizontal overflow, and rubber-banding or
   equivalent boundary behavior. Repeat representative vertical/horizontal motion in Telegram, Finder, VS Code,
   and Xcode, including a target/window switch while a tail is active.
4. Select System speed and exercise both axes; then exercise available non-Regular input modes. These reports must
   log `action=fallback` with `reason=system-acceleration` or `reason=non-regular`, and remain controlled by the
   legacy animator without a concurrent ring frame stream.
5. Exercise Ctrl zoom, latched zoom, rotate, horizontal modifier, Command-Tab, and available gesture effects.
   Effects must log `reason=effect`, retain the legacy `TouchAnimator` lifecycle, and send their required terminal
   phase before the next ordinary live report. In particular, Ctrl release must end zoom before ordinary scrolling.
6. Repeat fixed-pointer starts on every attached display. Snapshot the recorder and run
   `./dev.sh ring-capture-report`; inspect axis accounting, fallback reasons, first-output/queue distributions,
   frame gaps, direction changes, retained-area/carry bounds, display recovery, and tap state.
7. Before Phase 6, perform a telemetry-confirmed restart with `legacy`, then redeploy this exact Phase 5 build with
   `ring-live` only if the default-switch monitoring candidate is being started.

Exit gate:

- Complete ledger regression matrix passes on the exact build proposed for default enablement.

### Phase 6 — default switch and legacy retirement

Deliverables:

- Make ring engine the default for the verified TB800 Regular path.
- Keep runtime legacy fallback for one monitoring cycle.
- Append a full dated ledger entry with symptom, raw evidence, architecture, verification, and tradeoffs.
- After the monitoring cycle, remove obsolete Regular-only policy and animation code.

Candidate removal inventory after acceptance:

- Regular-path use of per-report HybridCurve construction.
- Regular-path retained target distance/carry recomposition.
- Regular-path dependence on `ScrollAnalyzer` gesture/swipe counters.
- idle-wake response shaping and baseline distance classifier;
- fast/settling/sharp-tail intent classifiers that raw evidence does not justify;
- stopped/remembered cadence opening caps;
- point-amplification response guards;
- legacy cadence policy helpers and tests superseded by model/replay tests;
- obsolete state variables and tuning constants.

Do not remove shared TouchAnimator, gesture-effect, DisplayLink, or output compatibility code merely because Regular
scrolling stops using it.

Exit gate:

- One monitoring cycle contains no unexplained slow-start, stuck, reversal, after-burst, target leak, or liveness
  regression, and rollback remains tested before final cleanup.

## Commit and review strategy

Keep changes reviewable and reversible:

1. Plan and trace schema.
2. HID observation/correlation with no behavior change.
3. Pure model and tests.
4. Shadow integration.
5. Gated vertical live output.
6. Horizontal/compatibility expansion.
7. Default switch.
8. Legacy cleanup after monitoring.

Each behavior-changing commit must:

- cite the exact trace/test it changes;
- state which ledger invariants it preserves;
- run deterministic suites and the relevant physical matrix;
- append rather than rewrite the regression ledger;
- avoid combining unrelated config, UI, or effect changes;
- include a rollback path until the monitoring gate closes.

## Risks and mitigations

### HID/CG correlation mismatch

Risk: raw samples and CGEvents may aggregate differently or timestamps may not pair reliably.

Mitigation: measure before depending on pairing, correlate by device/axis/sign/time/value, consume samples once, use
fixed capacity, and fall back immediately to CG line units.

### Raw HID access changes across macOS versions

Risk: permissions or DriverKit behavior may prevent passive values.

Mitigation: treat raw HID as preferred rather than mandatory, retain CG line fallback, and expose source in every
input record.

### Exponential impulse tuning feels too floaty

Risk: a long `tau` can recreate a software tail.

Mitigation: make `tau` speed-adaptive, bound remaining area, keep fast `tau` short, and validate stop time separately
from smooth sparse overlap.

### Sparse output still pulses

Risk: `tau` shorter than the physical count interval reveals quantization.

Mitigation: establish cadence from report two, raise sparse overlap continuously with confidence, and test real
extremely slow rotation rather than a synthetic fixed event rate alone.

### A small artifact remains visible

Risk: hardware artifact and genuine input are identical.

Mitigation: acknowledge the information limit, use one consistent low-speed response, avoid delayed intent inference,
and document the product tradeoff.

### Application compatibility regresses

Risk: motion changes accidentally alter event fields/phases/routing.

Mitigation: reuse the existing output sink unchanged for initial migration and test applications/content boundaries
as a separate gate.

### Rewrite becomes another layered engine

Risk: shadow/legacy compatibility code survives indefinitely and complexity increases.

Mitigation: define the removal inventory and monitoring gate now; do not add new symptom flags to the pure model;
finish Phase 6 before declaring the rewrite complete.

## Definition of done

The rewrite is complete only when all of the following are true:

- Raw HID behavior and CG fallback are characterized and observable.
- The Regular TB800 path uses the continuous ring model, not per-report finite curves.
- There is one bounded velocity/cadence state per independent physical ring, owned by one renderer and frame clock,
  with no delayed target-distance reservoir.
- The current and historical slow-start traces pass replay and physical checks.
- The entire required regression matrix passes on the deployed build.
- First output, queue time, active cadence, direction, remaining carry, display liveness, and target generation are
  all confirmed in telemetry.
- No report-count confirmation, quarantine timer, delayed replay, or unbounded carry exists.
- Zoom/effect terminal phases and ordinary phase-less output compatibility remain intact.
- The regression ledger contains an evidence-backed final entry.
- Obsolete Regular-path policy/animation code is removed after the monitoring cycle.
- The runtime fallback has been tested before it is eventually retired.
