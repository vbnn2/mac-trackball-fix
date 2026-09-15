# Scroll regression ledger

This is the canonical history and regression contract for the fork's TB800 scroll engine. Read it before changing
scroll input, analysis, animation, output events, display-link scheduling, or scroll tuning.

Older references:

- [`ScrollNotes.md`](ScrollNotes.md)
- [`Bug Log [Aug 2025] - Scroll Stopped Working.md`](Bug%20Log%20%5BAug%202025%5D%20-%20Scroll%20Stopped%20Working.md)
- [`../../../DEVELOPING.md`](../../../DEVELOPING.md)
- [`../../../PLAN.md`](../../../PLAN.md)

## Non-negotiable behavior

- A new physical report must be handled immediately. Never hold it behind a timer or an event-count confirmation gate.
- A new event must be able to accelerate or retarget an active glide immediately and without discarding its current
  velocity.
- Direction reversal must cancel old-direction motion immediately and still process the report that requested the
  reversal.
- The first report has no measured cadence. It must use a bounded normal-smoothness start, not maximum slow
  smoothness. Slow smoothing may begin with the second measured report.
- Extremely slow input should form continuous motion across sparse reports. Acceleration must invalidate remembered
  slow cadence on the same report.
- Mechanical settling protection must be narrow, one-shot, and non-deferred. It must not mutate analyzer history
  before a report is accepted.
- An animator's requested-running state is not proof that display callbacks are alive.
- Animated sessions must send their terminal phase. Do not strand an application in a synthetic gesture session.
- App changes, modifier/config changes, mouse-down resets, and display changes must not carry stale animation state
  into the next target.
- Keep maximum output rate, initial distance, and retained carry separately bounded. Do not create a delayed distance
  reservoir.

## Reading the telemetry

The rolling capture is `/tmp/mac-trackball-fix-scroll.log`; active data first lands in numbered `.segment.*` files.

```bash
./dev.sh logs-record
./dev.sh logs-record-snapshot
./dev.sh logs-record-stop
```

Important records:

| Record | Meaning |
|---|---|
| `MFSCROLL_INPUT cont=0` | Physical wheel report entering the engine |
| `MFSCROLL_INPUT cont=1` | Unmarked continuous input; MMF's own marked output now bypasses tap decoding/telemetry |
| `MFSCROLL_LATENCY` | Physical input to first animated output and time queued before processing |
| `MFSCROLL_LEGACY` | Input speed, mapped distance, retained distance, target velocity, duration, and adaptive state |
| `MFSCROLL_OUTPUT` | Aggregated nonzero output cadence; its window can span cancellation or idle time |
| `MFSCROLL_ADAPTIVE` | Unknown, measured, or remembered slow cadence decision |
| `MFSCROLL_TAIL` | One-shot mechanical-settling treatment |
| `MFSCROLL_CONTEXT` | Target app, display, pointer movement, and requested animator state |
| `MFSCROLL_DISPLAY` | Display binding, start, callback resumption, or stalled-link recovery |
| `MFSCROLL_TAP` | Event-tap disable/re-enable state |

Do not diagnose a display stall from `MFSCROLL_OUTPUT.maxGapMs` alone. That metric counts nonzero integer output and
can span idle time, pixel quantization, cancellation, or a restarted animation. Correlate physical input, latency,
display, and output records using the same helper PID.

## Regression history

### 2026-07-17 — delayed first movement

Symptom: a fresh slow scroll felt delayed by hundreds of milliseconds.

Evidence/root cause: the first report has no cadence measurement, but the adaptive path treated that unknown cadence
as zero speed and selected maximum Slow Smoothness.

Fix (`40f3430ed`): an unknown first cadence uses normal smoothness and a bounded start. The second report supplies a
real interval and may select slow smoothing.

Guardrail: do not infer "extremely slow" from missing timing data.

### 2026-07-19 to 2026-07-20 — sparse reports produced bursts

Symptom: very slow movement felt like separate position bursts, while faster follow-up input did not blend into the
glide naturally.

Root cause: a display-synchronized target follower drained each sparse report before the next arrived, and the
legacy retarget path could replace current output velocity with a new finite curve's average velocity.

Fixes (`cc23e028a`, `5034320d8`):

- Removed the second target/reservoir animation pipeline.
- Kept one TouchAnimator lifecycle.
- Added short velocity-preserving retarget transitions.
- Kept incoming input able to replan duration and target speed immediately.

Rejected approach: do not restore a distance reservoir or second smoothing lifecycle merely because its frame output
looks regular in isolation. It caused visible input-rate bursts and made reset/reversal/display state harder to keep
consistent.

### 2026-07-21 to 2026-07-22 — slow smoothing began on event three

Symptom: careful scrolling used normal smoothing for the first two reports and visibly switched to Slow Smoothness on
the third.

Root cause: `stableSlowSmoothingConfirmationReports` added a report-count gate on top of the time-aware velocity
filter.

Fix (`769ef3917`): removed the three-report confirmation counter. The second report's measured cadence directly
controls adaptive smoothing. Added separate slow-cadence memory so sparse slow reports, including a small reversal,
can overlap visually. Faster/larger input clears that memory immediately.

Guardrail: filter in continuous time; do not add responsiveness gates based on a fixed number of reports.

### 2026-07-22 — reversal did not inherit slow glide

Symptom: a fresh slow direction worked, but changing direction became abrupt or waited for later reports.

Root cause: gesture grouping and cadence memory were coupled to direction, while old-direction animation state could
survive long enough to interfere with the new direction.

Fix (`769ef3917` and preceding reversal fixes):

- Preserve slow cadence as scalar timing information across a small, slow reversal.
- Cancel the old animator immediately.
- Continue processing the first opposite report.
- Reset stale phase state even when output velocity is already near zero.

Guardrail: never return after cancelling a direction change if that would discard the current physical report.

### 2026-07-22 — stop produced a same- or opposite-direction after-burst

Symptom: after a fast scroll decelerated, one late hardware report could start a short second burst. Sometimes the
late report was opposite direction.

Evidence: captures showed one-unit/one-point reports roughly 150–320 ms after fast motion. Timing and magnitude
overlapped with a legitimate isolated slow reversal.

Fix (`769ef3917`):

- Arm a one-shot settling guard only after genuinely fast input.
- A same-direction candidate leaves a running glide untouched; if no glide remains, it emits at most one raw pixel.
- An opposite candidate cancels old motion and emits one raw pixel.
- Disarm immediately. Never release the report later and never wait for confirmation.

Known tradeoff: a legitimate isolated one-unit reversal is indistinguishable from mechanical rebound. The guard can
make that isolated action feel too small. At `11:51:08.420`, a physical one-unit reversal was classified as
`bounded-reversal`, emitted `1px` at `11:51:08.422`, and no second physical report arrived. That was amplitude
suppression, not processing latency. Do not "fix" it by adding a quarantine timer; that recreates a dead zone.

### 2026-07-23 — apparent delays were not queue delays

Reported symptom: scrolling sometimes felt delayed or stuck during slow starts and reversals.

Captured healthy latency:

- Input to first output: approximately `14.8–24.7 ms`
- Scroll-queue time: approximately `0.5–3.1 ms`
- Active output: normally about `60 Hz`, with `17–18 ms` frame gaps

Conclusion: when these values are healthy, investigate classification, output amplitude, display callbacks, or target
application state instead of adding queue/smoothing workarounds.

### 2026-07-23 — scrolling remained stuck until mouse movement

Symptom: wheel input could retarget scrolling without visible output; moving the mouse made it resume.

Evidence: the code defined `isRunning` as the requested display-link state. A `CVDisplayLink` could therefore stop
delivering callbacks while the animator still appeared running. New input retargeted that zombie animator instead of
calling the cold-start path. Existing comments and the observed mouse-dependent recovery both pointed to a parked
display/compositor callback as the failure mode.

Fix (working tree after `769ef3917`):

- Track callback time and requested-start time in `DisplayLink`.
- On new TouchAnimator input, treat a requested-running link with no callback for more than `100 ms` as stalled.
- End the stale synthetic phase, clear old velocity/subpixel state, stop the underlying link, and use the ordinary
  cold-start path for the same new input.
- Emit `MFSCROLL_DISPLAY action=recover-stall` and `action=animator-cold-restart` when recovery occurs.

Responsiveness property: healthy links take the unchanged path. Recovery is driven by the new wheel report; it does
not wait for mouse movement or a confirmation timer.

Verification: `git diff --check` and `./dev.sh build` passed; the app/helper was restarted and the rolling recorder
continued on the new helper. Normal post-restart scroll output remained display-paced.

### 2026-07-23 — one-pixel rebound protection looked like input delay

Symptom: the first report of a direction change appeared to do nothing; scrolling began with a later report.

Evidence from helper PID `82103`:

- `16:18:34.659`: one-unit reversal was bounded to `1px`; the next physical report arrived `79 ms` later.
- `16:21:22.136`: one-unit reversal was bounded to `1px`; the next physical report arrived `55 ms` later.
- `16:21:22.930`: one-unit reversal was bounded to `1px`; the next physical report arrived `39 ms` later.
- Normal starts in the same capture had `11.6–28.3 ms` input-to-output latency and mostly sub-`2 ms` queue time.
- No `recover-stall`, `animator-cold-restart`, tap-disable, or display-start failure occurred.

Root cause: the settling guard handled the first report on time, but its single output pixel was effectively
invisible. The wait for the next hardware report therefore felt like processing delay.

Fix:

- Replace the one-pixel response with a `50 ms` ease-out micro-glide.
- Scale it from `10px` when old motion has stopped down to `4px` while old motion is still active.
- Keep it outside ScrollAnalyzer so possible rebound does not alter cadence/direction history.
- Cancel old-direction motion before an opposite micro-glide.
- Disarm the guard immediately. A following report cancels or retargets TouchAnimator without waiting.
- Log the path as `MFSCROLL_TAIL action=micro-reversal|micro-same` and tag first-output latency with
  `path=settling-micro-glide`.

Verification: `git diff --check` and `./dev.sh build` passed. `./dev.sh run` restarted the app/helper; fresh helper
PID `47507` started its display link successfully and delivered the first observed scroll output in `12.25 ms` with
`0.54 ms` input queue time. No stall-recovery or display-start-failure marker appeared. A physical tail/reversal test
is still required to confirm the new `micro-reversal` path by feel and telemetry.

Preserved tradeoff: mechanical rebound and a legitimate isolated one-unit reversal remain indistinguishable. The
response is intentionally much smaller than the normal approximately `46px` accelerated first tick, but it is now
visible and smoothly distributed rather than appearing dead.

### 2026-07-23 — a parked cold start still depended on mouse movement

Symptom: an isolated scroll could remain stuck until the pointer moved, despite the new-input stalled-link recovery.

Evidence and diagnosis:

- Helper PID `47507` was healthy during the captured `16:38–16:40` tests: fixed-pointer starts produced output in
  approximately `12–29 ms`, and there was no tap disable, display-start failure, or stalled-link recovery marker.
- The reported freeze itself was therefore not directly captured.
- Code inspection found a remaining liveness gap: `invalidateIfStalled_Unsafe` ran only from `TouchAnimator.start`.
  It could recover an old requested-running link when another wheel report arrived, but it could not recover a
  newly cold-started link that accepted `CVDisplayLinkStart` and then produced no first callback. With no second
  physical report, mouse movement could wake CoreVideo before any recovery code ran.

Fix:

- Arm a generation-scoped watchdog only for a real cold start.
- After `110 ms`, if the same animation is still requested-running and has not received its first callback, stop and
  restart its display link while preserving the original animation distance and cold-start timing state.
- Retry at most three times. Normal callbacks make the watchdog a no-op; retargeting an already-live animation does
  not rearm it or postpone recovery.
- Log autonomous recovery as `MFSCROLL_DISPLAY action=watchdog-cold-restart`.

Responsiveness property: the original report still starts immediately. The watchdog is recovery, not a confirmation
gate, and it does not wait for another wheel event or mouse movement.

Verification: `git diff --check`, `./dev.sh build`, and `./dev.sh run` passed. On the restarted helper PID `54018`,
two fixed-pointer cold starts at `16:43:05.707` and `16:43:05.748` produced their first output in `15.00 ms` and
`24.04 ms`, with `0.57 ms` and `0.71 ms` queue time. The watchdog correctly stayed silent because normal callbacks
arrived. No recovery or display-start-failure marker appeared. A naturally parked display is still needed to observe
the autonomous `watchdog-cold-restart` path directly.

### 2026-07-23 — switching windows could retain the previous window's scroll session

Symptom: the first scroll after switching windows could feel delayed or unusually slow.

Evidence:

- In helper PID `79346`, the captured Arc-to-Telegram switch at `22:21:56.676` was not a queue or display stall.
  The first report reached output in `13.14 ms` with `1.58 ms` queued; the first opposite report `22 ms` later reached
  output in `14.14 ms` with `0.48 ms` queued. There was no tap disable, display recovery, or start failure.
- That capture did show only an application bundle in `MFSCROLL_CONTEXT`. Code reset on a bundle-ID change or a
  mouse-down, but a keyboard-driven switch between two windows of the same application changed neither. The exact
  same-app failure was not identifiable in old telemetry because no window identity was recorded; attributing the
  reported feeling to retained same-app window state is therefore a code-supported inference, not a captured
  reproduction.
- Direct testing on macOS 26 found both `kCGMouseEventWindowUnderMousePointer*` fields were zero on physical TB800
  HID-tap reports. The existing `NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:` WindowServer lookup took
  about `37 us` per call over 1,000 calls and resolved the live Arc target as window `1387`.

Fix (`Helper/Core/Scroll/Scroll.m`):

- Resolve the routed window ID for every handled physical report, using the event field when available and the
  measured non-AX point lookup when the HID event leaves it zero.
- Compare the window ID before analyzer classification. A real change ends the old synthetic phase and clears
  animator, cadence, tail, and analyzer state, then processes the same physical report normally.
- Add `window=` to `MFSCROLL_INPUT` and `MFSCROLL_CONTEXT`, and log the transition as
  `MFSCROLL_TARGET: window-change ... action=reset-session`.
- Keep bundle-ID and mouse-down resets as fallbacks. Do not defer or discard the first report.

Verification:

- `git diff --check` and `./dev.sh build` passed. `./dev.sh run` rebuilt and restarted the helper.
- On restarted helper PID `89177`, physical reports recorded `window=1387`. Fresh starts produced first output in
  `8.03 ms` with `0.48 ms` queued; an active-motion settling reversal produced its micro-glide in `6.84 ms` with
  `0.49 ms` queued.
- A controlled VS Code-to-Arc transition produced
  `MFSCROLL_TARGET: window-change app=com.microsoft.VSCode->company.thebrowser.Browser window=1470->1387` at
  `22:29:30.834`. The same report then used unknown-cadence normal smoothness and produced output in `17.69 ms`
  with `1.32 ms` queued.
- Existing live slow-to-fast input continued to retarget on each report. No display recovery, display-start failure,
  or event-tap timeout occurred. The one `MFSCROLL_TAP reason=user-input` marker accompanied helper restart and was
  re-enabled as requested.

Remaining tradeoff: target identity is the frontmost hittable window at the pointer. Transient panels legitimately
have their own window IDs and will start a clean session when they become the scroll target. A manual Command-backtick
same-app switch is still required to confirm the new `window-change` marker and feel in the originally reported case.

### 2026-07-24 — a resumed downward scroll was mistaken for a settling reversal

Symptom: scrolling down after a fast gesture could move briefly, snap back a little, then continue down.

Evidence from helper PID `82864`:

- At `12:54:02.499`, the first physical downward report was one line/one point (`line=(-1,0)`, `point=(-1,0)`) and
  reached the scroll queue in `0.42 ms`.
- At `12:54:02.501`, the broad settling guard classified it as
  `MFSCROLL_TAIL action=micro-reversal`, cancelled the old direction, and injected a `9px`, `50 ms` opposite glide.
  Its first output arrived in `3.02 ms`, so this was not a queue, display-link, target-window, or event-tap delay.
- A physical continuation in that same direction arrived `50 ms` later (`point=(-7,0)`), then larger same-direction
  reports at `40 ms` and `49 ms`. Those reports took the ordinary path and first output arrived in `11.09 ms` with
  `0.59 ms` queued. This proves the first report was the start of resumed input, not an isolated rebound.
- The recorder also contained reversal candidates at `265 ms`, `376 ms`, `484 ms`, and `708 ms` after fast input.
  The existing evidence for actual mechanical settling is only `150–320 ms`; the former `800 ms` window admitted
  clearly later resumed input.

Root cause: the one-shot guard's `800 ms` eligibility window exceeded the measured mechanical-rebound interval. It
therefore applied a deliberately bounded reversal response to a real new scroll start, creating the visible snap.

Fix (`Helper/Core/Config/ScrollConfig.swift`): restrict `stableSettlingTailWindowMax` to `320 ms`. A one-unit tail in
the observed rebound interval remains non-deferred and outside `ScrollAnalyzer`; a later report disarms the guard and
is processed immediately by the regular direction-change path, which cancels old motion while delivering that same
physical report.

Verification:

- `git diff --check` passed; `./dev.sh build` and `./dev.sh run` succeeded, and restarted helper PID `2553`
  re-enabled its event tap.
- Captured-regression replay preserves the `265 ms` in-window rebound candidate and routes the `376 ms`, `484 ms`,
  and `708 ms` candidates to normal input processing. This covers the stop-after-fast and late/resumed-reversal
  branches without adding a confirmation delay or altering analyzer history for an actual rebound.
- A fresh physical-device pass of the full matrix is still required after deployment: stop after fast motion,
  hardware rebound, active-motion reversal, slow reversal after a pause, and a normal slow-to-fast sequence.

Remaining tradeoff: a real rebound that arrives after `320 ms` will receive normal first-report amplitude rather than
the micro-glide. This is preferable to suppressing a deliberate resumed scroll, and the guard still never defers or
discards an input report.

### 2026-07-24 — display reconfiguration could leave a stale link until watchdog recovery

Symptom: a scroll could feel briefly stuck after recent display/window activity.

Evidence from helper PID `11467`:

- Unified logs recorded display reconfiguration callbacks at `15:13:16.753` and `15:14:20.156–.172`, marking
  `DisplayLink` instances outdated for displays `4` and `9`.
- The first subsequently captured physical scroll at `15:19:09.126` targeted VS Code on display `4`. Its routing
  record at `15:19:09.135` was `MFSCROLL_DISPLAY action=keep ... display=4`, which means the same-display early
  return bypassed `setDisplay:`—the only old route that refreshed an outdated link.
- That captured gesture was healthy (`21.10 ms` input-to-first-output, `5.34 ms` queue time, then `100–120 Hz`
  output), so the reported stall was not captured directly. The stale-link attribution is a code-supported
  inference from the reconfiguration and routing records, not a claim that this healthy gesture stalled.

Root cause: after a display reconfiguration, scrolling on the unchanged display returned through `action=keep`.
The stale `CVDisplayLink` was therefore not replaced before the next start; if CoreVideo had stopped invoking it, the
existing cold-start watchdog could only recover it after `110 ms`.

Fix (`Shared/Animation/DisplayLink.m`): same-display routing no longer bypasses an outdated link. It records a
pending refresh, and `start_UnsafeWithCallback:` recreates and rebinds the link in its ordered main-queue start block,
after any stale-link stop and immediately before `CVDisplayLinkStart`. A live active animation is not interrupted;
its next cold start refreshes safely. The normal report is still handled immediately and the watchdog remains a
fallback rather than the first recovery mechanism.

Verification:

- `git diff --check`, `./dev.sh build`, and `./dev.sh run` passed. The rolling recorder remained active across the
  restart.
- On fresh helper PID `14638`, a physical same-display start at `15:24:16.191` reached first output in `20.91 ms`
  with `1.27 ms` queued. Its opposite report at `15:24:16.293` reached first output in `9.61 ms` with `0.76 ms`
  queued; subsequent slow-to-fast reports sustained `111.8–120.3 Hz` output. A second cold start at `15:24:18.002`
  reached first output in `19.70 ms` with `2.39 ms` queued. No `watchdog-cold-restart`, `recover-stall`,
  `refresh-failed`, event-tap disable, or output gap was recorded.
- A physical display-reconfiguration pass is still required: fixed-pointer scroll after reconfiguration, active
  scroll during reconfiguration, and idle-display scroll should produce `refresh-before-start` only where expected
  and no stall-recovery marker.

Remaining tradeoff: a display reconfiguration during an active, still-callbacking animation defers replacement until
the next cold start so CoreVideo stop/release cannot race its callback. If callbacks actually stop, the next physical
report still uses the existing stale-link recovery and then starts a refreshed link.

### 2026-07-24 — stale slow-cadence memory made a resumed first report look stuck

Symptom: after a brief pause, the first scroll report felt stuck or delayed even though output eventually continued.

Evidence from helper PID `14638`:

- The report at `15:58:32.516` followed the prior physical report by `1,094 ms`. It entered the queue in
  `0.82 ms` and produced its first output in `10.68 ms`; there was no display recovery, event-tap disable, or
  target change.
- Despite that healthy delivery, `MFSCROLL_ADAPTIVE` classified it as remembered cadence with a `639.4 ms` estimate.
  `MFSCROLL_LEGACY` then selected `smoothness=.92`, `baseMs=479.5`, `durationMs=483.0`, and `targetV=41.7` for a
  `20px` first report. The next physical report `78 ms` later immediately restored normal retargeting. The visible
  problem was therefore the deliberately too-low initial output rate, not a queue or display-link stall.
- The previous report was slow and within the `1.5 s` cadence-memory horizon, but the `1,094 ms` gap is well beyond
  the `500 ms` gesture boundary. Treating its remembered cadence at full strength conflicts with the first-report
  responsiveness invariant.

Root cause: the sparse-cadence continuation branch applied full slow smoothing and the full cadence-derived duration
for every gap up to `1.5 s`. Its explicit purpose was to support truly sparse movement, but at the stale end of that
window it turned an opening report into a nearly half-second glide.

Fix (`Helper/Core/Scroll/Scroll.m`): retain the same `1.5 s` memory, but smoothly taper its smoothing and
cadence-duration influence from full strength at the `500 ms` gesture boundary to zero at the memory limit. The
physical report still starts immediately and carries no confirmation gate; a subsequent measured report still
retargets normally. Short-gap sparse motion keeps the existing full slow-cadence treatment.

Verification: `git diff --check`, `./dev.sh build`, and `./dev.sh run` passed; the restarted helper PID `25748`
re-enabled its event tap and the rolling recorder remains active. The target capture's `1,094 ms` gap should log
`memoryBlend≈0.41`, use `action=taper-stale-cadence`, and have a substantially shorter initial duration without
`recover-stall`, `watchdog-cold-restart`, or a queue-time increase. A fresh physical slow-restart pass is pending on
that helper; the `483 ms` trace above is the pre-deployment baseline.

Remaining tradeoff: a deliberately continuous one-unit cadence near `1.5 s` will start more crisply than before
rather than preserving a long overlap. This favors the documented first-report responsiveness guarantee; short
sparse gaps remain fully blended.

### 2026-07-24 — live same-direction settling candidates could discard resumed input

Symptom: scrolling again shortly after a fast burst could feel stuck or delayed even though the display link and
queue were healthy.

Evidence from helper PID `25783`:

- Four fresh physical one-unit, same-direction reports reached the narrow settling guard at `22:32:45.568`,
  `22:33:44.120`, `22:34:19.387`, and `22:36:33.396`. Their gaps were `200–270 ms`, and each logged
  `MFSCROLL_TAIL action=continue-same ... animatorRunning=1 microPx=0`.
- The detailed `22:36:33.396` case followed an active fast downward glide: output was still running at
  `120 Hz` at `22:36:33.327`, the candidate reported a `20px` physical tick, and its live animation speed was
  `296.9 px/s`. The guard immediately returned without an `MFSCROLL_LEGACY` retarget record or added distance;
  only the decaying old glide remained. That is a confirmed input-suppression path, not a queue delay.
- Surrounding fresh starts on the same helper remained healthy: for example `22:36:34.508` reached first output in
  `11.23 ms` with `0.60 ms` queued. The capture contains no stalled-link recovery, display-start failure, or
  event-tap disable.

Root cause: the accepted old same-direction policy (“leave a running glide untouched”) implemented that policy by
returning before `ScrollAnalyzer` and `TouchAnimator` saw the physical report. While it avoided a secondary tail,
it also violated the immediate-retarget invariant and could leave a deliberate resume with no new distance after the
old glide expired.

Fix (`Helper/Core/Scroll/Scroll.m`): a live same-direction settling candidate now disarms the guard but continues
through the ordinary one-shot tail blend and velocity-preserving animator retarget on the same report. The blend
still limits the ambiguous first distance/duration and is logged as
`MFSCROLL_TAIL action=blend source=settling-same`. Stopped same-direction candidates retain the bounded `50 ms`
micro-glide, and opposite candidates still cancel old direction and use their bounded micro-glide unchanged.

Verification:

- `git diff --check`, `./dev.sh build`, and `./dev.sh run` passed. The replacement helper PID `24694` re-enabled
  its event tap at `22:40:36.632`; the rolling recorder remained active.
- The affected path was checked against the matrix constraints: no timer or report-count gate was added; a live
  same-direction report retains current velocity and is capped by the existing one-shot tail blend; stopped tails
  and opposite rebound/reversal handling remain isolated from `ScrollAnalyzer` as before. Fresh-start, slow
  cadence, target-window, and display-recovery code paths are not changed.
- The fresh physical target case was captured on PID `24694`: at `22:41:03.788`, a one-unit same-direction report
  `226 ms` after fast input logged `retarget-same`, then `blend source=settling-same`, and the normal path logged
  `retarget=1` with `19.9px` added distance at `22:41:03.789`. The next active output arrived at `22:41:03.795`
  (`7 ms` later), while output remained `120 Hz` with a `9.20 ms` maximum active gap. There was no recovery,
  display-start failure, or tap disable.
- Adjacent physical cases remained healthy: the fresh start at `22:41:03.277` reached first output in `10.18 ms`
  with `0.88 ms` queued and accelerated into `119.9 Hz` output; a `303 ms` opposite settling candidate at
  `22:40:47.297` retained its unchanged `micro-reversal` path and reached first output in `9.92 ms` with
  `0.70 ms` queued. The remaining manual matrix cases are fast stop with no input, a hardware rebound, and a slow
  reversal after a long pause; they are not altered by this branch and should continue to be sampled in the rolling
  capture.

Remaining tradeoff: a real same-direction rebound during a still-live tail now adds one bounded blended response
instead of being ignored. That is intentionally preferable to discarding an indistinguishable physical resumed
scroll; the guard remains one-shot and the next report resumes ordinary adaptive behavior.

### 2026-07-25 — a near-boundary slow reversal retained full sparse cadence

Symptom: a slow scroll could feel stuck even though it began on time.

Evidence from helper PID `24694`:

- The physical one-unit reversal at `20:29:31.409` followed the prior slow report by `483 ms`. It entered the
  scroll queue in `1.25 ms` and sent its first output in `15.97 ms`, so neither the queue nor a display-link start
  was delayed.
- `MFSCROLL_ADAPTIVE` nevertheless recorded `memoryBlend=1.00 ... reversal=1 action=use-slow-smoothness`.
  `MFSCROLL_LEGACY` selected `targetV=55.2`, `baseMs=362.3`, and `durationMs=373.1` for its `20px` input. That is
  a deliberately very low post-first-frame response and explains the perceived stuck/slow movement.
- The same rolling capture has normal `0.41–1.78 ms` queue time and `5.24–19.50 ms` first-output latency, with no
  tap disable, stalled-link recovery, watchdog restart, display-start failure, or refresh failure. A close `174 ms`
  slow reversal at `20:29:28.896` selected a shorter `190.4 ms` response, showing that short deliberate reversals
  still need cadence continuity.

Root cause: the prior stale-cadence fix tapered only after the `500 ms` gesture boundary. Slow reversals took the
same full-cadence branch at every gap below that boundary, so the `483 ms` direction change treated a new opening
report as if it must overlap another sparse report and spread it over `373 ms`.

Fix (`Helper/Core/Config/ScrollConfig.swift`, `Helper/Core/Scroll/Scroll.m`): retain full slow-cadence influence
for reversals through `200 ms`, then continuously taper it to zero at the existing `500 ms` gesture boundary. The
general `500 ms–1.5 s` stale-memory taper remains unchanged for same-direction sparse input. The new telemetry
records the independent `memoryBlend`, `reversalBlend`, final `blend`, and
`action=taper-reversal-cadence`. No report is deferred, confirmed, or discarded; the normal direction-change path
still cancels old motion and processes the physical report immediately.

Verification:

- `git diff --check` and `./dev.sh build` passed (only existing unrelated deprecation/unused-code warnings).
  `./dev.sh run` rebuilt and restarted the helper; the current PID `14724` re-enabled its event tap at
  `20:32:47.442`, and the rolling recorder remains active.
- Regression-boundary review: the captured `174 ms` reversal remains at full cadence; the captured `483 ms`
  reversal now has `reversalBlend≈0.06` instead of `1.00`; reversals at or beyond `500 ms` receive the bounded
  normal first-report response; same-direction sparse input retains its previous `500 ms–1.5 s` taper. Fast-tail
  settling, target-window reset, output-rate bounds, and display-link recovery are not modified.
- A fresh physical pass on PID `14724` is still required for the relevant matrix: close slow reversal, `400–500 ms`
  slow reversal, extremely slow same-direction continuation, fast stop/rebound, and normal slow-to-fast input.
  The target path should emit `taper-reversal-cadence` and a substantially shorter duration without queue or
  display-recovery markers.

Remaining tradeoff: a deliberately continuous reversal between `200–500 ms` is now crisper than before rather than
fully overlapped. The smooth taper preserves close careful reversals while prioritizing the documented first-report
responsiveness invariant at the ambiguous boundary.

### 2026-07-25 — post-fix slow-start and stuck-scroll regression audit

Symptom checked: scrolling was reported as sometimes slow to start or briefly stuck after the near-boundary reversal
fix above.

Evidence from the current helper PID `14724`:

- The target `467 ms` reversal at `23:07:11.441` recorded
  `memoryBlend=1.00 reversalBlend=0.11 ... action=taper-reversal-cadence`. Its response was reduced to
  `durationMs=180.8` from the pre-fix captured `373.1 ms`, and its first output arrived in `13.01 ms` with
  `0.56 ms` queued. Subsequent active output ran at `119.6–120.3 Hz` with roughly `9.35–9.42 ms` maximum gaps.
- Adjacent reversal boundaries preserved their intended behavior: a `196 ms` reversal retained full cadence
  continuity, a `292 ms` reversal used `reversalBlend=0.69`, and `551 ms`, `585 ms`, `1,227 ms`, and `1,462 ms`
  reversals used zero reversal blend and the bounded normal `167.9 ms` response. Their first outputs remained
  within one or two display frames.
- Across the reviewed starts, `MFSCROLL_LATENCY` recorded `7.61–19.29 ms` input-to-first-output and
  `0.48–3.53 ms` queue time. Large aggregate `MFSCROLL_OUTPUT maxGapMs` values occurred only in windows that
  straddled an idle/quantized tail and a fresh restart; after physical input resumed, active output returned to
  approximately `116–120 Hz`.
- The Browser-to-Kitty switch at `23:09:24.804` emitted
  `window-change ... action=reset-session`. The first Kitty report used
  `cadence=unknown action=use-normal-smoothness` and produced output in `10.45 ms` with `0.82 ms` queued. This
  confirms that the target reset did not leak old cadence or distance into the new app.
- Fast-tail regression cases at `23:09:32.819` and `23:09:34.391` emitted
  `action=retarget-same` followed by `source=settling-same` and a normal `retarget=1`; the physical resumed
  reports were not discarded. Slow-to-fast samples likewise retargeted every new physical report and reached
  display cadence.
- No unexplained tap disable, display-link recovery/watchdog restart, display-start failure, refresh failure, or
  target-window churn was present. Display starts returned `result=0`; the only later target resets were explicit
  mouse-down records.

Conclusion: the captured slow-start/stuck symptom does not reproduce as a queue, display-link, target-reset, or
animator regression. The previously diagnosed near-boundary reversal problem is fixed in this build, so no further
scroll code was changed during this audit. In particular, the ordinary sparse same-direction response was left
unchanged because the capture shows timely first output and immediate acceleration on subsequent reports; shortening
it without contrary evidence would regress continuous sparse scrolling.

Verification: refreshed the rolling snapshot with `./dev.sh logs-record-snapshot`, correlated physical input,
adaptive choice, animator retarget, latency, output cadence, target reset, display-link, and event-tap telemetry,
and ran `git diff --check`.

Remaining coverage: this physical pass covered vertical scrolling in Browser and Kitty on display `4`, including
app switching, close and paused reversals, slow-to-fast input, ordinary tail settling, and fast-tail resumed input.
Horizontal scrolling, other attached displays, zoom/effect paths, Safari rubber-banding, Telegram, Finder,
VS Code/Xcode, and scrolling after a genuinely parked display were not represented in this capture and remain
manual matrix items rather than claimed passes.

### 2026-07-25 — an expired bounded fast-tail response weakened the next real report

Symptom: after a fast gesture, starting again in the same direction could feel slow or briefly stuck.

Evidence from helper PID `14724`:

- The Browser gesture opened normally at `23:20:52.368`: an app-change reset cleared the prior session, unknown
  cadence selected the bounded normal response, and first output arrived in `13.32 ms` with `1.67 ms` queued.
  The gesture accelerated normally and produced active output at `120.3 Hz`.
- At `23:20:52.877`, a one-unit same-direction report arrived `312 ms` after fast input while `161.8 px/s` of the
  old animation remained. It was correctly accepted rather than discarded:
  `action=retarget-same`, `source=settling-same`, and `retarget=1` were all present. The ambiguous response was
  bounded to `9.9px`, `baseMs=142.1`, and `durationMs=191.5`; active output remained `119.9 Hz`.
- The next one-unit physical report arrived `216 ms` later at `23:20:53.093`, after that bounded response had
  finished (`currentV=0.0`, `retarget=0`). It was delivered promptly—`13.27 ms` to first output with `1.85 ms`
  queued—but inherited `cadenceKnown=1`, maximum slow smoothing, `targetV=74.0`, `baseMs=270.3`, and
  `durationMs=292.2`. The `25 ms` and `51 ms` follow-up reports retargeted normally, confirming that the visible
  hesitation was the weak second start rather than a queue, tap, target, or display-link stall.

Root cause: the fast-tail state intentionally makes a second physical report regain normal speed-derived slow
smoothing, proving continuation without a report-count gate. It did so even when the first bounded tail response had
already ended. That conflated a visibly continuous sparse movement with a new same-direction opening after an
ambiguous tail, allowing a stopped animator to restart at only `74 px/s`.

Fix (`Helper/Core/Scroll/Scroll.m`): remember for one physical report that a bounded fast-tail response was just
accepted. The next report consumes that marker immediately. If the bounded response has already stopped and the
next report is still a small, slow, same-direction continuation within the analyzer gesture, apply the existing
`80 ms` opening base-duration cap before the measured slow-smoothing factor. Record the path as
`MFSCROLL_TAIL action=restart-after-expired-tail`.

Preserved behavior:

- The ambiguous first tail report keeps its existing distance and duration bounds; hardware rebound is not enlarged.
- If its animation is still running, sparse continuity is unchanged.
- The report is neither delayed nor discarded, analyzer/cadence history remains intact, and slow smoothing still
  begins from measured input rather than an event-count confirmation gate.
- Direction changes, faster/larger continuations, ordinary extremely slow input, stale-cadence/reversal tapers,
  target resets, display recovery, and non-Regular effect paths do not enter the new condition.

Verification:

- `git diff --check` passed. `./dev.sh build` succeeded, and `./dev.sh run` rebuilt, launched the app, and restarted
  its embedded helper. The replacement helper re-enabled its event tap; the rolling recorder remains active.
- For the captured `23:20:53.093` parameters, the new condition caps the pre-smoothing base response at `80 ms`
  instead of retaining the old roughly `162 ms` pre-smoothing value. It preserves the measured slow-smoothing
  factor, yielding a substantially shorter response while the following faster report can still retarget on that
  same report.
- Fresh adjacent-path telemetry on replacement helper PID `50666` remained healthy. The fixed-pointer fresh start at
  `23:24:32.940` produced output in `16.66 ms` with `0.71 ms` queued; active output returned to `116–120 Hz`.
  A close `178 ms` reversal preserved full slow cadence and responded in `18.86 ms` with `0.65 ms` queued, while a
  `763 ms` reversal used zero reversal blend and the normal `167.9 ms` response. A `199 ms` live same-direction tail
  at `23:24:34.331` still logged `retarget-same`, kept the full `20.2px`, and continued at display cadence. No tap
  disable, display recovery, start failure, or refresh failure accompanied these cases.
- Regression-path review covered fresh starts, live same-direction tail continuation, first hardware-rebound
  bounding, stopped-tail continuation, fast follow-up input, direction reversal, ordinary sparse cadence,
  app/window resets, and display-link recovery invariants. Only the stopped, small, same-direction second report
  after a bounded fast tail changes.

Remaining verification: a fresh physical reproduction on the replacement helper must capture
`action=restart-after-expired-tail` and confirm the shorter response by feel, with normal first-output latency and
active output cadence. Stop-with-no-input and an isolated hardware rebound should remain silent after their existing
one bounded response.

### 2026-07-25 — tick-interval averaging delayed slow-to-fast acceleration

Symptom: scrolling could still feel slow or briefly stuck at the start even after the expired fast-tail response was
shortened.

Evidence from helper PID `50666`:

- The new expired-tail path was captured at `23:26:35.424` and behaved as designed:
  `action=restart-after-expired-tail` capped its base response at `132.9 ms` after the measured slow-smoothing
  factor, down from the old `270.3 ms` behavior. The first output arrived in `8.44 ms` with `0.50 ms` queued.
- Input then accelerated only `34 ms` later at `23:26:35.458`. The velocity model immediately rose from
  `3.8` to `26.9 units/s`, but `ScrollAnalyzer`'s three-report tick average still reported `183.34 ms`.
  Animation duration therefore remained at `baseMs=263.3`, `durationMs=320.3`, and only `targetV=149.4`.
  A larger report `36 ms` later still used a stale `112 ms` cadence and only reached `targetV=577.2`.
- A separate ordinary slow-to-fast case reproduced the same mechanism more clearly. At `23:27:22.787`, the
  legitimate second one-unit report after `482 ms` selected slow smoothing, `targetV=66.6`, and a `288.0 ms`
  response. The next report arrived after only `38 ms`, but the duration path used a `262.47 ms` averaged cadence
  and selected just `targetV=154.0`. The following `33 ms` report still used `185.31 ms`; only the next report
  finally reached a current `33.33 ms` cadence and `targetV=1713.5`.
- Delivery was healthy in both cases: the relevant first outputs were `8.44–13.94 ms`, queue time was
  `0.50–2.73 ms`, active output returned to approximately `120 Hz`, and there was no tap disable, display recovery,
  start failure, refresh failure, or target reset causing the hesitation.

Root cause: the time-based velocity filter correctly recognized acceleration on the current physical report, but
the directly-driven animation-duration curve still consumed the symmetric three-report average of tick intervals.
After sparse input, that average stayed slow for two faster reports and contradicted the invariant that acceleration
must replan the active response on the same report.

Fix (`Helper/Core/Config/ScrollConfig.swift`, `Helper/Core/Scroll/Scroll.m`): for the Regular stable engine, use the
current raw interval for animation-duration cadence only when both of these are true on the same report:

- modeled output speed increased; and
- the raw interval is at most `75%` of the smoothed interval.

The path logs `MFSCROLL_ADAPTIVE ... action=use-raw-acceleration-cadence`. `MFSCROLL_LEGACY` now records both the
analyzer's `cadenceMs` and the duration curve's `baseCadenceMs`.

Preserved behavior: constant sparse input still uses the three-report average and measured slow smoothing;
deceleration continues to use the smoother; distance mapping, output-rate limits, retained carry, tail bounding,
direction cancellation, stale-cadence/reversal tapers, target resets, and display recovery are unchanged. No input
is delayed, confirmed, or discarded.

Verification:

- `git diff --check` and `./dev.sh build` passed. `./dev.sh run` rebuilt, launched the app, and restarted its helper.
- On replacement helper PID `52446`, a fresh first report used unknown-cadence normal smoothing and the bounded
  `80 ms` base response, reaching output in `20.53 ms` with `0.80 ms` queued. Subsequent active output ran at
  `119.6–120.5 Hz`.
- A live one-unit same-direction settling report at `23:29:36.947` retained the existing
  `retarget-same`/`source=settling-same` path and continued at `120.1 Hz`; its unchanged steady/decelerating cadence
  recorded equal `cadenceMs` and `baseCadenceMs`.

Remaining verification: the replacement helper has not yet captured a materially faster follow-up after sparse
input, so a fresh `action=use-raw-acceleration-cadence` record and feel check remain required. Constant extremely
slow input, a slow-to-fast ramp, fast-to-slow settling, close and paused reversals, and an app/window switch should
continue to be sampled in the rolling capture.

Remaining tradeoff: a genuinely anomalous short packet can shorten one response if modeled speed rises with it.
The `75%` interval threshold excludes ordinary timing jitter, while unchanged distance and rate caps prevent that
one report from creating an output burst.

### 2026-07-25 — post-fix verification of slow-to-fast duration cadence

The replacement helper PID `52446` captured the previously missing acceleration case twice, including the combined
expired-tail restart that had produced the reported hesitation:

- At `23:30:31.535`, a one-unit report after `462 ms` correctly took
  `action=restart-after-expired-tail`, retained the bounded `132.9 ms` opening base, and produced its first output in
  `12.02 ms`. At `23:30:31.556`, the next report arrived after `26 ms`; the analyzer's intentional three-report
  average was still `242.3 ms`, while `action=use-raw-acceleration-cadence` selected `baseCadenceMs=26.01`. This
  reduced the response base to `206.9 ms` and raised the target to `202.2 px/s` on that same report.
- At `23:30:31.580`, the next accelerating report used `baseCadenceMs=20.00` instead of the still-stale
  `cadenceMs=169.33`, reducing the response base to `128.8 ms` and raising the target to `995.9 px/s`. Once the
  rolling average caught up, `cadenceMs` and `baseCadenceMs` again matched. Active output then ran at
  `119.7–119.9 Hz` with maximum callback gaps below `9.4 ms`.
- A second independent sequence at `23:31:17.693–23:31:17.758` reproduced the same combined path:
  `restart-after-expired-tail`, then raw `39 ms` versus smoothed `251.3 ms`, followed by raw `28 ms` versus smoothed
  `174.7 ms`. Its restart reached first output in `8.69 ms` with `2.05 ms` queued.

This verifies the root-cause fix rather than merely the symptom: the current measured cadence now reaches the
animation-duration curve on the first materially faster report, while the analyzer's smoothing, velocity model,
distance, and carry remain untouched.

Adjacent regression evidence from the same helper:

- `24` fresh animation starts reached first output in `5.88–17.07 ms`; queue time was `0.46–5.52 ms`.
- `156` Regular-engine reports exercised both vertical directions and `132` live retargets. None were rate-limited
  and none dropped retained distance.
- Slow/paused reversals at `23:30:53.750`, `23:30:55.630`, and `23:31:06.857` retained the existing reversal taper;
  their first outputs arrived in `12.14`, `14.50`, and `12.59 ms`, respectively.
- Same-direction settling reports retained `action=retarget-same`; post-fast stopping produced no later secondary
  output burst in the captured intervals.
- Window switches Browser -> kitty at `23:30:43.942` and kitty -> Browser at `23:30:51.038` logged
  `action=reset-session`, and each target accepted the next first report.
- No `MFSCROLL_TAP` disable, display stall recovery, watchdog/animator cold restart, display-link start failure, or
  refresh failure occurred.

Verification commands: `git diff --check`, `./dev.sh build`, `./dev.sh run`, `./dev.sh logs-record-snapshot`, plus
targeted `MFSCROLL_INPUT`, `ADAPTIVE`, `TAIL`, `LEGACY`, `LATENCY`, `OUTPUT`, `TARGET`, `TAP`, and `DISPLAY`
correlation in the rolling capture. Build and deployment passed.

Remaining tradeoff: the current capture covers the affected vertical path, slow/fast transitions, reversals,
stopping, and a same-display app/window switch. Horizontal input, Safari/Chromium boundary behavior, and switching
between physical displays were not manually exercised in this verification pass. The cadence bypass is confined to
the Regular stable engine's duration input and does not alter those routing or effect paths.

### 2026-07-25 — deep scroll audit: stale restart duration and four latent session/liveness regressions

Symptom: a new slow report could still feel stuck after a pause, and repeated scroll fixes had left adjacent
direction, modifier/config, settling-tail, and display-recovery paths vulnerable to regressions.

Current telemetry before attribution:

- The rolling capture on helper PID `52446` contained `157` handled physical reports and `157`
  `MFSCROLL_LEGACY` records. Its `22` cold starts reached first output in `5.88–17.99 ms` with
  `0.55–5.52 ms` queued. There was no tap disable, display recovery/start failure, rate limiting, dropped carry, or
  target change around the reported pauses. The symptom was therefore not a queue, event-tap, or display-link stall.
- The slow openings were response-shape records: `23:31:08.053` followed a `788 ms` gap with
  `memoryBlend=0.71`, `baseMs=429.7`, and `targetV=46.5`; `23:31:23.273` followed `874 ms` with
  `baseMs=452.6`; and `23:31:25.196` followed `978 ms` with `baseMs=434.3`. The old formula multiplied a
  decreasing stale-memory blend by a cadence target that continued growing with the pause. Its maximum landed near
  `0.8–1.0 s`, making those later restarts slower than a report near the `500 ms` gesture boundary.
- A `109 ms` reversal immediately after the `874 ms` case used the stale `491.5 ms` scalar estimate. Direction
  cancellation still worked on the Regular curve, but the estimate showed that a close opposite decision could
  inherit the preceding same-direction pause.

Confirmed root causes and changes:

1. In `Helper/Core/Scroll/Scroll.m`, a stale report updated the cadence EMA before choosing its own duration.
   The restart now uses only cadence known before that physical report, capped by the `500 ms` gesture boundary; the
   current gap may update memory only for a future report. The existing memory/reversal tapers still decay to zero,
   and a reversal clamps the retained estimate to its actual cross-direction gap. New
   `priorEstimateMs`, `durationRefMs`, and `cadenceDurationRefMs` fields expose the distinction.
2. Direction cancellation lived inside the custom acceleration branch. System/Apple acceleration could therefore
   append an opposite report to the old animation session. Cancellation now runs after both acceleration branches,
   logs `MFSCROLL_DIRECTION action=cancel-old-session appleAcceleration=...`, terminates the old phase, and still
   delivers the current physical report.
3. Modifier state was sampled only after preliminary analysis and only at a gesture boundary; cached config reloads
   did not end an animation already holding the old snapshot. Modifiers are now sampled on every handled physical
   report before direction analysis. A change resets the session immediately, and
   `ScrollConfig.reload()` / `devToggles_deleteCache()` enqueue the same reset so the next report opens with the new
   curve, direction, and effect policy.
4. The stopped `micro-same` settling path returned before the local fast-tail marker was updated, so its next report
   could receive a second bound. Fast-tail classification is now resettable scroll-session state, and `micro-same`
   marks its one allowed response handled while arming the existing expired-response continuation cap.
5. `Shared/Animation/DisplayLink.m` wrote the outdated flag from an arbitrary display-callback thread and cleared it
   on main, so a second reconfiguration could be lost while CoreVideo was being recreated. All invalidation state is
   now serialized on the display-link queue. A refresh-in-flight guard prevents queue work from touching the replaced
   pointer, coalesces a concurrent start, and never clears a newer invalidation. Rebind/start failures preserve the
   outdated flag for a recreating retry. `Helper/Core/Touch/TouchAnimator.swift` now aborts after three callback-less
   cold retries, discards only the never-delivered animation, and returns requested state to stopped instead of
   leaving future reports attached to a zombie animator.

Preserved behavior:

- No timer, confirmation window, physical-report gate, or delayed replay was added. The first report still emits on
  the first available display callback.
- Constant sparse input may continue learning its cadence for later reports; a single resumed report can no longer
  use its own silence to make itself slower. Acceleration still switches immediately to raw cadence, while
  deceleration keeps the smoother.
- Fast-tail distance/duration bounds, the `320 ms` mechanical-settling window, live velocity-preserving retargets,
  expired-tail opening cap, rate/carry limits, target-window reset, and non-Regular effect behavior are unchanged.
- Display reconfiguration during a healthy active animation remains deferred to a cold start; the change makes that
  handoff race-free rather than interrupting visible motion.

Verification:

- `git diff --check` passed, and repeated `./dev.sh build` runs completed with `BUILD SUCCEEDED`. The final build was
  deployed through `./dev.sh run`; helper PID `60239` logged `MFSCROLL_CONFIG action=reload-reset` on startup.
- Physical pass PID `58902` covered `139` handled reports. `137` entered the Regular modeled path and the other two
  were intentional `micro-reversal` responses; all produced visible output. Seventeen cold/micro starts measured
  `10.44–21.71 ms` first-output latency and `0.53–4.26 ms` queue time. Same-direction live tails logged one
  `retarget-same` plus one `blend`, while direction changes logged cancellation and kept the current tick.
- Physical pass PID `59463` covered `95/95` handled/modelled reports across slow starts, `838 ms` same-direction
  restart, slow-to-fast and fast-to-slow motion, active and paused reversals, fast settling, clicks, and Kitty /
  Browser / Finder target changes. Excluding sparse/idle windows, `30` active output windows ran at
  `104.3–120.3 Hz` with a maximum `17.53 ms` gap. There was no unexplained tap disable, recovery/watchdog record,
  start/refresh failure, rate-limited report, or dropped carry.
- The intermediate boundary cap changed the captured `838 ms` start to `durationRefMs=493.3`,
  `baseMs=283.8`, and `durationMs=303.6`, already well below the pre-fix `429–453 ms` class. That pass then showed
  why the final refinement was needed: the current gap had raised its own estimate. Replaying the final formula with
  a fixed prior cadence from `500–1500 ms` is monotonically non-increasing (`225.0 ms` to `132.9 ms` for a
  representative `300 ms` prior estimate); the current report never increases its duration reference.
- Static branch review confirms the shared cancellation runs for both `useAppleAcceleration` values, modifier/config
  resets precede preliminary analysis, every reset clears the tail markers, and all display invalidation/refresh
  flag writes are queue-confined. The refresh-in-flight path has an explicit deferred-start resume and the terminal
  watchdog leaves `isRunning_Unsafe == false`.

Remaining manual coverage: the physical passes used the Regular custom-acceleration vertical path on display `4`.
System acceleration, live modifier/effect changes, horizontal input, Safari/Chromium rubber-banding, Telegram,
VS Code/Xcode, attached-display reconfiguration, and a genuinely parked display were branch/build checked but not
physically forced in the final build. Those cases must remain in the matrix and should not be claimed as live passes.

Remaining tradeoff: a cadence learned from several genuinely sparse reports can still lengthen a later report, which
is required for continuous extremely slow motion. The fix removes only self-lengthening by the current pause. After
three completely callback-less display restarts, the undelivered request is dropped so future input can recover;
silently retaining it would reintroduce both the zombie-session bug and a delayed snap.

### 2026-07-26 — deep engine hardening: false sparse restart, lifecycle races, and hot-path overhead

Symptom: after many earlier fixes, a fresh report following a fast spin could still move slightly and feel stuck
before continuing. A code-wide review also found modifier/effect teardown, display-link lifecycle, configuration
snapshot, remap cache, output-bound, and synthetic-event paths that could recreate a delay or stale session.

Telemetry before attribution:

- Helper PID `60239` at `22:29:28.007` received a first report after `681 ms`. Queue time was only about `0.58 ms`
  and first output arrived in about `12.02 ms`, with no tap/display failure, but the response used the current
  `681 ms` gap as remembered cadence (`priorEstimateMs=0`, `durationRefMs=500`) and stretched a roughly `20 px`
  opening to `baseMs=329.4`, `durationMs=343.5`.
- Nineteen captured starts otherwise reached output in `9.97–22.04 ms` (median about `13.97 ms`) with
  `0.52–6.32 ms` queued (median about `0.67 ms`). The perceived pause was response shape, not evidence of a queue,
  event-tap, or display-link delay.
- The recorder saw `155` physical inputs but `1,521` self-generated continuous events. More than 90% of the old
  input/logging path was therefore output feeding back through field decoding, target lookup, and debug telemetry.

Confirmed root causes and changes:

1. Sparse-cadence continuation checked only the previous modeled speed. A decelerated multi-unit report at the end
   of a spin could therefore seed the next opening report. `ScrollCadencePolicy.h` now requires the immediately
   preceding accepted report itself to be low-unit, low-speed motion, and excludes fast/settling-tail responses.
   Every session reset and early bounded-tail return clears that eligibility. Genuine sparse motion may still use
   cadence beginning with report two; no timer or report-count gate was added.
2. Modifier resolution performed usage side effects while polling every wheel report, and modifier release could
   disable the scroll tap before another report ended zoom or Command-Tab. Resolution is now pure, usage feedback is
   one-shot per effective activation, and immutable modifier callbacks end/reconfigure the scroll session
   immediately. Every reset releases a synthetic Command key. Remap reloads while a modifier is held publish the
   new effective scroll mode, and trackball-mode changes now explicitly re-evaluate the tap instead of calling the
   unrelated `userIsActive` callback.
3. The CoreVideo callback synchronously waited on a queue which can call `CVDisplayLinkStop`, forming a lock
   inversion. Delivery is now asynchronous on the existing user-interactive serial queue, with at most one
   executing and one waiting callback; stale/backlogged frames are rejected. Lifecycle generations prevent a stop
   from being undone by an older deferred start. Borrowed `CGEventRef` values no longer cross an async boundary:
   display ID is resolved synchronously, validated, and passed by value. Reconfiguration and failed-start behavior
   retain the existing cold-start/watchdog recovery contract.
4. The custom speed path mixed true units/second with an old events/second acceleration curve, and overload bounds
   were not universal across custom modes. The retained model now has explicit pixels/unit and pixels/second
   semantics, explicit Low/Medium/High, Precise, Quick, and display scaling, and a time-based final rate limit after
   all multipliers. Initial distance, carry, and fast-tail friction remain separate bounds for every custom mode.
   The rejected event-rate curve is compile-time unavailable.
5. `ScrollConfig` lazy values read a mutable global raw dictionary; cache reload and derived-cache publication were
   unsynchronized; animator parameter blocks still read the global current config. Each config now owns a deep,
   immutable raw snapshot, reload/cache state is generation-locked, and each queued animator block captures its
   exact config. During verification, the first implementation exposed the old generic shallow-copy trap:
   `Mac Mouse Fix Helper-2026-07-26-231716.ips` stopped in `ScrollConfig.init()` through
   `SharedUtilitySwift.shallowCopy`. Derived configs now construct directly from their immutable raw snapshot;
   the final live pass had no crash and was intentionally stopped only for the next deployment.
6. `Modifiers` and `Remap` shared mutable dictionaries/cache were read and written across queues. Modifier state is
   immutable copy-on-write; remap calculation occurs outside a short lock and publishes only if its generation
   still matches. Add-mode state and its matching remap table now swap atomically, with notifications outside the
   lock.
7. MMF wheel output carries a 64-bit source marker and returns from the HID tap before decoding or target lookup.
   `MFSCROLL_*` records needed by the rolling capture use info level, so recording no longer globally enables the
   unrelated per-frame debug stream. `cont=1` now represents unmarked external continuous input, not normal MMF
   output recursion.

Preserved behavior:

- A physical report is never held for a timer or confirmation count. First reports retain the bounded normal start,
  report two can use measured slow cadence, and faster input invalidates remembered cadence on that same report.
- Direction changes cancel the old session and deliver the requesting report for both custom and System/Apple
  acceleration. Live retargets retain velocity; no second reservoir or delayed distance is introduced.
- The one-shot `320 ms` settling protection, expired-tail opening cap, terminal gesture phases, target/window reset,
  display watchdog, and sparse-reversal taper remain active. System speed remains the untouched Apple path unless a
  Precise/Quick modification explicitly requests custom output.

Verification:

- `./dev.sh scroll-tests` passes deterministic cadence-seed, display-generation/callback-admission, speed-order, and
  cadence-independent rate-limit checks under `clang -Wall -Wextra -Werror`.
- Repeated `./dev.sh build`, the final `./dev.sh run`, `bash -n dev.sh`, and `git diff --check` passed. Xcode static
  analysis completed successfully; scroll lifecycle/cache files had no ownership or race finding. Existing analyzer
  findings outside this change remain repository debt. The exact final analyzed build started as helper PID `99302`
  with a clean config/tap initialization.
- Live helper PID `96862` handled `128` physical reports: `126` modeled responses plus the intended two bounded
  micro-reversals. All were accounted for. Eighteen cold/micro starts reached first output in
  `6.87–16.86 ms`, with `0.53–4.99 ms` queued. Thirty-four active output windows ran at `108.4–120.4 Hz` with
  `8.81–17.53 ms` maximum gaps. There was no display recovery/start/refresh failure, callback-backlog record,
  rate-limited report, dropped carry, unexplained tap disable, or marked synthetic input in the physical trace.
- The old false-seed shape was exercised directly: a seven-unit report at `23:19:57.112` was followed `612 ms`
  later by a one-unit opening at `23:19:57.724`. It logged `cadence=unknown previousSeed=0`, used
  `baseMs=80.0`, and produced output in `13.18 ms` with `1.40 ms` queued. A six-unit predecessor at
  `23:19:42.869` likewise could not seed the next opening. Conversely, a genuine one-unit predecessor at
  `23:19:44.004` remained eligible at `23:19:44.694`; the existing reversal taper reduced its blend to zero rather
  than creating a dead zone.

Remaining manual matrix: this physical pass covered the Regular custom vertical path in Kitty on display `4`,
including both directions, slow/fast transitions, paused/active reversals, stopping, and settling tails. System
acceleration, live modifier effects (horizontal, zoom, Command-Tab, Dock gestures), trackball-mode tap transitions,
Safari/Chromium boundaries, Telegram, Finder, VS Code/Xcode, each attached display, display reconfiguration, and a
genuinely parked display remain build/branch checked rather than physically forced.

Remaining tradeoffs: callback coalescing intentionally discards redundant display timestamps only when the delivery
queue is already occupied; the next available frame still advances the current animation. Explicit speed
multipliers approximate the old setting ordering without restoring its invalid event-rate domain, and extreme Quick
output may meet the universal safety cap. Genuine repeatedly sparse motion can still lengthen later reports by
design, but a multi-unit/tail report cannot bootstrap that state.

### 2026-07-30 — long-idle hardware ramp selected maximum slow smoothing

Symptom: scrolling had a definite slow start only after roughly 20 seconds or more without wheel input. Restarting
after a 4–5 second pause felt normal.

Current telemetry before attribution:

- Helper PID `11537` ruled out queue, display-link, and tap delay. Starts after `24.376–108.520 s` idle produced
  their first nonzero output in `7.22–14.18 ms`, with `0.48–2.95 ms` queued. The first report consistently used
  `cadence=unknown`, normal `smoothness=0.42`, the bounded `80 ms` base, and a `198 ms` hybrid response. There was
  no watchdog/recovery, display start/refresh failure, or unexplained tap disable.
- Some long-idle starts then contained a short low-unit ramp before normal acceleration. At
  `00:02:16.382–.734`, after `239.512 s` idle, three one-unit reports arrived `182 ms` and `170 ms` apart before
  the next `32 ms` report. At `00:03:37.575–00:03:38.011`, after `66.371 s`, the early gaps were `121 ms` and
  `315 ms`. At `00:06:23.263–.821`, after `108.520 s`, one-unit reports continued through elapsed times of
  `64`, `134`, `294`, and `558 ms`.
- Those measured reports immediately received the normal maximum Slow Smoothness path. Examples include
  `baseMs=269.9` and `269.8` at `00:02:16.564/.734`, `265.9` and `270.3` at
  `00:03:37.697/00:03:38.011`, and `245.5–270.2 ms` at `00:06:23.327–.821`. Later materially faster reports
  correctly selected `action=use-raw-acceleration-cadence`, but the opening already felt weak.
- Captures after `4.358–4.876 s` pauses retained the ordinary path and did not establish the reported threshold.
  The low-unit report shape is captured; attributing that shape to a particular TB800 receiver/firmware power state
  remains an inference because CGEvent telemetry begins only when hardware reports reach the tap.

Confirmed root cause: after the timely bounded first response, the Regular engine treated every measured low-unit
report as deliberate slow cadence at full strength. That is correct for established extremely slow motion, but it
made the captured sub-second long-idle opening ramp use `246–270 ms` base durations before acceleration could
retarget it.

Fix (`Helper/Core/Config/ScrollConfig.swift`, `Helper/Core/Scroll/ScrollCadencePolicy.h`,
`Helper/Core/Scroll/Scroll.m`):

- After a measured physical-input gap of at least `20 s`, remember the opening time. Before the first wheel report,
  helper observation uptime supplies the measured lower bound; an unknown `DBL_MAX` sentinel does not arm the policy.
- The first report keeps its existing bounded normal response. On later small/slow reports within `750 ms`, blend
  the same opening-duration cap into the measured response, fading continuously from full influence to zero.
- Preserve the measured Slow Smoothness ratio; only bound the early directly-driven duration. A report with more
  than two units or modeled speed outside the slow range exits the policy on that same report.
- Add `MFSCROLL_ADAPTIVE action=cap-idle-wake-ramp` with idle gap, elapsed time, blend, uncapped base, and final
  base. No report is delayed, counted, discarded, or replayed.

Preserved behavior:

- Starts after less than `20 s`, the first-report normal-smoothness invariant, ordinary sparse-cadence memory,
  reversal taper, raw-cadence acceleration, velocity-preserving retargets, distance/rate/carry limits, fast-tail
  protection, target resets, and display recovery are unchanged.
- A deliberately extremely slow stream after long idle transitions continuously back to its full measured cadence
  over `750 ms`; there is no event-three switch or timer-driven state change.

Verification:

- `./dev.sh scroll-tests` passes new deterministic boundaries for a `108.520 s` idle start, continuous blend decay
  at `182 ms` and `558 ms`, no policy after a `4.876 s` pause or at window expiry, and immediate bypass for
  substantial/fast input. Existing cadence-seed, display lifecycle, and output-limit suites also pass under
  `clang -Wall -Wextra -Werror`.
- Captured-trace replay predicts the affected `00:02:16` bases falling from `269.9/269.8 ms` to approximately
  `156.6/190.5 ms`; the `00:03:37` cases from `265.9/270.3 ms` to approximately `143.0/207.5 ms`; and the
  `00:06:23` sequence from `245.5–270.2 ms` to approximately `128.4–231.8 ms` as the blend fades.
- `git diff --check`, repeated `./dev.sh build`, and final `./dev.sh run` passed. The final Debug build was deployed.
  An intermediate helper PID `85082` exercised the blend mechanics at `00:15:28.673/.712` and exited on the faster
  report at `.750`; that pass also exposed that the first-process unknown-gap sentinel could arm the policy. The
  sentinel was excluded and first-use gaps were tied to measured helper uptime before the final rebuild/deployment,
  so that intermediate run is not claimed as a real `>20 s` test.
- Final helper PID `86357` preserved the adjacent short-idle case: its first physical input arrived about `5 s`
  after startup at `00:18:22.279`, did not emit `cap-idle-wake-ramp`, used the unchanged `80/198 ms` opening, and
  reached output in `14.67 ms` with `0.52 ms` queued. The expected startup tap re-enable was the only tap marker.

Remaining verification/tradeoff: a physical `>20 s` idle start on the final helper, plus a deliberately extremely
slow start after the same idle, is still required for the feel check and final `cap-idle-wake-ramp` telemetry.
During the first `750 ms` after long idle, genuine careful one-unit input is intentionally crisper than its settled
cadence. This bounded ambiguity is preferable to reproducing the confirmed slow opening, and full sparse smoothing
returns continuously without waiting for another report.

### 2026-07-30 — wake protection faded during hardware silence

Symptom: the long-idle slow start remained perceptible after the first idle-wake mitigation.

Current telemetry before attribution:

- Final helper PID `86357` confirmed the same response-shaping failure in multiple physical long-idle starts. At
  `00:32:09.673`, after `262.341 s` idle, the first report reached output in `10.69 ms` with `0.83 ms` queued.
  The next one-unit report arrived `328 ms` later, when the cap had already faded to `wakeBlend=0.56`; it retained
  `baseMs=193.0` from an uncapped `270.3 ms` response.
- At `00:23:41.490`, after `207.105 s` idle, the first report reached output in `13.81 ms` with `0.68 ms` queued.
  Its next one-unit report arrived `449 ms` later, after the cap had faded to `wakeBlend=0.40`, leaving
  `baseMs=215.2` instead of the `132.9 ms` opening cap. The following low-unit report retained `188.3 ms`.
- A healthier `46.193 s` idle start at `00:27:39.803` supplied follow-up reports after only `37 ms` and `89 ms`;
  the still-strong cap reduced their bases to `130.1 ms` and `127.2 ms`. This timing contrast isolates why the
  earlier fix helped fast wake ramps but not the reported late-second-report shape.
- The capture contained no display recovery, display-start/refresh failure, or unexplained tap disable. The long
  `MFSCROLL_OUTPUT.maxGapMs` records crossed silence between separate animations and are not evidence of a callback
  stall.

Confirmed root cause: the first mitigation linearly faded its opening cap from the time of report one. The captured
TB800 can remain silent for `328–449 ms` before report two, so hardware silence consumed `44–60%` of the protection
before the engine had observed any wake progression. This left the same maximum Slow Smoothness response partly
restored on the report that made the opening feel weak.

Fix (`Helper/Core/Config/ScrollConfig.swift`, `Helper/Core/Scroll/ScrollCadencePolicy.h`,
`Helper/Core/Scroll/Scroll.m`):

- Keep the opening-duration cap at full influence for the measured `750 ms` hardware-ramp interval after a
  qualifying `>=20 s` idle opening.
- Fade the cap continuously from full to zero over the following `750 ms`, expiring at `1.5 s`.
- Preserve the measured smoothness ratio. A report above two units or outside the slow-speed range still bypasses
  and ends wake shaping immediately on that report.
- The policy remains a current-report duration bound. It adds no timer, confirmation count, delayed report, replay,
  or distance reservoir.

Preserved behavior:

- The first report remains the existing normal-smoothness `80 ms` bounded start and emits on the first display
  callback. Starts after less than `20 s` do not arm wake shaping.
- Ordinary slow-cadence memory, reversal taper, raw-cadence acceleration, live velocity-preserving retargets,
  settling/fast-tail protection, target resets, display recovery, and output bounds are unchanged.
- A genuinely careful long-idle stream is fully bounded only during the observed wake interval, then transitions
  continuously to its measured sparse cadence without an event-count switch.

Verification:

- `./dev.sh scroll-tests` passes under `clang -Wall -Wextra -Werror`. Deterministic cases cover the exact
  `328 ms`/`449 ms` late-second-report captures, full influence through `750 ms`, a `0.50` blend halfway through
  the fade, zero influence at `1.5 s`, no policy after a `4.876 s` pause, first-report exclusion, and immediate
  substantial/fast-input bypass. Existing display-lifecycle and output-policy suites also pass.
- Captured-trace replay reduces the `00:32:10.003/.059/.107` bases from `193.0/184.4/172.4 ms` to their full
  `132.8/129.2/116.6 ms` opening caps. It reduces the `00:23:41.939/.979` bases from `215.2/188.3 ms` to
  `132.9/126.6 ms`.
- `git diff --check` and `./dev.sh build` passed. `./dev.sh run` rebuilt and deployed the Debug app; final helper
  PID `94387` logged `MFSCROLL_CONFIG action=reload-reset` and re-enabled its event tap.

Remaining verification/tradeoff: the final deployed helper still needs a physical `>20 s` idle pass covering both
a normal acceleration and deliberately extremely slow movement. Genuine careful one-unit input during the first
`750 ms` after long idle is now fully capped rather than partially tapered; this is the explicit ambiguity chosen
from the captured hardware ramp. Full sparse smoothing returns continuously over the next `750 ms`.

### 2026-08-02 — stopped wake-ramp reports restarted weaker than report one

Symptom: slow starts remained frequent after the long-idle wake protection was deployed. The opening report moved
on time, but a series of sparse one-unit wake reports still felt like repeated weak starts before normal acceleration.

Current telemetry before attribution:

- Across `23` retained starts on helper PID `866`, first nonzero output arrived in `6.02–14.23 ms` (average
  `10.67 ms`) with `0.50–4.15 ms` queued (average `1.31 ms`). Display starts returned `result=0`; there was no
  tap disable, stalled-link/watchdog recovery, callback backlog, or display start/refresh failure. This was not a
  queue, display-link, or event-tap delay.
- The clearest long-idle sequence began in Kitty at `00:10:42.851` after `179.367 s` without physical wheel input.
  Report one used the intended `baseMs=80.0`, `targetV=400.0`, `durationMs=198.0` opening and reached output in
  `5.61 ms` with `0.57 ms` queued.
- Report two arrived `195 ms` later at `00:10:43.046`, after that response had stopped. Wake protection fired, but
  its supposed opening cap was `132.7 ms` because maximum Slow Smoothness had inflated it. The stopped animator
  cold-restarted at only `targetV=241.2` and `durationMs=218.4`. Report three arrived at `00:10:43.456` after
  another `410 ms` of hardware silence and repeated the shape: `baseMs=132.9`, `targetV=218.3`, and
  `durationMs=212.4`. The next `35 ms` accelerating report immediately selected raw cadence and retargeted normally.

Confirmed root cause and fix (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`): the wake
policy capped base duration to the `80 ms` opening value only before applying the measured Slow Smoothness duration
ratio. It then called that inflated `125–133 ms` value the opening cap even when hardware silence had allowed the
previous animation to end. A wake-ramp report with no running animator is another visible opening and now selects
the original uninflated `80 ms` cap. A live animator still selects the adaptive cap, preserving smooth continuity
while it retargets. Telemetry now records `animatorRunning`, the selected `openingCapMs`, and `adaptiveCapMs`.

Preserved behavior:

- No report is delayed, confirmed, discarded, or replayed. The existing `>=20 s` idle threshold, `750 ms` full-cap
  interval, following `750 ms` continuous fade, and immediate larger/faster-input exit are unchanged.
- Report one still uses unknown-cadence normal smoothness. Measured Slow Smoothness still begins on report two; only
  a stopped response inside the already-qualified hardware-wake interval receives the uninflated base cap.
- Live velocity-preserving retargets, ordinary extremely slow input outside wake shaping, sparse cadence/reversal
  tapers, fast-tail settling protection, target resets, output/carry limits, and display recovery are unchanged.

Verification:

- `./dev.sh scroll-tests` passes the new stopped-versus-live wake-cap policy case plus existing cadence seed,
  display lifecycle, and output-bound suites under `clang -Wall -Wextra -Werror`.
- Captured-trace replay changes the stopped `00:10:43.046` response from `132.7 ms` to the same `80 ms` base cap as
  report one, raising its directly-driven target from `241.2` to `400 px/s`. The stopped `29 px` report at
  `00:10:43.456` likewise uses `80 ms` and a `362.5 px/s` target. The live `00:10:43.491` retarget keeps its
  adaptive cap and existing velocity continuity.
- `git diff --check`, `./dev.sh build`, and `./dev.sh run` passed. The deployed Debug helper PID `22437` logged
  `MFSCROLL_CONFIG action=reload-reset` and the expected startup `MFSCROLL_TAP action=re-enable`; the prior helper
  exited during deployment rather than from a scroll failure.
- Final helper PID `23775` later captured a real `59.970 s` idle opening at `00:19:29.110`. Report one reached
  output in `13.38 ms` with `4.89 ms` queued; its `50 ms` live follow-up logged
  `animatorRunning=1 openingCapMs=128.6 adaptiveCapMs=128.6` and raised target velocity from the live `287.7` to
  `429.9 px/s`. This verifies the unchanged live-retarget side of the policy on a qualifying physical idle start.

Remaining verification/tradeoff: the deployed helper still needs a physical `>20 s` idle reproduction that captures
`animatorRunning=0 openingCapMs=80.0` on a late second wake report, plus a deliberate extremely slow long-idle start
to judge the sharper stopped-response tradeoff. During the qualified wake interval, a genuinely careful report that
arrives after the previous response ends now restarts as crisply as report one. Live careful motion and the later
fade retain adaptive smoothing.

### 2026-08-02 — amplified low-unit follow-ups decelerated ordinary openings

Symptom: fresh post-deployment telemetry showed the slow-start notch outside the `>=20 s` idle-wake path as well.
An ordinary opening moved immediately, but the first physically accelerating follow-up could request a lower velocity
before a later report restored acceleration.

Evidence from intermediate helper PID `22437`:

- At `00:14:41.216`, a one-line/one-point opening reached output in `9.00 ms` with `0.67 ms` queued and started at
  `targetV=400.0`. Its next report arrived after `43 ms`; the line delta remained one while the point delta grew to
  eight, and modeled input speed rose. Maximum Slow Smoothness nevertheless selected `baseMs=225.1` and
  `targetV=250.0`, below the live `287.7 px/s`. The following two-line report accelerated normally.
- The independent start at `00:14:55.236` reached output in `5.99 ms` with `0.71 ms` queued. Its `25 ms` follow-up
  grew from one point to ten points, but selected `baseMs=193.0` and `targetV=328.4`, below the live
  `363.1 px/s`. Again, the next larger report restored acceleration.
- Both sequences sustained approximately `120 Hz` active output and had no tap disable, display recovery/failure,
  target churn, rate limit, or dropped carry. This was a duration-policy velocity notch, not delivery latency.

Confirmed root cause and fix (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`): the engine
correctly derives distance and modeled velocity from line units so it does not compound macOS acceleration. However,
the much larger point delta is still reliable binary evidence that a low-line-unit report is already in a hardware
acceleration ramp. The existing raw-cadence bypass cannot help the first measured follow-up because its raw interval
and one-sample smoothed interval are equal. The duration policy now uses point amplification only as a binary guard:
when a measured one- or two-unit report has more than twice as many points, modeled output speed rose but remains in
the slow-smoothing band, and its requested target would decelerate a live animator, cap its directly-driven base to
the existing adaptive opening cap. Telemetry records `action=cap-accelerating-low-unit-ramp` and both velocities.

Preserved behavior:

- Point delta does not scale modeled speed, output distance, or retained carry. The guard only prevents a confirmed
  accelerating report from requesting less velocity than the visible opening.
- A genuine one-point careful report does not match. Substantial input above two line units, input outside the slow
  band, and a retarget that already requests acceleration keep the ordinary path. No report-count confirmation,
  timer, delayed replay, or extra distance is introduced.
- Measured Slow Smoothness still begins with report two. The selected cap includes its adaptive duration ratio;
  unlike a stopped long-idle wake report, a live ordinary opening is not forced to raw normal smoothness.

Verification:

- `./dev.sh scroll-tests` passes deterministic cases for the captured amplified-point velocity notch, a true
  one-point slow report, an already-accelerating target, substantial input, and the slow-band boundary, along with
  the existing cadence, display lifecycle, and output-bound suites under `clang -Wall -Wextra -Werror`.
- Captured-trace replay caps the `00:14:41.259` base from `225.1 ms` to approximately `128 ms`, raising its target
  from `250` to roughly `440 px/s`. It caps `00:14:55.261` from `193.0 ms` to approximately `120 ms`, raising its
  target from `328` to roughly `527 px/s`. Their already-accelerating next reports do not match the new guard.
- `git diff --check`, repeated `./dev.sh build`, and final `./dev.sh run` passed. Final helper PID `23775` logged
  `MFSCROLL_CONFIG action=reload-reset` and the expected startup tap re-enable.
- The final helper captured the new path on three independent ordinary starts at `00:19:29.746`, `00:19:31.445`,
  and `00:19:32.767`. Their amplified one-unit follow-ups would have targeted only `273.1`, `265.5`, and
  `267.3 px/s` against a live `323.2 px/s`; the cap selected `125.3–126.5 ms` bases and raised the actual targets
  to `464.0–468.6 px/s` on those same reports. The starts reached first output in `8.44–14.92 ms` with
  `0.63–0.90 ms` queued, subsequent reports accelerated normally, and active output returned to `120 Hz` with
  approximately `9.3–9.4 ms` maximum gaps. No tap, display, rate-limit, or dropped-carry failure accompanied them.

Remaining verification/tradeoff: the target accelerated path is physically verified. A deliberate opening whose
measured follow-up remains one line/one point still needs a focused feel check to complement the deterministic
non-match case. The point/line divergence is macOS-accelerated rather than raw HID data, so it is deliberately used
only to prevent deceleration, not to amplify distance. Horizontal/effect paths and other attached displays remain
outside this physical pass.

### 2026-08-03 — Chromium PDF/content zoom jumped after a smooth opening

Symptom: wheel zoom with Control held or a latched Scroll & Zoom mode could begin smoothly on an ordinary page, but
then jump by a large amount in a PDF or another embedded Chromium content view.

Evidence/root cause: no rolling physical capture was active when the report arrived, so this is a code-confirmed
output-path diagnosis pending a physical trace. `Scroll.m` routes every zoom effect through the TouchDriver curve and
the synthetic magnification-event path, not the Regular pixel-scroll path. On its first output frame, the Chromium
workaround posted the ordinary `Began` delta and then immediately posted a `Changed` delta enlarged by a fixed
`+380/800` or `-250/800`. A normal frame delta is only `pixels/800`, so this injects a discrete 0.475 or 0.3125
magnification step. PDFium/embedded viewers consume that injected second event as a large zoom step, explaining the
smooth-then-jump sequence.

Fix (`Helper/Core/Scroll/Scroll.m`): remove the Chromium bundle-specific magnitude boost. The ordinary nonzero
`Began` event and normal terminal phase are preserved; the next display-paced animator callback provides the first
`Changed` delta at its real magnitude. `MFSCROLL_ZOOM action=begin ... chromiumBoost=0` records the new start path.
No input is delayed, accumulated, amplified, replayed, or retimed.

Verification:

- `git diff --check` and `./dev.sh scroll-tests` passed all cadence, display-link lifecycle, and output-policy
  suites.
- `./dev.sh build` passed (existing unrelated warnings only), and `./dev.sh run` rebuilt, launched the Debug app,
  and restarted its embedded helper.
- The recorder could not provide a physical before/after trace in this environment: its snapshot was empty and no
  active launchd recorder was visible. A manual Chromium PDF/content-view pass is therefore still required.

Preserved behavior/tradeoff: ordinary Chromium page zoom may begin on the following display callback if Chromium
ignores the `Began` delta, rather than receiving a fabricated large first-frame delta. This is at most one display
frame and avoids changing zoom scale by unrequested distance. Regular scrolling, its cadence policy, acceleration,
settling protection, output bounds, target resets, and display-link recovery are unchanged.

### 2026-08-03 — removing the PDF jump made slow Chromium page zoom appear inert

Symptom: the prior removal of the first-frame magnification boost made canvas/PDF zoom smooth, but slow normal
Chromium page zoom could appear to do nothing.

Evidence/root cause: this is a user-confirmed follow-up to the preceding code-path diagnosis; a rolling physical
capture remains unavailable in this environment. The prior version delivered its first nonzero Chromium delta with
the `Began` phase. The existing workaround's own comment documented that Chromium may ignore that delta. The
TouchDriver response can finish before a slowly turned wheel produces a second animator callback, leaving no
accepted `Changed` delta and therefore no visible page zoom. Restoring the old magnitude boost would reintroduce
the confirmed PDF/content-view jump.

Fix (`Helper/Core/Scroll/Scroll.m`): for the known Chromium bundle IDs only, a zoom start now posts a zero-value
`Began` event and immediately follows it with the frame's real, unamplified delta as `Changed`. This preserves the
event's phase ordering and sends exactly one frame of requested zoom distance. The start is recorded as
`MFSCROLL_ZOOM action=prime-zero-begin ... chromiumBoost=0`. Other applications retain their normal nonzero
`Began` event.

Verification:

- `git diff --check` and `./dev.sh scroll-tests` passed all cadence, display-link lifecycle, and output-policy
  suites.
- `./dev.sh build` passed with existing unrelated warnings only. `./dev.sh run` rebuilt, launched the Debug app,
  and restarted its embedded helper.
- A focused manual pass remains required: slow single-step and continuous zoom on a Chromium page, a Chromium PDF
  or embedded content view, Control-held zoom, and both latched trackball zoom modes. Confirm the new telemetry
  start marker and absence of an added-distance jump.

Preserved behavior/tradeoff: this adds a zero-valued phase primer only at Chromium zoom-session start; it adds no
timer, input gate, distance reservoir, animation-duration change, or extra nonzero magnification event. Regular
scrolling and all established scroll-session, cadence, acceleration, target, tail, and display-link invariants are
unchanged.

### 2026-08-03 — slow Chromium zoom needed one physical gesture, not one animator gesture

Symptom: the phase-primer follow-up still did not make slow Chromium zoom reliable. The requested behavior is for
the first physical Ctrl-wheel/latched-zoom input to send `Began`, every later zoom delta to send `Changed`, and the
session to send `Ended` only when Control is released or the latched zoom mode exits.

Evidence/root cause: this is a user-directed lifecycle correction; no rolling physical capture is available in this
environment. The former implementation derived magnification phases from `TouchAnimator` callbacks. A TouchDriver
response can end while the user holds Control between sparse wheel reports, so that one physical modifier session
became several short `Began`/`Ended` gestures. Chromium can discard the opening delta of each such gesture. The
previous fixed-distance boost and the zero-begin/changed-in-one-callback attempt both retained the wrong ownership:
they still began only when the animator produced output rather than when the physical zoom interaction began.

Fix (`Helper/Core/Scroll/Scroll.m`): zoom now has a generation-scoped, lock-serialized gesture session. The first
physical zoom report posts a zero-value `Began` synchronously on the scroll queue, then every nonterminal animator
or direct-output frame posts its unamplified delta as `Changed`. Animator end/cancel callbacks no longer emit zoom
`Ended`. `resetState_Unsafe` emits exactly one terminal zero-value `Ended` before modifier release, trackball-mode
exit, target/app changes, clicks, or other explicit session resets cancel output; a generation check rejects any
late old-session callback. New telemetry records `MFSCROLL_ZOOM action=begin-on-input` and `action=end`.

Verification:

- `git diff --check` and `./dev.sh scroll-tests` passed the cadence, display-link lifecycle, and output-policy
  suites.
- `./dev.sh build` and `./dev.sh run` passed; the Debug app and its embedded helper were rebuilt and restarted.
- Manual validation remains required on the deployed helper: slow single Ctrl-wheel input, sparse held-Ctrl input,
  Control release without a follow-up wheel report, Scroll & Zoom / Zoom mode exit without a follow-up wheel
  report, PDF/content zoom, normal Chromium page zoom, a target switch, and a click during an active zoom session.
  Correlate `begin-on-input`, `Changed` outputs, and one `end` per closed session.

Preserved behavior/tradeoff: every real zoom distance still comes from the existing animator and is sent once; the
new long-lived part is phase ownership only. No physical report is deferred, confirmed, dropped, amplified, or
retained. Explicit non-modifier session resets also end zoom, preventing a synthetic touch gesture from leaking
into a new target; ordinary scrolling, cadence policy, acceleration, tail protection, bounds, and display recovery
are unchanged.

### 2026-08-03 — Ctrl release left the synthetic zoom session open until the next wheel report

Symptom: zoom still felt frozen at the start, and releasing Control before beginning ordinary scrolling caused a
visible pause before the page scrolled.

Current telemetry before attribution (helper PID `33491`):

- The `22:32:18.017` Chromium zoom opening recorded `MFSCROLL_ZOOM action=begin-on-input generation=61`; its
  physical input reached the first animator output in `10.31 ms` with `0.53 ms` queued. It nevertheless used the
  zoom TouchDriver's eased `baseMs=250.0`, `durationMs=250.0`, and `targetV=120.0`, versus the ordinary opening's
  `80 ms`/`400 px/s` response. The start feeling is response shape, not queue or display-link latency.
- Control was released after that zoom gesture, but no modifier-callback/reset record occurred then. The next
  ordinary physical wheel report at `22:32:22.444`—`4.427 s` after the zoom opening—was the event that logged the
  zoom `end`, modifier change, and the new plain-scroll start together. Its own first output was healthy at
  `8.41 ms` with `0.71 ms` queued. Thus the reported post-release pause was the target application receiving a
  terminal pinch phase and a first ordinary scroll in the same report, not a scroll-queue delay.
- The capture showed no tap disable, display recovery/failure, target reset, or output-rate failure around either
  transition.

Confirmed root causes:

1. While ordinary scrolling is enabled, `SwitchMaster` keeps keyboard modifiers passively sampled. The existing
   phase-lifecycle fix therefore learned Control was no longer held only when the next wheel report sampled its
   flags; its terminal zoom event was deferred to that report.
2. Zoom still selected the shared eased TouchDriver curve, which spreads a small first zoom distance over `250 ms`.
   That intentionally smooth curve made its opening visually weak despite healthy one-frame delivery.

Fix (`Helper/Core/Coordinate/SwitchMaster.swift`, `Helper/Core/Config/ScrollConfig.swift`,
`Helper/Core/Scroll/Scroll.m`):

- A Ctrl-owned active zoom gesture temporarily promotes the existing keyboard-modifier listener to active mode.
  Control release now calls `Scroll.modifierStateDidChange` without requiring another wheel report, closes the zoom
  phase immediately, and restores the normal configuration-derived listener priority. Latched trackball zoom modes
  do not enable this keyboard-release tracking; their existing explicit mode exit remains the terminal event.
- Zoom selects the existing linear TouchDriver effect curve, retaining display-paced smooth output while avoiding the
  slow eased opening. Rotate and other effect paths retain their existing curves.
- Existing lock/generation ownership still prevents an old animator callback from emitting `Changed` after the
  release-generated terminal phase.

Verification:

- `./dev.sh logs-record-snapshot` captured and correlated physical input, modifier transition, zoom lifecycle,
  latency, queue time, animator response, display, and output telemetry.
- `git diff --check`, `./dev.sh scroll-tests`, `./dev.sh build`, and `./dev.sh run` passed. The app and embedded
  Debug helper were rebuilt and restarted; the rolling recorder remains active for the follow-up pass.
- Manual verification is still required on the new helper: slow Ctrl zoom, Control release while idle (verify `end`
  before a wheel input), the next ordinary scroll, canvas/PDF zoom, normal Chromium zoom, and latched zoom mode
  exit. Confirm no synthetic zoom phase leaks into the new scroll target.

Preserved behavior/tradeoff: the keyboard listener is active only for a live Ctrl-owned zoom session and is restored
immediately after its end. The linear zoom curve changes timing, not requested distance; no report is held, counted,
amplified, or replayed. All ordinary-scroll cadence, acceleration, tail, target, output-bound, and display-recovery
invariants remain unchanged.

### 2026-08-03 — Slow normal Chromium page zoom remained below its visible response threshold

Symptom: after the phase-lifecycle and linear-curve fixes, slowly scrolling with Control held still appeared to do
nothing on a normal web page, even though canvas/content zoom had become smooth.

Current telemetry before attribution (helper PID `37105`): the slow Ctrl-owned openings recorded physical ticks of
about `30 px`, `modelScale=1.50`, and a linear zoom animator target of `166.7 px/s` with `baseMs=180.0`. Their first
output arrived in roughly `7.6–12.5 ms`, with `0.4–0.9 ms` queued. In the same capture, Control release recorded the
modifier callback and `MFSCROLL_ZOOM action=end` before the later ordinary wheel input. This rules out queue latency
and a deferred terminal pinch phase as the cause of this remaining slow-start symptom.

Root cause/inference: the existing zoom mapping, `(dx + dy) / 800`, converts a `30 px` slow report into only `0.0375`
of total magnification, divided further across display-paced output frames. Given the timely observed outputs and the
normal Chromium page's visible non-response, that continuous value is inferred to be below Chromium's practical page
zoom threshold; the threshold itself is not instrumented by the helper.

Change (`Helper/Core/Scroll/Scroll.m`): doubled the uniform magnification mapping to `(dx + dy) / 400`. This applies
to both Ctrl-owned and latched zoom modes on every frame. It deliberately does not add a first-event impulse, extra
phase, or fixed-distance boost, so PDF/content views retain continuous motion rather than receiving the previously
rejected jump.

Verification:

- `git diff --check`, `./dev.sh scroll-tests`, `./dev.sh build`, and `./dev.sh run` were run after the mapping change.
- Manual verification is required on the deployed helper: an extremely slow normal Chromium zoom must move on the
  first input; repeated slow Ctrl zoom must remain continuous; canvas/PDF zoom must remain smooth; Ctrl release while
  idle must emit `end` before the next ordinary scroll; and latched Scroll & Zoom / Zoom exit must close cleanly.

Preserved behavior/tradeoff: zoom distance is now uniformly twice as sensitive in every target, including canvas and
PDF/content views. No report is buffered, discarded, replayed, or specially amplified at session start; animation,
phase ownership, ordinary scrolling, cadence, acceleration, target isolation, and display recovery are unchanged.

### 2026-08-03 — Uniform 2× zoom still did not start normal Chromium page zoom

Symptom: doubling every zoom delta did not make extremely slow normal Chromium page zoom visibly start. The user
requested restoration of the Chromium opening impulse, while retaining the new physical-input-owned zoom lifecycle,
and requested that no residual zoom animation carry into ordinary scrolling after zoom ends.

Current telemetry before attribution (helper PID `38147`): repeated Ctrl zoom sessions recorded
`MFSCROLL_ZOOM action=begin-on-input`, first-output latency of about `5.2–14.6 ms`, and queue time of about
`0.39–1.97 ms`. Their Ctrl release records `MFSCROLL_CONFIG action=modifier-callback` and
`MFSCROLL_ZOOM action=end` before the next ordinary-wheel output (for example, end at `22:39:35.383`, then an
ordinary first output at `22:39:35.511`). The current capture therefore shows neither a blocked input queue nor a
late Ctrl-release terminal phase. It does not expose Chromium's internal page-zoom quantization, so the need for its
opening distance remains application-observed evidence.

Root cause: the uniform mapping—including the temporary `(dx + dy) / 400` scale—still supplied only continuous small
opening values. Chromium page zoom needs the existing target-specific opening distance. Applying that distance to
all targets was previously rejected because PDF/content views visibly jumped. The old failure mode does not apply to
this restoration because the impulse is now limited to Chromium targets and occurs only once as the first `Changed`
frame of an already-open physical zoom gesture; it is not used as a nonzero `Began` phase or applied to content views.

Change (`Helper/Core/Scroll/Scroll.m`): restored the original `/800` continuous mapping and Chromium bundle matching.
For Chrome, Chromium, Arc, Opera, Edge, Vivaldi, and Brave, the first nonzero `Changed` frame receives the prior
sign-aware fixed opening distance (`+380/800` or `-250/800`) once per physical zoom session. `Began` remains the
zero-value event posted synchronously on first physical zoom input, and all subsequent frames remain `Changed`.
Zoom teardown now invalidates the generation, posts `Ended`, and immediately cancels `TouchAnimator` inside the zoom
end operation. A late display-link callback cannot post another zoom change, and the next ordinary scroll starts
without a residual zoom animator tail.

Verification:

- `./dev.sh logs-record-snapshot` captured the current release/end and first-ordinary-output ordering before the
  change.
- `git diff --check`, `./dev.sh scroll-tests`, `./dev.sh build`, and `./dev.sh run` were run after the change.
- Manual verification is required on the deployed helper: slow Chromium page zoom must move at its first real frame;
  PDF/canvas zoom must remain continuous without the Chromium impulse; release Ctrl during active zoom and immediately
  scroll normally to confirm no tail; and exit latched Scroll & Zoom / Zoom mode while output is active.

Preserved behavior/tradeoff: Chromium gets one deliberate opening-distance impulse, so its first response is larger
than later continuous frames. Non-Chromium zoom targets remain on the original continuous scale. No physical report
is delayed, accumulated, or replayed; Ctrl-release tracking, phase ownership, ordinary scroll cadence,
acceleration, target isolation, and display recovery remain unchanged.

### 2026-08-03 — live long-idle wake retarget changed response after report one

Symptom: ordinary scrolling still occasionally felt as if it started slowly and therefore felt inconsistent, most
recently on a normal Arc page after a long idle.

Current telemetry before attribution (helper PID `39643`): the candidate opening at `23:29:37.878` followed
`101.160 s` without wheel input. Its one-line/one-point report used the accepted `baseMs=80.0`, `targetV=400.0`, and
`durationMs=198.0`; the queue took `0.66 ms`, the first nonzero output arrived in `8.99 ms`, the display link started
with `result=0`, and there was no tap disable or display recovery/failure. The second one-unit report arrived `79 ms`
later while the animator was live. Idle-wake shaping then selected maximum Slow Smoothness and
`openingCapMs=131.2`, producing `baseMs=131.2` and `targetV=351.1`. Further slow reports remained around
`131.8–132.6 ms`. This was not delivery latency: the response envelope changed materially after the timely first
report.

Confirmed root cause: `MFScrollIdleWakeBaseDurationCap` deliberately selected the adaptive opening cap for live
animator retargets, while stopped wake responses used the original `80 ms` cap. The distinction was introduced to
preserve maximum Slow Smoothness during live careful movement, but the new physical capture and user report show its
failure mode: one physical opening changes from the normal responsive envelope to a roughly 65% longer base on report
two. That visible inconsistency outweighs the extra live-retarget smoothness during the already-qualified wake ramp.

Fix (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`,
`Helper/Core/Config/ScrollConfig.swift`, `Tests/ScrollCadencePolicyTests.c`): wake-ramp reports now select the tighter
of the responsive and adaptive caps, independent of whether `TouchAnimator` is live. With current configuration this
keeps both report one and early small/slow follow-ups inside the same `80 ms` base-duration envelope. The existing
`750 ms` full-influence interval, following `750 ms` continuous fade, and same-report bypass for input above two
units or outside the slow-speed band remain unchanged.

Verification:

- The captured `23:29:37.957` live second report now selects `80 ms` instead of `131.2 ms`; its `36 px` directly
  driven distance can no longer soften the accepted opening response merely because the first animation is live.
- `git diff --check`, `./dev.sh scroll-tests`, `./dev.sh build`, and `./dev.sh run` were run after the change.
- Manual verification is still required after a physical `>=20 s` idle: a deliberately slow start, a normal
  acceleration, a fast start that exits wake shaping immediately, slow-to-fast and fast-to-slow transitions,
  reversal, Chromium and Safari/content boundaries, and scrolling on each attached display.

Preserved behavior/tradeoff: no report is delayed, confirmed, dropped, amplified, or replayed. Ordinary sparse
cadence outside the qualified wake interval still receives full adaptive Slow Smoothness. Early genuine careful
motion after a long idle is crisper for up to the measured wake interval, then transitions continuously back to its
configured slow response. Acceleration, distance, carry/rate limits, tail/reversal protection, target isolation,
zoom lifecycle, and display recovery are unchanged.

### 2026-08-07 — stopped close reversal weakened its next continuation

Symptom: a deliberate reversal could begin on time but still feel slow to start. The first opposite report moved,
then the next sparse same-direction report restarted more weakly before later accelerated input restored normal
motion.

Current telemetry before attribution (helper PID `58940`):

- At `20:26:19.320`, a Readdown-to-Kitty target change reset the old session. The first one-unit report used the
  accepted `baseMs=80.0`, `targetV=400.0` opening and reached output in `10.14 ms` with `2.13 ms` queued.
- At `20:26:19.546`, a one-unit reversal arrived `132 ms` after the preceding report. The close-reversal cadence
  policy intentionally kept full slow continuity, cancelled the old direction, and delivered the report in
  `7.11 ms` with `0.66 ms` queued. Its response used `baseMs=132.7` and `targetV=241.2`.
- The next one-unit report arrived `216 ms` later at `20:26:19.762`, after that response had stopped. Maximum Slow
  Smoothness restarted it with `baseMs=270.1`, `durationMs=314.5`, and only `targetV=118.5`—less than half the
  opening reversal's target. The amplified follow-up at `20:26:19.801` and the three-unit report at `.831` then
  raised the target to `309.7` and `1447.1 px/s`, respectively. The perceived hesitation was therefore the weak
  stopped restart during the roughly `255 ms` before acceleration, not input delivery.
- Active output around the sequence returned to `119.8–120.0 Hz`. There was no event-tap disable, display recovery
  or start failure, target churn after the initial explicit reset, rate-limit involvement, or dropped distance on
  the affected reports.

Confirmed root cause and fix (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`): a close
slow reversal correctly retained cadence on its first opposite report, but no state linked that opening response to
the immediately following continuation. If the response expired during hardware silence, the next measured
one-unit report could restart from rest with the full roughly `270 ms` maximum-slow base and visibly decelerate the
new direction. A fully blended, low-speed close reversal now arms a one-physical-report session marker. The next
report consumes it immediately; if the reversal response has stopped and that report remains in the same analyzer
gesture, same direction, at most two units, and inside the slow band, its base is capped to the adaptive opening
envelope. The captured `270.1 ms` response becomes approximately `132.7 ms`, raising its requested velocity from
`118.5` to approximately `241 px/s` without changing its distance. Telemetry records
`action=cap-stopped-close-reversal-continuation`.

Preserved behavior:

- The reversal report is still processed immediately, cancels old-direction motion, and retains full cadence
  continuity through the existing `200 ms` close-reversal boundary.
- A live reversal response keeps ordinary velocity-preserving retargeting. A new analyzer gesture, another direction
  change, input above two units, or input outside the slow band bypasses the cap on that same report.
- Ordinary established extremely slow movement, long-idle wake shaping, stale-reversal tapering, fast-tail settling,
  acceleration cadence, distance/carry/rate limits, target resets, and display recovery are unchanged. The marker
  is cleared by every session reset and is neither a confirmation gate nor a delayed replay.

Verification:

- `./dev.sh scroll-tests` passes deterministic coverage of the captured stopped one-unit continuation, the exact
  `270.1 -> 132.7 ms` duration cap, and non-matches for a live response, new gesture, another reversal, substantial
  input, and input outside the slow band. Existing cadence, display lifecycle, and output-policy suites also pass
  under `clang -Wall -Wextra -Werror`.
- `git diff --check` and `./dev.sh build` passed. `./dev.sh run` rebuilt and deployed the Debug app; final helper
  PID `68682` logged `MFSCROLL_CONFIG action=reload-reset` and the expected startup tap re-enable.

Remaining verification/tradeoff: a physical reproduction must still capture the new action and confirm the feel,
followed by close live reversal, stopped close reversal, deliberately sparse same-direction motion, slow-to-fast,
fast stop/rebound, target switching, and the broader required matrix. The first stopped continuation after a close
reversal is intentionally crisper than ordinary established sparse motion, but it remains at the adaptive opening
envelope rather than the raw `80 ms` normal-smoothness cap.

### 2026-08-09 — an unestablished stale restart used its own silence as cadence

Symptom: ordinary scrolling again felt as if it had a slow start. The opening report moved, but a later sparse
same-direction report could restart far more weakly before follow-up input accelerated it.

Current telemetry before attribution (helper PID `68682`):

- The capture ruled out input delivery and display-link delay. Across `106` starts, first nonzero output arrived in
  `5.64–14.79 ms` with `0.36–3.17 ms` queued. `172` active output windows ran at `108.4–120.6 Hz` with at most a
  `17.59 ms` active gap. There was no tap disable, callback recovery, watchdog restart, or display start/refresh
  failure.
- At `22:55:21.727`, a one-unit Discord opening used unknown-cadence normal smoothness, `baseMs=80.0`, and
  `targetV=400.0`; first output arrived in `10.66 ms` with `0.92 ms` queued.
- At `22:55:22.460`, the next same-direction one-unit report arrived after `732 ms`, when the animator had stopped.
  The sparse policy recorded `priorEstimateMs=0.0`, but used the current report's silence as
  `estimateMs=732.0` and `durationRefMs=500.0`. With `memoryBlend=0.77`, that expanded the response to
  `baseMs=316.0`, `durationMs=352.3`, and only `targetV=101.3`. First output was still timely at `12.46 ms` with
  `2.04 ms` queued, confirming that the perceived delay was the weak response envelope.

Confirmed root cause and fix (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`): the stale
cadence comment and earlier regression contract said the current pause may update memory only for a future report,
but a zero-prior-estimate fallback still promoted `physicalInputGap` into the current duration reference. An
unestablished same-direction restart now uses a zero cadence-duration reference on that report. It still selects
measured Slow Smoothness immediately and publishes the `732 ms` estimate for later reports, but its own silence can
no longer lengthen its response. Captured-parameter replay reduces the affected base from about `316 ms` to the
adaptive opening envelope of about `120 ms`, raising its requested velocity from `101` to about `267 px/s` without
changing distance. Telemetry identifies the path as `action=bound-unestablished-stale-cadence` with
`durationRefMs=0.0`.

Preserved behavior:

- The first report remains the normal-smoothness `80 ms` opening. The second sparse report is processed immediately,
  begins measured slow smoothing, and records its cadence without waiting for a third report.
- A cadence estimate that existed before the current report still drives established extremely slow motion.
  Close reversals retain their actual bounded cross-direction gap. Stale-memory and reversal blends still taper at
  the same boundaries.
- Slow-to-fast raw-cadence acceleration, live velocity-preserving retargets, fast-tail/rebound handling, direction
  cancellation, output/carry bounds, target isolation, zoom/effect paths, and display recovery are unchanged. No
  report is delayed, confirmed, discarded, or replayed, and no distance reservoir is introduced.

Verification:

- `./dev.sh scroll-tests` passes the exact `732 ms` zero-prior reference and `316 -> 120 ms` base replay, an
  established prior estimate, and a close reversal's actual-gap reference. Existing wake-ramp, low-unit
  acceleration, close-reversal continuation, cadence seed, display lifecycle, and output-bound suites also pass
  under `clang -Wall -Wextra -Werror`.
- `git diff --check` and `./dev.sh build` passed. The current rolling capture supplied adjacent physical coverage
  for fresh starts, repeated slow reports, slow-to-fast and fast-to-slow motion, active/paused reversals, settling
  micro-glides, target resets, and display-paced output on display `1` before deployment; the changed decision is
  additionally covered by deterministic replay.
- Deployed helper PID `4391` physically reproduced the target path. Its opening at `23:03:12.347` retained
  `baseMs=80.0`, `targetV=400.0`, and reached output in `11.96 ms` with `1.20 ms` queued. The next one-unit report
  at `23:03:13.175` arrived after `825 ms` and logged `action=bound-unestablished-stale-cadence`,
  `priorEstimateMs=0.0`, `durationRefMs=0.0`, `baseMs=115.6`, and `targetV=276.9`; it reached output in
  `11.64 ms` with `5.01 ms` queued. Subsequent measured slow reports retargeted normally, active output returned to
  `108.2–120.0 Hz`, and a `179 ms` close reversal retained `durationRefMs=179.0` before faster input accelerated.
  No tap, display-start, recovery, rate-limit, or dropped-carry failure accompanied the pass. The final pure-helper
  extraction rebuilt successfully and was deployed as PID `7006`, which logged the expected config reset and tap
  re-enable.

Remaining verification/tradeoff: the affected branch, subsequent established slow motion, acceleration, reversal,
fast-tail settling, and display-paced output are physically covered. The complete cross-app/display/effect matrix
remains manual. On the second same-direction report after a `500 ms–1.5 s` gap, a genuinely continuous sparse stream
now receives measured adaptive smoothing but not a long cadence-derived duration until a cadence estimate existed
before the report. That is intentionally crisper at the ambiguous opening while retaining later established sparse
continuity.

### 2026-08-11 — abrupt deceleration tail weakened stopped and stale restarts

Symptom: a start/stop scroll in Browser felt slow to begin even after the unestablished-cadence duration fix. The
current rolling telemetry from helper PID `7006` shows that delivery was healthy but exposes two response-shape
variants of the same missing tail classification:

- At `22:49:13.998`, a same-direction one-unit/one-point report abruptly decelerated from approximately `897` to
  `111 px/s`, or `12.3%` of the preceding modeled speed. The live animator retargeted normally, but the report was
  recorded as eligible slow-cadence history. At `22:49:14.711`, after a `712.1 ms` pause and after animation had
  stopped, the next one-unit report logged `previousSeed=1`, `priorEstimateMs=173.1`,
  `action=taper-stale-cadence`, `baseMs=128.1`, and `targetV=249.9`. Its first output still arrived in `13.93 ms`
  with only `0.65 ms` queued, and display-link start returned `result=0`; this was not an input queue, display link,
  event tap, or target-app stall.
- At `22:46:46.406`, a one-unit/one-point report arrived after the preceding response had stopped and abruptly
  decelerated from approximately `1021` to `69 px/s`, or `6.8%`. It received maximum slow smoothing directly:
  `baseMs=270.4` and `targetV=107.2`. Delivery was again healthy at `8.39 ms` input-to-first-output with `0.56 ms`
  queued and display start `result=0`.

Root cause: `MFScrollReportCanSeedSlowCadence` excluded known fast-tail and settling-tail paths but treated every
other low-unit, low-modeled-speed report as deliberate sparse motion. A sharp deceleration edge following much
faster multi-unit motion could therefore seed a stopped restart up to `1.5 s` later. When the sharp edge itself
arrived after the animator stopped but stayed inside ScrollAnalyzer's gesture, it could also use the full measured
slow-smoothing duration. The correspondence between the nearby capture and the subjective report is inferred; the
two policy failures and their output shapes are directly confirmed by telemetry and code replay.

Change:

- `ScrollCadencePolicy.h` now classifies only measured, same-direction, one- or two-unit reports whose modeled speed
  falls to at most `25%` of the immediately preceding modeled speed. The two captures are well inside that boundary;
  gradual careful deceleration is outside it.
- The report is still processed immediately. If animation is live, ordinary velocity-preserving retargeting remains
  unchanged. If it has stopped, only the report's base duration is capped to the adaptive opening envelope; captured
  replay reduces `270.4 ms` to about `132.9 ms` and raises requested speed from `107` to about `218 px/s` without
  changing distance.
- A classified sharp deceleration edge cannot seed later sparse-cadence continuity. Captured replay makes the
  `712.1 ms` report an ordinary bounded opening (`80 ms`, approximately `400 px/s`) rather than reusing the tail's
  stale `173.1 ms` estimate. The current edge may still update timing history for a later genuinely established
  slow stream.
- `ScrollConfig.swift`, `Scroll.m`, and `ScrollCadencePolicyTests.c` contain the threshold, integration, telemetry
  (`action=cap-stopped-sharp-deceleration-tail`), and exact captured-policy regression cases.

Preserved behavior: first-report delivery and distance are unchanged; no report is delayed, confirmed, discarded,
or replayed. Established repeated sparse scrolling, gradual fast-to-slow motion, raw-cadence slow-to-fast response,
live velocity-preserving retargets, close-reversal continuation, long-idle wake shaping, fast-tail/rebound handling,
direction cancellation, output/carry bounds, target resets, effect paths, and display recovery retain their existing
policies. A direction change is explicitly excluded from the new classification, and no event-count gate, timer, or
distance reservoir was introduced.

Verification:

- `git diff --check` and `./dev.sh scroll-tests` pass. Deterministic coverage replays both captured speed ratios,
  stopped versus live animation, the `270.4 -> 132.9 ms` duration cap, cadence-seed rejection, and non-matches for
  gradual deceleration, reversals, substantial input, and unmeasured openings. Existing cadence, wake-ramp,
  low-unit acceleration, close-reversal, display-link lifecycle, and output-bound suites pass under
  `clang -Wall -Wextra -Werror`.
- `./dev.sh build` and `./dev.sh run` pass. The rebuilt app restarted through its normal lifecycle; helper PIDs
  `55195` and then `55225` logged `action=reload-reset` and event-tap `action=re-enable` during deployment. On PID
  `55225`, the fresh Browser opening at `22:55:55.260` kept `baseMs=80.0`, `targetV=400.0`, and reached output in
  `8.75 ms` with `0.52 ms` queued. The stopped one-unit start at `22:55:58.330`, following a protected tail, logged
  `previousSeed=0`, the same `80 ms`/`400 px/s` opening, and `13.93 ms` first-output latency with `0.50 ms` queued.
  Adjacent starts measured `6.11–14.43 ms` with `0.53–0.61 ms` queued, active output measured `112–120 Hz`, and all
  display starts returned `result=0`.
- The pre-change rolling capture supplies adjacent physical coverage for fresh bounded starts, repeated slow input,
  slow-to-fast and fast-to-slow motion, active and paused reversals, a Browser-to-Readdown target reset, display `1`
  starts with `result=0`, and active output near `108–120 Hz`. No unexplained tap disable or display recovery appears
  around the affected reports.

Remaining verification/tradeoff: bounded starts and tail-seed rejection are physically covered after deployment,
but the new sharp-deceleration action itself is exact-policy replayed rather than physically recaptured. The complete
cross-app, multi-display, horizontal, zoom/effect, and content-boundary matrix remains manual. An intentional
instantaneous deceleration below one quarter of the preceding modeled speed now receives a crisper stopped response
and cannot alone establish a later sparse continuation. The current report remains fully delivered, and one
subsequent genuine slow report can establish history again, limiting that ambiguity to the captured transition edge.

### 2026-08-15 — stopped 382ms reversal retained a weak partial cadence opening

Symptom: an ordinary Browser scroll again felt slow to start. The bounded rolling recorder was no longer active, but
the current unified log retained the complete candidate sequence from helper PID `1797`:

- At `09:51:40.930`, a stopped one-unit opening used the accepted unknown-cadence response: `baseMs=80.0`,
  `targetV=400.0`, and first output in `8.30 ms` with `1.76 ms` queued.
- At `09:51:41.313`, a one-unit reversal arrived after `382.0 ms`, with the preceding animator stopped. It entered
  `action=taper-reversal-cadence` with `reversalBlend=0.39`, retained the actual `382.0 ms` duration reference, and
  selected `baseMs=173.8`, `durationMs=243.1`, and only `targetV=184.1`. First output was still timely at `9.51 ms`
  with `2.88 ms` queued; direction cancellation processed the same tick and display start returned `result=0`.
- The next physical report arrived `38 ms` later and immediately retargeted to `812.9 px/s`. Active output returned
  to about `120 Hz`. There was no event-tap disable, display recovery/failure, rate limit, dropped carry, target
  churn, or retained old-direction distance around the sequence.

Confirmed root cause: the reversal taper correctly made cadence influence decay between the accepted `200 ms` close
boundary and the `500 ms` gesture boundary, but response visibility was independent of that taper. When the old
response had already stopped, a later partially blended reversal was visibly another opening while still spreading
its `32 px` over `173.8 ms`. That made it less than half as fast as the immediately preceding ordinary opening. The
previous sharp-deceleration fix is working: at `09:49:11.878`, a captured `0.117` speed ratio logged
`action=cap-stopped-sharp-deceleration-tail`, followed by the qualified wake cap and an `80 ms`/`362.5 px/s`
response. This report is a distinct paused direction-change path, not a regression of tail classification.

Change (`Helper/Core/Config/ScrollConfig.swift`, `Helper/Core/Scroll/ScrollCadencePolicy.h`,
`Helper/Core/Scroll/Scroll.m`, `Tests/ScrollCadencePolicyTests.c`):

- Only a stopped, first analyzer report that is a small/slow direction change and already qualified for remembered
  slow cadence can enter the new response cap. The accepted `292 ms` paused-reversal capture remains unchanged.
- Beginning at `300 ms`, continuously blend the cadence-derived base toward the adaptive opening envelope; reach
  full influence at `380 ms`, before the reported `382 ms` case. The exact replay reduces `173.8 ms` to about
  `101.2 ms`, raising its requested velocity from `184` to about `316 px/s` without changing distance or cadence
  classification. Telemetry records `action=cap-stopped-paused-reversal-opening` with both blends and durations.
- A live animator, a close reversal, same-direction sparse input, input above two units, input outside the slow band,
  or a reversal at/after the `500 ms` fresh-gesture boundary does not match. The transition between `300–380 ms` is
  continuous rather than a report-count or timing discontinuity.

Preserved behavior: the current reversal still cancels old-direction motion and is delivered immediately. Full
cadence continuity through `200 ms`, the accepted `292 ms` response, live velocity-preserving retargets, ordinary
established sparse motion, stale same-direction tapering, long-idle wake shaping, sharp/fast/settling-tail handling,
raw-cadence acceleration, distance/rate/carry bounds, target isolation, zoom/effect paths, and display recovery are
unchanged. No report is delayed, confirmed, discarded, replayed, or stored in a second reservoir.

Verification:

- `git diff --check` and `./dev.sh scroll-tests` pass under `clang -Wall -Wextra -Werror`. Deterministic cases cover
  the exact `382 ms` full cap, the unchanged `292 ms` boundary, a continuous `340 ms` midpoint, the
  `173.8 -> 101.2 ms` base replay, and non-matches for live, close, same-direction, substantial, fast, and fresh
  `>=500 ms` reversals. Existing wake, acceleration, cadence seed, sharp-tail, close-reversal continuation,
  display-link lifecycle, and output-bound suites also pass.
- `./dev.sh build` and `./dev.sh run` pass; the rebuilt Debug helper is deployed. The bounded `2,000`-event recorder
  was restarted after deployment so future recurrences no longer depend on sparse unified-log persistence.
- Deployed helper PID `17139` supplied adjacent physical coverage. Its Hik-Connect fresh opening at
  `10:07:36.889` used `80 ms`/`400 px/s`, reached output in `17.01 ms` with `1.59 ms` queued, accelerated through a
  qualified long-idle wake ramp without leaving the `80 ms` envelope, and sustained `120 Hz` output. A stopped
  `591 ms` reversal at `10:07:37.772` correctly remained a fresh `80 ms`/`400 px/s` opening, cancelled the old
  direction, and reached output in `7.66 ms` with `1.10 ms` queued. Display starts returned `result=0`; no tap,
  recovery, rate-limit, or dropped-carry failure appeared.
- The same deployed helper then physically exercised the new transition in Kitty. A stopped `331 ms` reversal at
  `10:07:56.356` logged `openingCapBlend=0.39` and reduced `baseMs=167.2` to `144.9`; first output arrived in
  `12.06 ms` with `5.53 ms` queued. A near-boundary `487 ms` reversal at `10:08:00.251` logged the full
  `openingCapBlend=1.00`, reduced `94.6 ms` to `82.3 ms`, and requested `388.9 px/s`, with first output in
  `13.01 ms` and `1.15 ms` queued. The accepted `254 ms` close reversal at `10:07:56.993` emitted no new cap action,
  while `653 ms` and `850 ms` fresh reversals remained the normal `80 ms`/`400 px/s` response. Follow-up reports
  retargeted immediately and active output returned to approximately `112–120 Hz`.

Remaining verification/tradeoff: the new partial and full stopped-reversal cap actions, close non-match, fresh
reversals, acceleration, and display-paced output are physically covered after deployment; the exact reported
`382 ms` parameters remain deterministic replay. The broader cross-app, multi-display, horizontal, zoom/effect,
content-boundary, rebound, and genuinely parked-display matrix remains manual. A deliberate stopped reversal late
in the old partial-cadence window is now crisper, while close, live, and the previously accepted `292 ms` reversal
preserve their established behavior. The bounded recorder remains active for recurrence monitoring.

### 2026-08-15 — stopped same-direction slow continuations repeatedly reopened at maximum smoothing

Symptom: shortly after deploying the paused-reversal fix above, an ordinary Kitty scroll again felt slow. The active
bounded recorder captured the complete sequence from helper PID `17139`:

- The opening at `15:03:49.985` was healthy: one unit used the accepted `80.0 ms` base and `400.0 px/s` target;
  first output arrived in `14.38 ms` with `0.84 ms` queued. Several following reports accelerated and retargeted
  live without a velocity notch.
- At `15:03:51.137`, a same-direction one-unit report arrived after the preceding animation had stopped. It had a
  measured `245.0 ms` analyzer cadence but maximum adaptive smoothing selected `baseMs=270.4`,
  `durationMs=311.4`, and only `targetV=111.0`. First output was on time at `13.29 ms` with `1.68 ms` queued.
- At `15:03:51.874`, the same path recurred: the animator was stopped, yet another same-direction one-unit report
  selected `baseMs=270.4`, `durationMs=309.7`, and `targetV=107.2`. Output began in `8.13 ms` with `0.66 ms`
  queued. A physical report `43 ms` later immediately entered raw-cadence acceleration and retargeted to
  `282.4 px/s`, confirming that the weak interval was the stopped opening response rather than missing input.
- The rolling window contains the same stopped approximately `270 ms` response at `14:02:18.441`,
  `14:20:33.131`, `14:50:38.702`, `14:50:44.247`, and `14:50:44.565`, so this is a recurring path rather than the
  earlier paused reversal. Active output around the reported sequence returned to approximately `112–120 Hz`.
  There was no unexplained tap disable, display-link start/recovery failure, target churn, rate limiting, dropped
  carry, or retained old-direction distance.

Confirmed root cause: maximum slow smoothing is useful while sparse reports overlap a still-running response, but
the same approximately `270 ms` base was also applied after that response had completely ended. At that point there
was no motion left for the long duration to preserve across the preceding silence; it merely reopened the current
approximately `29–30 px` report at roughly `107–111 px/s`. The queue, display link, target app, and paused-reversal
policy were healthy.

Change (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`,
`Tests/ScrollCadencePolicyTests.c`):

- A measured, same-direction, non-opening report of at most two units in the adaptive slow band now uses the
  adaptive opening-duration envelope only when the animator is already stopped. The exact captured replays cap
  `270.4 ms` to approximately `132.9 ms`, raising the requested target to approximately `218–226 px/s` without
  changing distance, cadence history, or delivery timing.
- A live sparse response does not match, preserving the overlap that makes deliberate extremely slow scrolling
  continuous. Analyzer openings, reversals, substantial/fast reports, and Apple-acceleration paths also do not
  match. Existing long-idle wake, stopped sharp-tail, expired close-reversal, and expired fast-tail policies remain
  authoritative and are excluded from this generic stopped-continuation action to avoid double shaping.
- Telemetry records `action=cap-stopped-slow-continuation` with gap, unit count, modeled speed, opening cap, and both
  base durations. No report is delayed, confirmed, discarded, replayed, or stored in another reservoir.

Preserved behavior: first-report `80 ms` response, live velocity-preserving retargets, established sparse cadence
while an animation is active, slow-to-fast raw-cadence acceleration, fast/settling/sharp-tail behavior, paused and
close reversals, long-idle wake shaping, target/session resets, rate/carry/distance bounds, horizontal and zoom/effect
paths, display generation/recovery, and direction cancellation are unchanged.

Verification:

- `git diff --check` and `./dev.sh scroll-tests` pass. The cadence suite runs under
  `clang -std=c11 -Wall -Wextra -Werror` and covers both captured stopped speeds, the exact
  `270.4 -> 132.9 ms` cap, preservation of a base already below the cap, and non-matches for live motion, an analyzer
  opening, reversal, substantial/fast input, unmeasured cadence, and disabled adaptive control. Existing idle-wake,
  acceleration, paused/close reversal, cadence-seed, sharp-tail, display lifecycle, and output-bound cases pass.
- `./dev.sh build` and `./dev.sh run` pass with existing unrelated warnings. The rebuilt Debug helper was deployed
  through the normal app lifecycle; PID `19045` logged the expected config reset and user-input tap re-enable at
  `15:08:45–46`. The current build includes both today's paused-reversal fix and this stopped-continuation fix.
- The bounded `2,000`-event recorder remained active across deployment. Pre-change physical telemetry covers fresh
  starts, live slow-to-fast motion, stopped same-direction continuations, a paused reversal, normal first-output
  latency, and display-paced output; the changed stopped decision is covered by deterministic captured-parameter
  replay.

Remaining verification/tradeoff: a physical post-deployment occurrence should log the new action and confirm feel.
The broader cross-app, multi-display, horizontal, zoom/effect, content-boundary, rebound, and parked-display matrix
remains manual. A deliberately sparse report that arrives only after its prior response has fully ended is now
crisper; genuinely overlapping sparse motion retains the accepted longer smoothing. The recorder remains active.

### 2026-08-16 — stopped remembered cadence weakened same-direction analyzer openings

Symptom: another ordinary slow start was reported after the stopped measured-continuation fix above. The active
bounded recorder had captured two remaining same-direction cases on deployed helper PID `19045`:

- At `23:01:58.286`, a one-unit report arrived after `711 ms`. ScrollAnalyzer correctly classified it as the first
  report of a new gesture and the preceding animator was stopped, but slow-cadence memory retained a `371.8 ms`
  duration reference with `memoryBlend=0.79`. The report selected `baseMs=245.7`, `durationMs=295.2`, and only
  `targetV=130.3`. First output still arrived in `14.52 ms`; `6.02 ms` was input queue time.
- At `23:03:26.347`, the same stopped path recurred after `616 ms`, reusing a `274.9 ms` duration reference with
  `memoryBlend=0.88`. It selected `baseMs=196.9`, `durationMs=258.9`, and `targetV=162.5`; first output arrived in
  `7.77 ms` with `0.81 ms` queued. A report `48 ms` later accelerated immediately, isolating the weak interval to
  the response chosen for the opening rather than delayed or missing input.
- The newest pre-change physical sequence at `00:01:52.385–00:01:54.124` did not reproduce the branch. Its fresh
  Browser opening used `80 ms`/`400 px/s` and reached output in `6.72 ms` with `0.76 ms` queued; stopped wake and
  expired-tail openings were bounded to `80–132.7 ms`, follow-up acceleration was immediate, active output returned
  to approximately `112–120 Hz`, and display starts returned `result=0`. Across the current window there was no
  unexplained tap disable, display-link start/recovery failure, rate limit, dropped carry, or target churn.

Confirmed root cause: the preceding fix intentionally handled measured in-gesture continuations only. These two
reports crossed ScrollAnalyzer's `500 ms` gesture boundary, so they had no current measured cadence and escaped that
cap even though established cadence memory still lengthened their response. Since the preceding animation had
already ended, the remembered duration could not preserve visual continuity across the silence; it only made the
new physical opening weak. The correspondence to the subjective report is inferred, while the policy hole and both
weak response shapes are directly confirmed by telemetry and captured-parameter replay.

Change (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`,
`Tests/ScrollCadencePolicyTests.c`):

- A same-direction first analyzer report now regains the adaptive opening-duration envelope only when slow-cadence
  continuation has qualified, an established positive duration reference is actually being reused, the old animator
  is stopped, the physical gap is at or beyond the analyzer boundary, and the report is at most two units within the
  slow band. The exact captured replays cap `245.7 ms` and `196.9 ms` to approximately `132.9 ms`, raising both
  approximately `32 px` responses to about `241 px/s` without changing their distance.
- Cadence estimate and memory are retained for later reports; only this stopped visible opening's response base is
  bounded. Telemetry records `action=cap-stopped-remembered-slow-opening` with gap, duration reference, unit count,
  modeled speed, opening cap, and both base durations.
- A live overlapping response, measured in-gesture continuation, direction change, unestablished cadence, gap below
  the analyzer boundary, substantial/fast input, and disabled adaptive control do not match.

Preserved behavior: no report is delayed, confirmed, discarded, replayed, or distance-scaled. First unknown-cadence
openings, unestablished second sparse reports, genuinely overlapping sparse motion, measured stopped continuation,
close and paused reversals, slow-to-fast raw-cadence acceleration, fast/settling/sharp-tail handling, long-idle wake
shaping, target/session resets, rate/carry/distance bounds, horizontal and zoom/effect paths, display recovery, and
direction cancellation retain their existing policies.

Verification:

- `git diff --check` and `./dev.sh scroll-tests` pass. The cadence suite runs under
  `clang -std=c11 -Wall -Wextra -Werror` and covers both exact `711 ms`/`371.8 ms` and `616 ms`/`274.9 ms` captured
  decisions, the `245.7/196.9 -> 132.9 ms` caps, preservation of an already shorter base, and non-matches for live
  motion, measured continuation, reversal, zero duration reference, substantial/fast input, and a sub-boundary gap.
  Existing idle-wake, low-unit acceleration, stopped measured continuation, close/paused reversal, cadence-seed,
  sharp-tail, display lifecycle, and output-bound suites pass.
- `./dev.sh build` and `./dev.sh run` pass with existing unrelated warnings. The rebuilt Debug helper was deployed
  through the normal app lifecycle; helper PID `41765` logged the expected config reset and user-input tap re-enable
  at `00:06:03–04`. The bounded `2,000`-event recorder remains active across deployment.
- Pre-change physical telemetry supplies adjacent coverage for fresh starts, stopped wake continuation, slow-to-fast
  acceleration, fast-to-slow tail handling, direction changes, Browser and Kitty targets, successful display starts,
  and display-paced output. The changed stopped remembered-opening decision is covered by deterministic replay of
  the captured parameters.

Remaining verification/tradeoff: the next physical occurrence should log the new action and confirm subjective feel;
the exact action has not yet recurred after deployment. The broader cross-app, multi-display, horizontal,
zoom/effect, content-boundary, rebound, and genuinely parked-display matrix remains manual. An established sparse
stream whose reports arrive only after the prior response has fully stopped will now visibly reopen more crisply at
an analyzer boundary, while live overlap and the retained cadence state preserve the accepted continuity behavior.

### 2026-08-16 — rising amplified point magnitude escaped the opening velocity-notch guard

Symptom: after deploying the stopped remembered-opening cap, another ordinary Browser start felt slow. The current
bounded recorder on helper PID `41765` shows the new stopped policies working, but captured one remaining live
opening notch:

- At `12:52:42.895`, a fresh one-unit/one-point Browser opening used the accepted `baseMs=80.0` and
  `targetV=400.0`; first output arrived in `14.47 ms` with `0.77 ms` queued and display start returned `result=0`.
- At `12:52:42.953`, its first measured one-unit report carried six points. The existing amplified-low-unit guard
  prevented deceleration and selected `baseMs=129.8`, keeping the live response at about `402 px/s`.
- At `12:52:43.041`, the next report still carried one line unit but its point magnitude rose from `6` to `14`,
  evidence that the physical/macOS acceleration ramp was continuing. Its packet gap was longer, however, so the
  line-derived modeled speed fell and the old guard did not match. Maximum slow smoothing selected `baseMs=252.3`
  and retargeted live motion from `342.3` down to `227.5 px/s`. Output callbacks remained approximately `120 Hz`;
  there was no tap, display-link, target, rate-limit, or dropped-carry failure.
- The newest pre-change sequence at `12:53:35.889` was healthy rather than another policy failure: it opened at
  `80 ms`/`400 px/s`, its `20 ms` amplified follow-up used the qualified long-idle cap and requested `830 px/s`,
  active output ran at `120 Hz`, and first output arrived in `17.38 ms` with `5.90 ms` queued. The correspondence
  between the subjective report and the `12:52:43.041` notch is inferred; the notch itself is directly captured.

Confirmed root cause: `MFScrollShouldCapAcceleratingLowUnitRamp` required rising line-derived modeled speed even
though point amplification was already used as independent binary evidence of a hardware acceleration ramp. A
longer packet interval could therefore make modeled speed fall while point magnitude continued rising, allowing the
duration curve to request a large live deceleration during the opening.

Change (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`,
`Tests/ScrollCadencePolicyTests.c`):

- The existing guard now qualifies when either modeled speed rises or the current amplified point magnitude rises
  over the immediately preceding handled report. It still requires measured input of at most two line units, point
  amplification above twice the line count, modeled speed inside the slow band, a live animator, and a requested
  target below current velocity.
- Point magnitude remains a binary response-shape signal only. It does not scale modeled speed, distance, carry, or
  rate limits. The exact captured `14 > 6` replay now applies the existing adaptive opening envelope instead of the
  `252.3 ms` base.
- Session resets clear the previous point magnitude, and an early bounded settling micro-glide clears it before
  returning. A flat or falling point magnitude with falling modeled speed remains ordinary deceleration; the nearby
  captured `15 -> 13` falling-point case is an explicit deterministic non-match.
- Telemetry retains `action=cap-accelerating-low-unit-ramp` and now records `previousPointPx` so the two acceleration
  signals can be distinguished in later captures.

Preserved behavior: first-report timing and distance, genuine falling-magnitude deceleration, reports without point
amplification, already-accelerating retargets, substantial/fast input, measured/stale sparse cadence, stopped
continuation and remembered-opening caps, close/paused reversals, long-idle wake shaping, fast/settling/sharp-tail
handling, target/session resets, distance/rate/carry bounds, horizontal and zoom/effect paths, display recovery, and
direction cancellation are unchanged. No report is delayed, confirmed, discarded, replayed, or amplified.

Verification:

- `git diff --check` and `./dev.sh scroll-tests` pass. Deterministic coverage includes the exact rising-point /
  falling-model decision, the existing rising-model decision, a falling-point/falling-model non-match, a genuine
  one-point careful report, an already-accelerating target, substantial input, and the slow-band boundary. Existing
  stopped measured/remembered openings, wake, reversal, cadence-seed, sharp-tail, display lifecycle, and output-bound
  suites pass under `clang -Wall -Wextra -Werror`.
- `./dev.sh build` and `./dev.sh run` pass. The rebuilt Debug helper was deployed through the normal lifecycle as
  PID `12093`, which logged the expected config reset and tap re-enable.
- The first post-deployment Browser pass at `12:57:56.476` used `80 ms`/`400 px/s` and reached output in `10.36 ms`
  with `0.70 ms` queued. Its amplified one-unit follow-up logged `pointPx=9 previousPointPx=1`, applied the existing
  cap, and requested `506.3 px/s`; subsequent substantial reports accelerated immediately, active output ran at
  approximately `116–120 Hz`, display starts returned `result=0`, and a live reversal cancelled the old session and
  delivered its `80 ms`/`400 px/s` opening in `12.03 ms` with `1.32 ms` queued.

Remaining verification/tradeoff: the exact rising-point/falling-model action is captured-parameter replayed but has
not yet physically recurred on PID `12093`. The broader cross-app, multi-display, horizontal, zoom/effect,
content-boundary, rebound, and parked-display matrix remains manual. A point-amplified low-unit report whose point
magnitude rises while packet cadence slows now retains the opening envelope instead of decelerating live motion;
flat/falling point magnitude still permits the accepted smooth deceleration path.

### 2026-08-16 — unestablished stopped reversal used its own pause as a weak opening

Symptom: another Browser scroll start felt slow after the rising-point ramp fix. The newest bounded telemetry on
helper PID `12093` captured a different stopped reversal path immediately before the report:

- At `14:33:23.572`, a one-unit negative opening used the accepted unknown-cadence response: `baseMs=80.0`,
  `targetV=400.0`, and first output in `7.15 ms` with `0.75 ms` queued. Display-link start returned `result=0`.
- At `14:33:23.781`, a one-unit reversal arrived after `209.0 ms`, just beyond the full close-reversal cadence
  boundary. The preceding response had stopped and no cadence estimate existed before this report
  (`priorEstimateMs=0.0`), but reversal handling promoted the current cross-direction gap to
  `durationRefMs=209.0`. With `reversalBlend=0.97`, that selected `baseMs=156.0` and only `targetV=205.2`, about
  half the ordinary opening velocity. First output was still timely at `6.66 ms` with `0.67 ms` queued, direction
  cancellation kept the current report, and display start again returned `result=0`.
- The amplified report `48 ms` later immediately used the qualified idle-wake cap and requested `747.7 px/s`,
  isolating the weak interval to the stopped reversal's response envelope. Subsequent substantial input accelerated
  normally and active output returned to approximately `120 Hz`.

Confirmed root cause: the reversal duration policy intentionally permits the current bounded cross-direction gap
to establish cadence when no prior estimate exists. That preserves useful close-reversal continuity while motion is
still visible, but the new capture shows a failure just outside the fully continuous `200 ms` window: when the old
response is already stopped, the report's own silence cannot bridge visible motion and only weakens a new opening.
The correspondence between the subjective report and this immediately preceding sequence is inferred; the weak
response shape and healthy delivery/display path are directly captured. This is not a recurrence of the live
point-ramp notch.

Change (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`,
`Tests/ScrollCadencePolicyTests.c`):

- A stopped, first analyzer report now regains the adaptive opening envelope only when it is a small/slow reversal,
  slow-cadence continuation qualified, no positive cadence estimate existed before this report, and its gap lies
  strictly after the accepted `200 ms` full-continuity boundary but before the `500 ms` fresh-gesture boundary.
  Captured-parameter replay caps `156.0 ms` to about `132.9 ms` and raises the unchanged `32 px` response from
  approximately `205` to `241 px/s`.
- The cadence classification and newly measured cross-direction estimate remain available to following reports;
  only this stopped visible opening is bounded. Telemetry records
  `action=cap-stopped-unestablished-reversal-opening` with prior estimate, reversal blend, and both base durations.
- A cadence estimate known before the reversal remains authoritative, preserving the accepted established `254 ms`
  case. Live overlap, the accepted `<=200 ms` close window, same-direction input, substantial/fast input, and a
  fresh `>=500 ms` reversal do not match. The more general `300–380 ms` stopped paused-reversal blend remains the
  fallback for established cadence and is excluded when this more specific unestablished action applies.

Preserved behavior: the reversal is delivered immediately and still cancels old-direction motion. Established
sparse cadence, live close reversals, first-report `80 ms` openings, measured and remembered stopped-continuation
caps, slow-to-fast raw-cadence acceleration, long-idle wake shaping, live low-unit ramp protection,
fast/settling/sharp-tail behavior, distance/rate/carry bounds, target/session resets, horizontal and zoom/effect
paths, and display recovery are unchanged. No report is delayed, confirmed, discarded, replayed, or distance-scaled.

Verification:

- `git diff --check`, `./dev.sh scroll-tests`, and `./dev.sh build` pass. Deterministic coverage replays the exact
  `209 ms`, zero-prior decision and `156.0 -> 132.9 ms` cap, plus non-matches for live motion, established cadence,
  the exact `200 ms` boundary, same-direction input, substantial/fast input, and a `500 ms` fresh reversal. Existing
  wake, low-unit acceleration, stopped measured/remembered opening, close/paused reversal, cadence-seed,
  sharp-tail, display lifecycle, and output-bound suites pass under `clang -Wall -Wextra -Werror`.
- Across the current `14:30–14:36` physical window, `62` first-output records measured `6.14–21.58 ms` total and
  `0.44–8.61 ms` queued. `118` active output windows ran at `101.3–120.5 Hz`. Browser and Readdown supplied fresh
  starts, slow-to-fast and fast-to-slow motion, both directions, live and stopped reversals, stopped slow
  continuation, fast-tail settling, target reset, and successful display `4` starts. No unexplained tap disable,
  display start/recovery failure, or retained cancelled-direction distance accompanied the affected path; bounded
  carry drops occurred only during captured very-high-speed input.
- `./dev.sh run` rebuilt and deployed the fix through the normal app lifecycle. Helper PIDs `46825` and then
  `46865` logged the expected config reset and user-input tap re-enable. The `2,000`-event recorder remains active.

Remaining verification/tradeoff: the changed action is exact-policy replayed but has not yet physically recurred on
PID `46865`; the broader cross-app, multi-display, horizontal, zoom/effect, content-boundary, rebound, and parked-
display matrix remains manual. A stopped unestablished reversal in the `200–500 ms` interval is intentionally
crisper, while an established sparse reversal or visually continuous `<=200 ms` reversal retains its accepted
cadence response.

## 2026-08-16: point-collapse fast tail must not seed a weak paused reversal

Symptom: the user reported another slow scroll start after the stopped unestablished-reversal opening fix was
deployed. The most recent start at `14:55:37.783` was healthy (`6.54 ms` to first output, then an amplified
one-unit report accelerated from `363` to `792 px/s`), so the report was correlated with the only adjacent weak
stopped opening rather than attributed to the queue or display link.

Evidence and root cause (helper PID `46865`):

- At `14:53:39.505`, a one-unit opening used the normal `80 ms` base and `400 px/s` target. Point magnitude then
  rose `1 -> 7 -> 19` at `14:53:39.559–39.626` and accelerated normally.
- At `14:53:39.805`, the physical report fell from `19` points to the one-point baseline. Modeled speed fell from
  about `552` to `179 px/s`, but its ratio of about `0.32` remained just above the existing `0.25` sharp-tail
  threshold. The report was consequently eligible to seed slow cadence despite being the terminal edge of the
  amplified ramp.
- At `14:53:40.128`, a stopped one-unit reversal after `323 ms` consumed that seed and opened at only about
  `288 px/s` instead of the normal `400 px/s`. This is the inferred correspondence to the report; the earlier
  `209 ms` unestablished-reversal action did not recur because this path incorrectly appeared established.
- First-output time was `11.10 ms`, including `0.42 ms` queued, and display-link start succeeded. No tap disable,
  stale callback, retained cancelled-direction distance, or hardware/target failure accompanied the event.

Change (`Helper/Core/Scroll/ScrollCadencePolicy.h`, `Helper/Core/Scroll/Scroll.m`,
`Tests/ScrollCadencePolicyTests.c`):

- The existing sharp-deceleration-tail classifier now also accepts captured point collapse as independent tail
  evidence: a measured, same-direction, one-unit slow report at or below the two-point baseline following a point
  magnitude above that baseline, with both point and modeled speed falling. This covers the captured `19 -> 1`,
  `179 / 552` path even though analyzer smoothing leaves the modeled-speed ratio above `0.25`.
- The current report remains fully delivered and retains its existing live tail response. Classification only
  prevents this terminal report from seeding remembered slow cadence for a later stopped continuation/reversal.
  Telemetry records point magnitudes and modeled-speed ratio with
  `action=classify-sharp-deceleration-tail`.

Preserved behavior: gradual careful deceleration, a still-amplified falling `15 -> 13` point report, unchanged
one-point sparse input, direction reversal, multi-unit or fast input, and unmeasured openings do not enter the new
branch. Genuine sparse cadence can still be established by following reports. Current-report distance, live
retargeting, slow-to-fast acceleration, fast-tail settling, reversal cancellation, long-idle wake behavior,
low-unit ramp protection, distance/rate/carry bounds, target/session resets, horizontal and zoom/effect paths, and
display recovery are unchanged. The rejected timer/quarantine/confirmation approaches remain rejected; no input
is delayed, discarded, replayed, or distance-scaled. The known short rebound/micro-reversal tradeoff is unchanged.

Verification:

- `git diff --check`, `./dev.sh scroll-tests`, and `./dev.sh build` pass. Deterministic coverage replays the exact
  `19 -> 1`, approximately `0.32` modeled-speed-ratio case and verifies it cannot seed cadence. Adjacent negative
  cases cover gradual `5 -> 4` decay, still-amplified `15 -> 13` decay, unchanged `1 -> 1`, reversal, larger input,
  and unmeasured openings. Existing cadence, wake, reversal, tail, display-lifecycle, and output-policy suites pass
  under `clang -Wall -Wextra -Werror`.
- `./dev.sh run` rebuilt and deployed the fix through the normal app lifecycle. Helper PID `54766` logged config
  reset and user-input tap re-enable. On the live path at `14:59:36.390`, the new branch physically classified
  `18 -> 1` points with modeled speed `550.8 -> 140.8 px/s` and ratio `0.256`, just outside the old cutoff, while
  delivering the report normally.
- At `14:59:38.059`, a later `85 -> 1` terminal report was classified. Its next stopped reversal at
  `14:59:39.300–39.308` logged `previousSeed=0`, used the normal `80 ms` base and `400 px/s` target, and reached its
  first output in `12.11 ms` with `4.51 ms` queued. The next `1 -> 9` report immediately accelerated the target to
  `490 px/s`. An adjacent established reversal at `14:59:37.461–37.475` also retained its normal `400 px/s`
  opening and `13.98 ms` first-output time.
- In the captured post-deploy window, `25` first-output records measured `6.13–14.25 ms` (mean `11.05 ms`), and
  `47` steady output windows at or above `100 Hz` measured `100.6–120.5 Hz` (mean `117.3 Hz`). No error, fault,
  unexplained tap disable, or display stall/timeout was present.

Remaining verification/tradeoff: the exact inferred pre-fix sequence and the new point-collapse decision are both
replayed, and the latter physically recurred with the desired subsequent restart. The broader cross-app,
multi-display, horizontal, zoom/effect, content-boundary, rebound, and parked-display matrix remains manual. A
genuine transition from an amplified one-unit ramp directly to intentional one-point sparse cadence now requires
the next report to establish that cadence; the terminal one-point report itself is still visible immediately.

### 2026-08-17 — collapsed six scattered stopped-opening caps into one invariant

Symptom: slow starts kept recurring despite a month of targeted fixes. Each prior fix closed one classification
path while a different combination slipped through, because the underlying invariant was only encoded piecemeal.

Evidence/root cause (structural): the engine carried six near-identical `cap-stopped-*` duration caps, all guarding
the same shape — a small/slow report arriving when the animator was already stopped — through different flag
combinations (measured vs remembered cadence, first-gesture vs continuation, reversal vs same-direction, sharp vs
close-reversal tail). Slow-smoothing duration inflation only exists to overlap live motion; once the animator has
stopped there is nothing left to overlap, so every such report is a fresh visible opening and must not be spread
across the maximum slow base. The scattered guards were the union of that one rule, and new report combinations
kept escaping between them.

Change:

- `ScrollCadencePolicy.h`: replace `MFScrollShouldCapStoppedCloseReversalContinuation`,
  `MFScrollShouldCapStoppedSlowContinuation`, `MFScrollShouldCapStoppedRememberedSlowOpening`,
  `MFScrollShouldCapStoppedUnestablishedReversalOpening`, `MFScrollStoppedPausedReversalOpeningCapBlend`, and the
  stopped sharp-tail cap with a single `MFScrollShouldCapStoppedSlowOpening` predicate plus
  `MFScrollStoppedSlowOpeningBaseDurationCap`. `MFScrollIsSharpDecelerationTailReport` and the cadence-seeding
  rules are unchanged.
- `Scroll.m`: compute `stableStoppedSlowOpeningForTick` once, after the adaptive blend is finalized, and apply a
  single cap to `effectiveOpeningDurationCap`. Remove the six application blocks, the close-reversal continuation
  marker, and the 300–380 ms paused-reversal blend.
- `ScrollConfig.swift`: remove the now-unused `stableStoppedPausedReversalCapBlendStartInterval` /
  `stableStoppedPausedReversalCapFullInterval`.
- `Tests/ScrollCadencePolicyTests.c`: collapse five scenario tests into one unified suite.

Preserved behavior: live overlapping sparse motion keeps full slow smoothing; the first unknown-cadence report
keeps the 80 ms bounded start; idle-wake, fast-tail/expired-tail, and the live velocity-notch guard are excluded
via `tailPolicyActive`. No report is delayed, confirmed, discarded, or replayed.

Verification: `./dev.sh scroll-tests` (ScrollCadence, DisplayLinkLifecycle, OutputPolicy all PASS),
`./dev.sh build` (BUILD SUCCEEDED, existing unrelated warnings only), and `git diff --check` passed.

Remaining tradeoff: the previously accepted 292 ms stopped paused reversal (kept full cadence under the old
300–380 ms blend) now restarts crisply at the adaptive opening envelope. This matches the ledger's own repeated
conclusion that a stopped report has no motion to preserve, and is the one intentional behavior change. The full
physical matrix (fresh start, extremely slow motion, slow-to-fast, fast-to-slow, stop/rebound, close and paused
reversals, app/window switch, multi-display, horizontal/zoom/effect paths, and a parked display) remains manual on
a live helper; the rolling recorder should be sampled for the new single `cap-stopped-slow-opening` record.

### 2026-08-21 — long-idle baseline report moved opposite the real wake ramp

Symptom: after a slow start, scrolling appeared to move briefly in the opposite direction before following the
physical ring direction.

Current telemetry before attribution (helper PID `1641`):

- At `13:11:31.270`, after `43.251 s` without physical wheel input, the TB800 path delivered a baseline positive
  report: `line=(1,0) point=(1,0)`. The helper processed it as the ordinary `32 px`, `80 ms` base opening and
  reached first output in `13.32 ms` with `3.83 ms` queued.
- At `13:11:31.520`, `253 ms` later by event timestamps, the device delivered the first negative report:
  `line=(-1,0) point=(-1,0)`. Direction cancellation retained that report, and its first output arrived in
  `10.39 ms` with `0.76 ms` queued. The real negative ramp then continued at `13:11:31.563/.600/.636` with point
  magnitudes `-8/-29/-43`.
- Display starts returned `result=0`, active output returned to approximately `120 Hz`, and there was no tap disable,
  display recovery/failure, target churn, rate limit, dropped carry, or retained old-direction animator distance.

Root cause: the opposite sign was already present in physical `MFSCROLL_INPUT` telemetry, so it was not created by
the scroll queue, animator, display link, or application. The exact device/receiver cause is inferred: after long
idle, a single baseline report can precede the amplified wake ramp and can have the opposite sign. Treating that
ambiguous baseline as a full `32 px` opening made the physical artifact clearly visible before the real direction
arrived.

Change (`Helper/Core/Config/ScrollConfig.swift`, `Helper/Core/Scroll/ScrollCadencePolicy.h`,
`Helper/Core/Scroll/Scroll.m`, `Tests/ScrollCadencePolicyTests.c`):

- Only a Regular stable-engine first analyzer report after the existing `>=20 s` idle boundary, with the exact
  one-unit/one-point baseline signature, receives the accepted stopped-settling response bounds: at most `10 px`
  and a `50 ms` base. It is still emitted immediately and never waits for the next report.
- The ambiguous baseline cannot seed remembered slow cadence. A following opposite report therefore opens crisply
  instead of inheriting direction cadence from the possible wake artifact. Amplified, multi-unit, short-idle, and
  every follow-up report retain their ordinary full distance on that same report.
- Telemetry records `MFSCROLL_ADAPTIVE action=bound-idle-wake-baseline` with idle gap and full/bounded distance.

Preserved behavior: no timer, confirmation count, quarantine, delayed replay, or second distance reservoir was
added. The first physical report remains visible; a genuine isolated baseline tick after long idle is intentionally
smaller but not discarded. The existing duration shaping for subsequent long-idle reports, unknown-cadence normal
smoothness, live velocity-preserving retargets, direction cancellation, slow-cadence continuity outside the
ambiguous baseline, settling/fast-tail protection, distance/rate/carry bounds, target resets, effect paths, and
display recovery are unchanged.

Verification:

- `./dev.sh scroll-tests` passes exact captured-signature coverage plus non-matches for short idle, amplified and
  multi-unit openings, follow-up reports, and non-stable engines. Existing cadence, display-link lifecycle, and
  output-policy suites pass under their warning-as-error builds.
- `git diff --check` and `./dev.sh build` pass (`BUILD SUCCEEDED`, existing unrelated warnings only).
- `./dev.sh run` rebuilt and deployed the Debug app/helper. Final helper PID `79302` logged the expected config reset
  and event-tap re-enable. The bounded `2,000`-event recorder was restarted before deployment and remains active.

Physical reproduction captured (helper PID `79302`, rolling snapshot `23:05–23:09`): the single long-idle start in
that capture arrived after a `128,649 ms` (≈`128 s`) idle. Its telemetry confirms the intended sequence:

- `23:09:46.431` the baseline `line=(-1,0) point=(-1,0)` report logged
  `action=bound-idle-wake-baseline idleGapMs=128649.2 fullPx=32.0 outputPx=10.0` and reached first output in
  `14.01 ms` with `0.89 ms` queued — bounded to `10 px` without being deferred or discarded.
- `23:09:46.786`, `355 ms` later, the real opposite `line=(1,0) point=(1,0)` ramp logged
  `MFSCROLL_DIRECTION action=cancel-old-session` and opened at the ordinary full `32 px` (`8.85 ms` first output,
  `0.62 ms` queued). It did not inherit the baseline's direction or cadence.
- The physical spin then accelerated normally (`point=(7,0)/(26,0)/(40,0)/(49,0)`) through
  `action=cap-idle-wake-ramp` and `cap-accelerating-low-unit-ramp`, returning to ≈`120 Hz` active output.

Across the full snapshot, first-output latency stayed `7–15 ms`, queue time `≤4.9 ms`, and there was no tap disable,
display recovery/start failure, target churn, rate limit, or dropped carry. This closes the previously pending
capture: the guard fires exactly once on the ambiguous long-idle baseline and the real ramp is unaffected.

Remaining verification/tradeoff: the broader physical matrix (horizontal, multi-display, zoom/effect paths, and a
genuinely parked display) remains manual on a live helper. Because a genuine isolated deliberate one-point tick is
indistinguishable from the captured wake baseline, it now produces `10 px` after long idle instead of the ordinary
approximately `32 px`. This bounded immediate response is preferred to either amplifying the confirmed wrong-sign
artifact or reintroducing a timer-based dead zone.

## 2026-09-01 — Ring rewrite Phase 0/1 begins with passive raw-HID observation

Symptom/evidence: the `23:16:59.565` helper PID `1800` capture above showed that the accepted long-idle baseline
classifier can select a `10 px` response for a genuine TB800 start whose `line=(1,0) point=(1,0)` signature is
indistinguishable at the CGEvent layer. Queue (`0.52 ms`), first output (`6.85 ms`), display start, target, and tap
telemetry were healthy. The same-sign continuation arrived `277 ms` later only after the first finite response had
stopped. This reconfirms that the recurring slow-start class is response-shape ambiguity, not queue or display-link
latency.

Root cause/design decision: point delta is already accelerated and the isolated line packet does not contain enough
information to distinguish a real tick from the captured receiver baseline. Instead of adding another intent
classifier, the rewrite now begins by measuring the TB800's raw Generic Desktop Wheel and Consumer Pan values before
WindowServer acceleration. Output remains on the frozen legacy engine until raw/CG pairing reliability and artifact
distinguishability are measured.

Change:

- Added `SCROLL_REWRITE_PLAN.md` plus sanitized JSONL fixtures for the same-sign long-idle false positive and its
  adjacent healthy-start comparator. Unknown fields are explicitly `null`; no missing raw data was invented.
- Added `RingHIDSource`, an independent `IOHIDManager` sidecar matched only to vendor `1149`, product `33129`. It
  opens with `kIOHIDOptionsTypeNone`, observes only Wheel `0x38` and Pan `0x0238`, handles attach/removal, and never
  suppresses or posts an event.
- Added a fixed `64`-sample buffer and pure `RingInputCorrelator`. Pairing requires the same device, axis, sign, and
  a raw timestamp no more than `30 ms` old (with only `2 ms` future-skew tolerance). Samples are consumed once,
  expired samples are reclaimed, and overwrite loss is counted. A miss returns CG line units immediately; it never
  waits for raw HID. Point magnitude remains telemetry only.
- Added versioned `MFSCROLL_RING_HID` attach/sample/detach records and one `MFSCROLL_RING_INPUT` record per handled
  TB800 CG report, including engine=`legacy`, source, raw/CG timing and magnitude agreement, target window, and
  display. The existing heavy-processing arguments and legacy output path are unchanged.

Preserved behavior: this slice does not select `ring-shadow` or `ring-live`, create a motion model, change distance,
duration, direction, carry, cadence, target routing, output phases, animator/display behavior, zoom/effects, or
synthetic event handling. When the target device is absent, the event tap does not perform sending-device lookup.
When raw data is absent or incompatible, the physical CG report proceeds immediately through the existing path.

Verification:

- `./dev.sh scroll-tests` passes the existing cadence, display lifecycle, and output-policy suites plus the new
  warning-as-error correlator suite. New coverage includes nearest-compatible selection, device/axis/sign rejection,
  one-time consumption, bounded clock skew, stale expiry, magnitude mismatch, device removal, fallback, and bounded
  overflow.
- Both checked-in JSONL fixtures parse successfully with `jq`; `plutil -lint Mouse\ Fix.xcodeproj/project.pbxproj`,
  `git diff --check`, and `./dev.sh build` pass. The full Debug app and embedded Helper build succeeded.
- Runtime launch could not complete the physical pairing gate because the machine had no active display
  (`system_profiler SPDisplaysDataType` listed the GPU but no display). The Helper aborted in the pre-existing
  `DisplayLink.m:230` startup assertion after `CVDisplayLinkCreateWithCGDisplays` received an empty display list.
  The crash stack faulted entirely in DisplayLink/TouchAnimator construction; the sidecar's IOHID manager state
  queue was alive but no scroll capture was possible. This is recorded as an environment/lifecycle blocker, not
  attributed to HID correlation. After launchd repeated the same abort, the development Helper service was booted
  out to stop the crash loop; it must be re-enabled from the GUI when an active display is present.

Remaining tradeoffs/gates: Phase 1 is not complete. On the next active-display run, capture normal slow/fast,
multi-unit, long-idle, stop/rebound, vertical, and horizontal motion; measure registry-ID and sign agreement,
pairing/fallback rates, timestamp distribution, and overflow before raw values influence output. The per-sample HID
record is intentionally verbose during observation and must be reduced or aggregated after the capture gate. The
legacy long-idle behavior and its known genuine-tick tradeoff remain active until a later evidence-backed live-engine
phase replaces them.

## 2026-09-02 — Phase 1 capture analyzer and exact TB800 mouse-collection match

Objective/evidence: Phase 1 requires measured HID/CG pairing reliability before the raw value can influence output.
The development Helper was running as PID `85986` from the expected DerivedData build, and the bounded recorder was
started successfully, but no physical scroll report arrived during three observed capture windows. The empty trace
is not evidence about pairing success or failure. Current `ioreg` state did confirm the receiver is attached and
exposes two collections with vendor `1149` and product `33129`: the intended Generic Desktop Mouse collection
contains relative Wheel `0x38` and Consumer Pan `0x0238`, while a second vendor/keyboard collection has the same
product identity and unrelated elements.

Change:

- Narrowed `RingHIDSource` device matching from VID/PID alone to VID/PID plus Generic Desktop Mouse usage. Element
  matching remains Wheel/Pan only. This prevents the receiver's second collection from incrementing attachment
  generations or making `hasAttachedTarget` true without the scroll collection.
- Added `Tests/ring_capture_analyzer.py` and `./dev.sh ring-capture-report [file]`. The analyzer reports sidecar
  lifecycle, raw/CG counts, HID pairing and fallback rates, axis/source coverage, sign and magnitude agreement,
  registry-ID sets, HID-to-CG min/p50/p95/max timing, negative skew, raw utilization, and maximum buffer overflow.
- Added deterministic analyzer tests for paired/fallback input, both axes, timestamp percentiles, sign/magnitude
  agreement, device identity, overflow, and empty-capture gate behavior. `./dev.sh scroll-tests` now runs them.

Preserved behavior: the running and built helpers remain `engine=legacy`; this work changes neither event handling
latency nor scroll output. The analyzer is offline. The source match only removes an unrelated receiver collection
which cannot emit the matched Wheel/Pan elements. The newly built collection filter was not force-deployed into the
currently stable headless Helper process because restarting with no enumerated active display previously triggered
the existing DisplayLink startup assertion.

Verification: `./dev.sh scroll-tests` passes all four C suites plus two analyzer tests; Python syntax compilation
passes with a sandbox-local bytecode cache; `git diff --check`, Xcode project validation, and `./dev.sh build` pass.
The recorder service remains active and bounded at `/tmp/mac-trackball-fix-scroll.log`. At the time of this entry its
snapshot contains zero events, so Phase 1 is deliberately not marked complete.

Remaining gate: physically exercise slow/fast/reversal/stop and horizontal motion, then include long-idle genuine
and artifact starts. Refresh the snapshot and run `./dev.sh ring-capture-report`. Pairing distribution, fallback,
registry/sign agreement, packet aggregation, and artifact distinguishability must be reviewed before Phase 2.

## 2026-09-02 — Phase 1 closes; raw baseline origin and TB800 axis polarity captured

Symptom/evidence: the first physical exercise produced 374 ordinary `MFSCROLL_INPUT` reports (295 multi-unit,
both directions) with healthy `6.54–14.37 ms` first-output latency, but zero `MFSCROLL_RING_HID` samples. That
helper predated the exact Generic Desktop Mouse collection deployment, so the absence isolated acquisition without
implicating the scroll queue, animator, display link, target application, or hardware output path. After deploying
the exact VID `1149` / PID `33129` / Mouse collection match, helper PID `6960` attached registry ID `4294971676`
non-seizing and captured Wheel and Consumer Pan values. Those records exposed axis-specific protocol polarity:
vertical raw `-1` corresponded to positive CG line input, while horizontal raw and CG signs already agreed.

The final corrected helper PID `7908` captured 240 raw reports and 240 handled CG reports: 204 vertical, 36
horizontal, 100% HID pairing, both directions, matching registry-ID sets, zero sign mismatches, zero fallbacks, and
zero buffer overflow. Only 24.2% of paired raw magnitudes equaled CG line magnitude because the HID stream delivered
one physical count per callback while WindowServer aggregated/accelerated corresponding CG line reports as high as
eight or nine units. HID and CG timestamps were identical at the available Mach timestamp resolution. Legacy output
remained healthy at `6.14–14.34 ms` first-output latency.

The same capture reproduced the long-idle opposite-baseline case. At `12:20:37.817`, after `21,025.2 ms` idle, the
receiver emitted Wheel `rawUnits=1`, normalized units `-1`, report ID `1`; CG reported `line=(-1,0) point=(-1,0)`.
Only `28.017 ms` later, Wheel `rawUnits=-1`, normalized units `1`, report ID `1` began the real opposite ramp while
CG had already amplified it to `line=(3,0) point=(34,0)`. The first report therefore originates before WindowServer
and has no report-ID, element, magnitude, or companion-field discriminator from a genuine isolated count at arrival.
The later ramp cannot be used without reintroducing the rejected timer/confirmation dead zone.

Root cause: the initial raw-acquisition gap was an undeployed collection matcher, not runtime scroll latency. Once
attached, vertical correlation failed because the TB800 Generic Desktop Wheel element uses the inverse polarity from
CGEvent; Consumer Pan does not. The recurring long-idle wrong-sign baseline is confirmed receiver/HID input, while
its mechanical cause remains unknown. It is causally indistinguishable on its first packet, so the rewrite must use
the same bounded immediate low-speed response for both artifact and deliberate one-count starts.

Change:

- Normalize TB800 Wheel units into CGEvent direction convention before buffering; preserve both `rawUnits` and
  canonical `units` in telemetry. Pan remains unchanged. The rule is exact-device and exact-axis scoped.
- Extend the capture analyzer with ordinary-input and latency evidence, explicit raw-acquisition-gap diagnosis, and
  latest-helper-session selection so rolling captures cannot mix sequence numbers across restarts.
- Sanitize the captured raw opposite-baseline/ramp into
  `Tests/ScrollTraces/2026-09-02-raw-long-idle-opposite-baseline.jsonl`.
- Begin Phase 2 with a pure `RingMotionModel`: explicit physical/output units, current-report acceleration,
  immediate second-report sparse cadence, additive same-direction impulses, atomic reversal, analytic exponential
  frame integration, generation reset, and separate initial-distance, velocity, and remaining-area caps. Add a
  deterministic JSONL runner plus unit, randomized boundedness, packetization, fixed/variable-refresh, reset, stale
  generation, invalid-time, and parked-frame tests. The model is not wired to runtime output.

Preserved behavior: `engine=legacy` remains the only output authority. Raw lookup never waits; a correlation miss
still returns the CG line fallback immediately. No timer, confirmation count, direction vote, quarantine, delayed
replay, new target routing, output phase, display-link behavior, or legacy response policy was added or changed.

Verification: `./dev.sh scroll-tests` passes all legacy policy suites, correlator tests, pure motion tests, all JSONL
replays, and four capture-analyzer tests under warning-as-error C builds. `./dev.sh run` built and deployed the helper
successfully (existing unrelated warnings only). The exact sidecar logged `action=start result=0` and `action=attach`
for registry ID `4294971676`; the physical matrix above then produced the 240/240 accepted session. `git diff
--check` and Xcode project property-list validation pass.

Remaining tradeoffs/gates: Phase 1 is complete, but Phase 2 is not. More sanitized captured fixtures are still needed
for sparse slow motion, active/paused reversal, hard stop/rebound, target/config/display reset, and horizontal motion.
The Phase 2 constants establish bounded model behavior rather than accepted feel; replay and physical A/B tuning must
precede shadow/live selection. Because the raw long-idle baseline is indistinguishable at arrival, no sanitizer is
justified; consistent calibrated low-speed response must replace the legacy idle-dependent 10 px classifier when the
new engine eventually becomes live.

## 2026-09-02 — Phase 2 closes; Phase 3 shadow renderer begins without output authority

Symptom/evidence: Phase 1 established that the recurring long-idle opposite one-count report is real raw TB800 HID
input and indistinguishable from a deliberate count at arrival. The retained helper PID `7908` capture also contains
sparse reports, active and paused reversals, a rebound-shaped real resume, horizontal Pan, and target changes. Queue
and first-output measurements remained healthy, so no evidence attributes the perceived slow start to the event
queue, animator callback admission, display link, target application, or device attachment.

Root cause: the remaining work is architectural rather than another legacy classifier fix. Captured ambiguous inputs
cannot be separated causally, while the per-report legacy animation has accumulated idle, cadence, settling, and tail
policies that interact through retained distance. A bounded continuous velocity model can give indistinguishable
inputs the same immediate response and make cancellation, remaining area, and reset ownership explicit.

Change:

- Expanded the sanitized replay suite with raw sparse-slow, active-reversal, paused-reversal,
  rebound-shaped-resume, horizontal-Pan, and target-reset fixtures from the current capture.
- Added explicit mapping from current UI/config values into physical/output units in `RingMotionModel`, and made the
  replay runner assert first-frame sign, atomic reversal, reset clearing, and maximum remaining area in addition to
  deterministic total output.
- Routed eligible TB800 Regular custom-acceleration reports through a Phase 3 `ring-shadow` diagnostics queue. The
  scroll queue publishes immutable report/config/display snapshots and monotonically generated resets; the shadow
  queue solely owns its motion state and analytic between-report integration.
- Added versioned `MFSCROLL_RING_MODEL` and `MFSCROLL_RING_COMPARE` records for source, queue time, speed/filter,
  cadence, decay, impulse/carry, first-frame prediction, velocity envelope, predicted signed total/stop time,
  immediate reversal timing, maximum remaining area, and reset summaries.

Preserved behavior: legacy `TouchAnimator` output remains the only authority. The shadow code has no event-posting
or animator call, does not mutate a legacy input/config/result, does not wait for raw HID, and runs after current
target/config/modifier/direction resolution but before legacy artifact classifiers. System acceleration and effect
paths remain legacy-only. Target, click, modifier, config, and axis transitions clear shadow state by generation; no
timer, confirmation gate, direction vote, artifact sanitizer, delayed replay, output phase, or display recovery rule
was added.

Verification: `./dev.sh scroll-tests` passes the cadence, display-link lifecycle, output policy, raw correlator,
motion-model unit/property/refresh tests, all JSONL traces, and capture-analyzer tests. Replayed reversals replace the
old sign on their first opposite input, every replayable input predicts a same-sign nonzero 120 Hz first frame,
target resets retain zero state, and all traces stay below the configured remaining-area cap. `./dev.sh build`
succeeds and `git diff --check` is clean.

Remaining tradeoffs/gates: Phase 2 is complete, but Phase 3 is not accepted from automated evidence alone. The
deployed shadow build still needs extended physical use across fresh/sparse/fast/stop/rebound/reversal/idle/target,
each display, horizontal, and compatibility/effect cases. Its predictions must be compared with the simultaneous
legacy records before parameters change or `ring-live` is enabled. The historical ordinary healthy-start fixture
lacks physical unit values and therefore remains a legacy latency comparator rather than a model replay.

## 2026-09-02 — First Phase 3 capture finds a raw-unit tuning-domain error

Symptom/evidence: helper PID `41944` filled the retained 2,000-event shadow window. It contains 266 raw reports and
266 CG inputs with 100% HID pairing, 254 vertical and 12 horizontal, both directions, no fallback, no sign mismatch,
and no overflow. The ring model accepted 206 eligible Regular reports from sequence `176` through `442`, including
18 immediate reversals, with no rejected timestamp/generation, velocity limit, or carry drop. The other consecutive
inputs were exercised under Rotate/Zoom effects and correctly stayed on the legacy path. Model queue time averaged
`1.047 ms` and peaked at `6.142 ms`. Legacy first output was `5.94–16.18 ms` on retained Regular cases; the sole
`27.32 ms` outlier was the Chromium zoom opening impulse. All 59 display-link starts on captured display `3`
succeeded, with no tap disable or display recovery.

The first mapping was not ready for live output. Across 200 aligned Regular reports, legacy requested distance was
`1.01x` the shadow impulse for slow reports below 50 px, but `7.87x` for fast reports at or above 150 px. Legacy's
line-derived reported speed averaged `3.86x` raw HID report-rate speed and ranged up to `9x`; this is the exact domain
difference visible in paired records where raw HID remained one count while CG line magnitude rose to nine. The
shadow did preserve all structural bounds: predicted first frames were nonzero and same-sign, 18 reversals replaced
old velocity on their first input, and maximum remaining area was `185.19 px` under the then-`630 px` cap.

Root cause: Phase 2 copied the legacy `50 line-units/s` reference pivot and `gamma=1.2` UI mapping into a raw HID
model. Those legacy units already contain WindowServer magnitude amplification; raw input instead presents signed
one-count impulses and carries free-spin speed mainly in their interval. The low-speed coincidence hid the mismatch,
but the candidate would have made fast live scrolling several times too slow. This is model parameterization, not
queue delay, display-link liveness, target leakage, or a missing input classifier.

Change:

- Recalibrate the candidate raw domain around `5 reports/s` careful motion and `50 reports/s` sustained free-spin
  delivery. Default sensitivity now anchors 20 base pixels/count at the slow pivot and default acceleration maps to
  `gamma=2.0`; the separate 50 reports/s output/carry calibration preserves bounded high-speed ceilings.
- Keep the observed slow response near its already-matching value while restoring a candidate fast envelope near
  the current accepted behavior. Replay fast traces now reach, but cannot exceed, the explicit `525 px` remaining
  area cap.
- Correct `dtMs` telemetry so reversal reports retain their measured interval instead of displaying `-1`, and split
  comparison totals into session-net integrated/predicted output, current-direction integrated/predicted output,
  and signed remaining area. This prevents a valid cumulative opposite-sign history from looking like reversal lag.

Preserved behavior: the recalibrated model remains `ring-shadow`; legacy output is still the only authority. No
posted delta, target routing, display link, animator curve, effect lifecycle, raw correlation, session reset, or
legacy classifier changed. The evidence does not justify a new timer, confirmation gate, rebound classifier, or
CG-point/line fallback inside the raw model.

Verification: after recalibration, `./dev.sh scroll-tests` passes all policy, correlator, model/property/refresh,
JSONL replay, and capture-analyzer suites. All replay responses remain finite, every first frame is nonzero and
same-sign, reversals remain atomic, resets clear state, and fast fixtures clamp at or below `525 px`. `./dev.sh build`
succeeds and `git diff --check` is clean.

Remaining tradeoffs/gates: Phase 3 remains open. The recalibrated build needs a second physical shadow capture before
any live gate. Only display `3` and the Browser/trackball-mode exercise are present in this retained window; other
attached displays and Safari, Telegram, Finder, VS Code/Xcode compatibility are not evidenced. Reaching the carry cap
in deterministic fast traces is intentional boundedness but must be inspected for repeated clipping and subjective
fast-spin feel in the next shadow comparison.

## 2026-09-02 — Second Phase 3 capture separates fast speed from bounded tail area

Symptom/evidence: the recalibrated helper PID `47254` retained 297/297 paired raw/CG reports with no fallback, sign
mismatch, or overflow: 260 vertical, 37 horizontal, both directions. The shadow accepted 278 eligible Regular
updates, including 15 atomic reversals. Queue time averaged `0.952 ms` and peaked at `6.459 ms`; legacy first output
was `5.63–16.65 ms` with `10.41 ms` average. No model reject, tap disable, display start failure, or recovery occurred.

Raw-distance calibration improved as intended: across 275 aligned reports, legacy requested distance averaged
`0.82x` the shadow impulse for slow reports and `1.72x` for fast reports, versus the first run's `1.01x` and `7.87x`.
However, 129/278 model updates hit the user-configured `582.195 px` remaining-area limit and discarded a total
`25,931.99 px` of requested carry. Every report at 60 or more raw reports/s clipped. Shadow velocity therefore
plateaued near `8,213 px/s`, while retained legacy output windows reached `15,732 px/s`. Raising the remaining-area
cap would restore speed only by creating a much longer post-stop tail, violating the rewrite's latency budget.

Root cause: with normal decay near `70.9 ms`, remaining area divided by decay formed an unintended effective speed
ceiling near `8.2k px/s`, well below the separate configured maximum velocity. Acceleration was no longer the main
problem; lowering it would undo the now-correct raw distance curve. The model needed speed-dependent friction so a
free spin could reach its speed ceiling without storing more future distance.

Change:

- Add explicit fast-decay start/full-speed parameters. Above 20 raw reports/s, decay smoothly shortens from the
  normal value toward `remainingAreaLimit / maximumOutputVelocity`, which is 35 ms for the current mapping and
  reaches full strength at 50 reports/s.
- Preserve signed retained area exactly whenever decay changes by converting the old velocity/tau representation
  into the new tau before adding the current impulse. Expose this converted `carriedVelocity` in model telemetry.
  This avoids silently creating or deleting distance as friction adapts.
- Keep initial and sparse response unchanged. The fast ring's physical reports supply continued motion; extra
  software tail is neither required nor permitted to raise top speed.

Preserved behavior: this remains diagnostics-only `ring-shadow`; legacy is the only event producer. The tail-area
limit is not raised, every cap remains independent, reversals still discard old-sign area atomically, and no legacy
animation, classifier, effect, target, display, or output behavior changed.

Verification: `./dev.sh scroll-tests` passes after adding adaptive fast decay and area-preserving tau conversion.
The packetization-independence test initially caught the missing area conversion; after correcting it, linear
aggregated and split reports again integrate identically. All captured replays remain bounded at or below the
configured area limit, reversal/reset/refresh invariants pass, capture analysis passes, and `git diff --check` is
clean.

Remaining tradeoffs/gates: Phase 3 remains open for a third physical capture. The next evidence must show that the
velocity envelope rises without extending stop area, that clipping represents deliberate maximum-speed saturation
rather than ordinary mid-speed loss, and that first-frame output remains acceptable. Only display `3` is captured;
multi-display and wider application compatibility remain unproven.

## 2026-09-02 — Third Phase 3 capture reaches explicit fast limits and exposes a sparse integer-output edge

Symptom/evidence: helper PID `4477` retained 270/270 paired raw/CG reports with no fallback, sign mismatch, or
overflow. The window contains 271 shadow updates because its first input record rolled out one line earlier, 16
reversals, and three app/window target resets. Queue time averaged `1.005 ms` and peaked at `5.940 ms`; 39 legacy
starts produced first output in `5.49–14.61 ms`. Every display start on display `3` succeeded and there was no tap
disable, display recovery, model rejection, or carry drop.

Adaptive fast friction achieved its intended separation. Maximum remaining area stayed exactly at the configured
`582.195 px`, carry drops fell from 129 to zero, and 39 reports saturated through the explicit velocity limit instead.
Peak shadow velocity reached the current Maximum Speed setting's `27,846.95 px/s`; tau shortened as raw speed rose,
from ordinary/sparse values down to `20.907 ms` at the ceiling. All 16 reversals retained their measured
`98.004–478.979 ms` intervals, discarded the old sign on the same update, and emitted no wrong-sign model velocity.

One retained slow sequence exposed a distinct response edge. Sequence `354` arrived one count after a `928.038 ms`
gap. Its honest raw-speed acceleration distance was `8.713 px`, but sparse overlap selected `217.434 ms` tau, so the
120 Hz first-frame prediction was only `0.334 px` and two callbacks accumulated `0.655 px`. The current integer sink
could therefore wait roughly three callbacks even though the physical report reached the model immediately. Across
the capture, eight of 271 updates shared this two-fast-callback visibility problem.

Root cause: the fast path was now correctly bounded, but sparse cadence and very-low-speed acceleration were allowed
to combine without an explicit integer-output responsiveness constraint. Total distance was finite and intentional;
only its temporal distribution could remain subpixel beyond the plan's one-or-two-callback gate.

Change:

- Add an explicit visibility window of two 144 Hz callbacks and a one-pixel minimum. If a nonzero impulse has enough
  total area but its selected tau would emit less than one pixel inside that window, shorten tau analytically just
  enough to cross the threshold. Do not add distance or alter acceleration.
- Expose `responsivenessDecayLimited` per model update. On the retained capture the rule would affect only eight
  sparse updates, changing their average tau from `219.2 ms` to `154.5 ms`; fast and ordinary responses are unchanged.
- Add a deterministic test reproducing the 928 ms sparse case and assert at least one pixel of analytic output in two
  144 Hz callbacks.

Preserved behavior: legacy remains authoritative and unchanged. The bound creates no timer, held report, synthetic
confirmation, delayed replay, extra distance, carry reservoir, or artifact classification. Fast velocity/area caps,
atomic reversal, raw correlation, routing, effects, and display lifecycle remain unchanged.

Verification: `./dev.sh scroll-tests` passes all legacy policy, correlator, model/property, packetization, fixed and
variable refresh, replay, and capture-analyzer suites. The new two-callback visibility test passes; all prior bounds
and sign/reset invariants remain green. `./dev.sh build` succeeds and `git diff --check` is clean.

Remaining tradeoffs/gates: a short physical shadow confirmation of sparse single-count input remains before Phase 3
can close. Horizontal evidence exists in the prior two captures but not this third window. All three captures used
display `3`; no evidence shows another display is attached, so multi-display validation remains a Phase 4 live gate
if additional hardware is available.

## 2026-09-02 — Final sparse confirmation closes Phase 3 shadow mode

Symptom/evidence: helper PID `7071` captured the requested deliberate single-count sequence. It paired 41/41 CG
inputs from 44 retained raw samples with no fallback, sign mismatch, or overflow. The model accepted all 41 reports;
15 selected `responsivenessDecayLimited=1`. Recomputing every accepted response at the plan's fastest tested schedule
found minimum cumulative output of `1.000461 px` within two 144 Hz callbacks, with zero reports below one pixel.
Three reversals remained same-update and same-sign, maximum retained area was `227.731 px`, and there were no carry
drops, velocity-cap events, stale/invalid rejects, display failures, or recovery records.

Queue time averaged `1.225 ms`. One report queued `7.972 ms` and produced the sole `20.28 ms` legacy first-output
sample; the other 35 latency records and `10.43 ms` overall mean show no repeated long-tail class. The outlier occurred
on sequence `2` immediately after helper launch while the routed target was the Mac Mouse Fix app. It did not coincide
with a tap disable, failed display start, raw fallback, model reject, target leak, or later slow-response failure.

Root cause: the prior captured subpixel delay was fully explained by sparse tau distributing a small honest raw-speed
impulse below the integer sink's threshold. The analytic response-time cap addresses that representation boundary;
there is no evidence for an idle artifact classifier, report confirmation, queue workaround, or display recovery.

Change: no further model change was needed after the two-callback response bound. Mark Phase 3 complete in the rewrite
plan and retain `legacy` as the only live output authority. Phase 4 is authorized only to add a development-gated
vertical renderer with an immediate legacy fallback; it must not switch the default.

Preserved behavior: all application-visible scrolling in these four shadow passes came from the legacy engine. Raw
observation remained non-seizing and immediate, effects remained legacy-only, resets stayed generation ordered, and
the shadow never posted or modified an event.

Verification: final physical telemetry proves the response bound on real 0.3–1 second single-count intervals.
`./dev.sh scroll-tests`, the full Xcode build, and `git diff --check` passed on the deployed candidate. Across the
preceding shadow captures, raw/CG pairing, active/paused reversal, fast saturation, hard-stop area, target resets,
horizontal input, Rotate/Zoom exclusion, and legacy first-output health were also observed without a new unexplained
failure class.

Remaining tradeoffs/gates: only display `3` appeared in every capture; if another display is attached later, Phase 4
must test it before live acceptance. Safari, Telegram, Finder, VS Code/Xcode, and the full effect matrix remain Phase
4/5 compatibility gates. The raw model intentionally gives a genuinely near-1-report/s count less total distance
than legacy's isolated 32 px floor, but makes it visible immediately; subjective A/B testing must decide UI tuning,
not another hidden-state classifier.

## 2026-09-02 — Phase 4 vertical live renderer is gated for physical A/B

Symptom/evidence: four Phase 3 captures established healthy raw/CG pairing, normal queue delivery, atomic model
reversal, explicit fast saturation, bounded remaining area, and two-callback sparse visibility. They also showed no
evidence for another wake/tail classifier. The remaining gap was architectural: `ring-shadow` could predict motion
but had no display-paced integer output owner, liveness supervision, or mutually exclusive handoff from the legacy
animator. This change does not attribute any perceived delay to the queue, display link, target application, or
hardware beyond the raw baseline behavior already captured above.

Root cause/design decision: using an independent second display link would permit old legacy callbacks and new live
callbacks to overlap during vertical/horizontal or effect transitions. Phase 4 instead shares the existing
`TouchAnimator` `DisplayLink` and its serial queue. Ordered cancellation/reset, display rebinding, callback
replacement, and legacy restart now establish exactly one output authority. The pure leaky-impulse model remains the
only new motion state; no finite target curve or legacy intent classifier was copied into it.

Change (`Helper/Core/Scroll/RingScrollRenderer.h/.m`, `Helper/Core/Scroll/Scroll.m`, `dev.sh`, capture analyzer and
tests, Xcode project, rewrite plan):

- Added a renderer which owns model/subpixel state on the shared display-link queue, analytically integrates actual
  frame intervals, emits phase-less vertical pixel-wheel output through the existing sink, stops when no visible
  integer output remains, and aggregates frame cadence/output telemetry.
- Reset publishes its generation before queue delivery so an already-admitted old callback cannot post after a
  target/config/modifier/click reset. Reversal clears old-sign velocity and subpixel error on the same report.
- Retained the hardened 110 ms cold-start watchdog contract with three restarts and a true stopped abort. New input
  invalidates a requested-running stalled link, discards its old tail, and processes the current report as a fresh
  model opening. A callback resuming after a greater-than-100 ms parked interval discards the old remaining area
  instead of posting it as one secondary burst.
- Added a startup-immutable, Debug-only `legacy|ring-shadow|ring-live` selector. Legacy is the default and the forced
  Release behavior. Live eligibility is exact TB800, vertical, Regular/Low Inertia custom acceleration, and no effect;
  all nonmatches reset live state and enter legacy immediately.
- Extended capture reporting with selected engine, live first-output/queue distributions, model rejects/reversals/
  limits/carry, frame cadence/gaps, parked/stall discards, and display/tap lifecycle counts. Added the exact A/B and
  rollback procedure to the rewrite plan. The independent HID sidecar now identifies itself as a non-authoritative
  observer instead of hard-coding `output=legacy`, which would be false while the gated live renderer is selected.

Preserved behavior: raw HID correlation never waits and CG-line fallback remains immediate. Horizontal, other-device,
Apple-acceleration, non-Regular, zoom, rotate, and all other effect paths remain legacy. Continuous events retain the
existing synthetic marker, HID-tap posting, line/fixed-field pixelation, and unset phase/momentum fields. The selector
does not change at runtime, Release cannot select live, discarded area is not stored or replayed, and no timer,
confirmation count, direction vote, artifact sanitizer, or second distance reservoir was added.

Verification: `plutil -lint Mouse\ Fix.xcodeproj/project.pbxproj`, `git diff --check`, and `./dev.sh scroll-tests`
pass, including all legacy cadence/display/output policy suites, raw correlator tests, motion model properties,
60/120/144/variable-refresh schedules, captured JSONL replays, and five capture-analyzer tests. The full Debug app and
embedded Helper build succeeds. The first sandboxed build attempt could not write Xcode/Swift caches; the same build
run with normal cache access completed with `BUILD SUCCEEDED`, so that environmental failure is not attributed to the
renderer.

Remaining gate/tradeoff: no `ring-live` physical event has been posted by this implementation yet. Phase 4 therefore
remains open for the documented legacy/live A/B, full vertical regression matrix, every attached display, and a
telemetry-confirmed rollback. A display gap above 100 ms intentionally discards bounded old motion rather than
bursting it on resume; the next physical report remains independently cold-startable. Subjective testing must still
decide whether the calibrated raw one-count distance and sparse overlap feel correct before any default change.

## 2026-09-02 — Phase 4 legacy baseline passes and ring-live A/B begins

Symptom/evidence: the completed legacy half of the Phase 4 physical A/B was captured from helper PID `50471` and
preserved at `/tmp/mac-trackball-fix-scroll-phase4-legacy.log`. Its retained window contains 390 vertical CG reports
and 390 successful raw-HID correlations, both directions, 308 multi-unit CG reports, and Browser/kitty target
transitions. There were zero fallbacks, sign mismatches, buffer overflows, tap disables, display recoveries, or
display-start failures. Queue time was `0.38–4.34 ms` (`0.98 ms` mean), and first output was `5.86–14.38 ms`.
All 54 display starts on the only observed display, display `3`, returned success. This evidence does not attribute
perceived response shape to the queue, display link, target application, or raw acquisition.

Change/progression: no scroll policy or model constant changed. The baseline snapshot was frozen before changing the
startup-immutable selector. `./dev.sh ring-engine ring-live` followed by `./dev.sh run` built successfully and
deployed the Debug candidate. The final helper PID `54090` logged at `22:31:04.201`
`requested=ring-live selected=ring-live debugBuild=1 legacyFallback=1 verticalOnly=1`; the sidecar started
non-seizing, the TB800 attached as registry ID `4294971676`, and generation-ordered model/session resets completed.

Preserved behavior: the legacy capture is unchanged and remains available for direct comparison. The live selector
still affects only exact-TB800 vertical Regular/Low Inertia custom acceleration with no effect; all other paths keep
their immediate legacy fallback. Release defaults, raw correlation, routing, synthetic marking, and output fields
remain unchanged.

Verification: `./dev.sh ring-capture-report /tmp/mac-trackball-fix-scroll-phase4-legacy.log` reported the accepted
pairing/lifecycle/latency evidence above. `./dev.sh run` completed with `BUILD SUCCEEDED`, and the rolling recorder
captured the final live startup and attachment records. The live physical matrix has not yet been exercised, so this
entry advances the A/B handoff but does not close Phase 4.

Remaining gate/tradeoff: repeat the identical vertical matrix under PID `54090`, inspect live model/frame/latency
telemetry and subjective feel against the preserved baseline, then restart in `legacy` and verify the rollback
selection. Only display `3` has been observed; every additional attached display remains required if available.

## 2026-09-02 — Phase 4 live A/B and rollback pass

Symptom/evidence: the `ring-live` candidate physical pass from helper PID `54090` was preserved at
`/tmp/mac-trackball-fix-scroll-phase4-ring-live.log`. Its retained window contains 301 raw reports and 301 CG
reports with 100% correlation: 275 vertical, 26 horizontal, both directions, zero fallback, zero sign mismatch, and
zero overflow. Browser, kitty, and Safari targets were present, along with explicit target resets and three complete
Chromium zoom sessions. The user completed the requested physical matrix without reporting a subjective failure.

Candidate behavior:

- All 301 physical inputs are accounted for by 240 eligible `ring-live` model updates and 61 legacy-path model
  reports. Horizontal and effect paths reset the live generation and used legacy; there is no evidence of concurrent
  output authority.
- Ten direction changes cleared carried velocity to zero and established the current report's sign on the same
  model update. There were no stale/invalid rejects and no carry drops. Twenty-four fast reports reached the explicit
  velocity limit, while maximum remaining area stayed at the configured `582.195 px` bound.
- Live first-output latency was `0.59–20.65 ms` (`4.82 ms` median, `11.87 ms` p95, `5.30 ms` mean) and queue time
  was `0.34–7.52 ms` (`1.04 ms` mean). The sole `20.65 ms` maximum was sequence `589`, a one-count sparse report
  whose `responsivenessDecayLimited=1` response crossed the integer sink after display-paced subpixel integration;
  its queue time was only `1.26 ms`, display start succeeded, and adjacent callbacks remained at `8.333 ms`.
- Across 103 frame summaries, the renderer processed 3,040 callbacks and posted 2,201 nonzero events at exactly
  `120 Hz`, with maximum callback gap `8.333 ms`. There were no parked-frame or stalled-start discards, display
  recoveries, start failures, or tap disables.

Comparison/root-cause conclusion: the frozen legacy baseline had `10.33 ms` median / `14.07 ms` p95 first-output
latency and `0.98 ms` mean queue time. The live candidate reduced typical first-output latency without moving work
into the event queue. Its one larger sparse maximum was bounded integer visibility, not a queue, display-link,
target, or HID-acquisition stall. No new classifier, timer, confirmation gate, delayed replay, or retained-distance
failure is justified by this capture.

Change/progression: no model parameter or output policy changed after the live evidence. The startup selector record
had rolled out of the bounded candidate file, but the pre-pass snapshot and preceding ledger entry independently
recorded PID `54090` selecting `ring-live`, and every retained model/frame record identifies `engine=ring-live` with
`legacyAuthoritative=0`. After preserving the candidate, `./dev.sh ring-engine legacy` and `./dev.sh run` rebuilt and
restarted the helper. Final helper PID `56505` logged at `22:39:23.159`
`requested=legacy selected=legacy debugBuild=1 legacyFallback=1 verticalOnly=1`, completing the rollback gate.

Preserved behavior: the installed Debug helper is back on legacy. The live engine remains opt-in, exact-TB800,
vertical, Regular/Low Inertia, and no-effect only; Release still forces legacy. Horizontal, zoom/effect, raw fallback,
target resets, synthetic output fields, and shared display-link lifecycle remain unchanged.

Verification: `./dev.sh ring-capture-report` was run on both preserved captures; targeted input/model/frame/latency/
target/zoom/display/tap correlation supplied the evidence above. `./dev.sh scroll-tests` passes the cadence,
display-lifecycle, output-policy, correlator, motion-model, captured replay, and five analyzer suites. Both candidate
deployment and rollback builds completed with `BUILD SUCCEEDED`; `git diff --check` passes.

Remaining tradeoff: only runtime display `3` was observable, and `system_profiler SPDisplaysDataType` did not
enumerate another attached display at closure. Phase 4 is complete for the available hardware, but a later attached
physical display still requires a fixed-pointer pass. Wider Safari/Chromium/Telegram/Finder/VS Code/Xcode and
horizontal/effect compatibility remain Phase 5 gates. The one-count raw model intentionally favors immediate bounded
visibility over legacy's larger idle-dependent opening, and the user-facing default remains unchanged.

## 2026-09-03 — Phase 5 raw Pan renderer and compatibility routing begin

Symptom/evidence: before changing output authority, the rolling capture on legacy helper PID `56505` contained
303/303 paired vertical TB800 reports, both directions, zero fallback, sign mismatch, or overflow. First output was
`5.58–21.00 ms` (`11.51 ms` median, `14.80 ms` p95); no display-start failure, recovery, or tap disable appeared.
This current capture does not contain horizontal input and therefore is not evidence for horizontal feel, but it
rules out a new general queue/display/tap regression. Phase 4's preserved live capture already contained 26 paired
horizontal reports which intentionally fell back to legacy, while the earlier raw Pan capture established that
Consumer Pan polarity agrees with CGEvent and the deterministic horizontal replay passes both directions and
reversal.

Root cause/design decision: Phase 4 deliberately hard-coded live eligibility and renderer telemetry to vertical.
Simply admitting Pan while retaining one unlabelled scalar state could post vertical velocity or biased subpixel
error through horizontal event fields during an axis transition. Maintaining two simultaneously coasting models
would instead create two output authorities and ambiguous cancellation. Phase 5 treats axis as scroll-session
identity: an axis change publishes a new generation and clears the old scalar motion before processing the current
report, while both axes reuse the same bounded model, display link, and compatibility sink.

Change (`Helper/Core/Scroll/RingScrollRenderer.h/.m`, `Helper/Core/Scroll/Scroll.m`, `dev.sh`, capture analyzer,
tests, and rewrite plan):

- The exact TB800 Regular custom-acceleration live gate now accepts vertical Wheel and horizontal Consumer Pan.
  Canonical positive output maps to up/right and negative output to down/left through the existing phase-less
  two-axis pixel-wheel event constructor, preserving its line/point/fixed fields and HID-tap routing.
- Renderer reports and callbacks carry an explicit axis. Vertical <-> horizontal transitions reset generation,
  velocity, pending latency, and the biased subpixel accumulator before the same report opens the new axis. A
  mismatched axis without a reset is rejected defensively instead of leaking old-axis state.
- Added `MFSCROLL_RING_ROUTE` for each exact-device live decision. It records live ownership or immediate legacy
  fallback with reason `effect`, `system-acceleration`, `non-regular`, or a validation failure. Analyzer schema v3
  now reports route/model/frame counts and first-output/queue distributions by axis, fallback-reason counts,
  observed horizontal live output, and the System/non-Regular/effect fallback coverage gate.
- The Debug selector message/startup record now advertises `horizontalPan=1`; Release behavior and the restart-only
  rollback selector remain unchanged.

Preserved behavior: raw correlation never waits and CG-line fallback remains usable. A report is never held,
confirmed, replayed, or discarded to infer axis intent. Same-axis acceleration, sparse overlap, atomic reversal,
velocity/area/initial-distance caps, parked-frame discard, watchdog recovery, target/config/click reset, and
phase-less ordinary output are unchanged. Effects—including zoom and its terminal lifecycle—System acceleration,
non-Regular curves, other devices, and invalid live inputs still enter the legacy `TouchAnimator` path on the same
report. No second display link, second motion reservoir, or simultaneous axis coast was introduced.

Verification: `./dev.sh scroll-tests` passes the full cadence, display lifecycle, output policy, correlator, motion
model/property/refresh, captured replay, and six analyzer tests, including the captured horizontal Pan replay and
new vertical/horizontal live-route plus fallback-reason accounting. `plutil -lint` on the Xcode project,
`bash -n dev.sh`, `git diff --check`, and the full Debug build pass. The first sandboxed build was denied access to
existing Swift/Xcode cache directories; the normal-cache build then completed with `BUILD SUCCEEDED`, so that
environmental error is not attributed to the code. The final instrumented candidate was deployed through
`./dev.sh run`; helper PID `66968` selected `ring-live` at `19:39:00.589`, started the non-seizing HID observer,
attached registry ID
`4294971676`, reset configuration, and re-enabled its event tap.

Remaining gate/tradeoff: implementation is complete but Phase 5 is not physically accepted. PID `66968` must cover
native horizontal slow/fast/stop/reversal, active vertical/horizontal handoffs, Safari/Chromium boundaries,
Telegram, Finder, VS Code/Xcode, System and non-Regular fallbacks, zoom/rotate/other effects with terminal phases,
target changes, and every available display. A vertical/horizontal transition intentionally discards the bounded
old-axis tail rather than allowing diagonal synthetic coasting; the new-axis physical report is delivered
immediately. The installed candidate is development-gated and rollback remains `./dev.sh ring-engine legacy`
followed by `./dev.sh run`.

## 2026-09-04 — independent Wheel/Pan overlap repeatedly reset the live renderer

Symptom: after releasing the vertical ring and beginning horizontal Pan, scrolling visibly stuttered. The hardware
has separate physical Wheel and Consumer Pan controls rather than one control whose axis changes.

Current telemetry before attribution (helper PID `66968`, preserved at
`/tmp/mac-trackball-fix-scroll-phase5-axis-stutter.log`):

- The retained window has 248/248 paired raw/CG reports (220 vertical, 28 horizontal), zero fallback, sign mismatch,
  buffer overflow, model rejection, display recovery/start failure, or tap disable. Ring-live first output was
  `0.59–14.18 ms`; horizontal queue time was `0.33–2.43 ms`, and renderer callbacks stayed at `120 Hz` with an
  `8.333 ms` maximum gap. This rules out the input queue, HID correlation, target application, display callback
  cadence, and event tap as the source of the reported transition stutter.
- At `09:08:21.578–.657`, the actual input order was vertical sequence `502`, horizontal `503`, trailing vertical
  `504`, horizontal `505`, and vertical `506`. Each axis transition emitted `reason=axis-change`, stopped the shared
  display link, discarded the other axis's bounded motion/subpixels, opened with `dtMs=-1`, and started the link
  again. The complete window contains 28 such axis resets—the same count as horizontal reports—and two reports
  never reached an axis-specific first-output record before a following reset.

Confirmed root cause: Phase 5 modeled axis as mutually exclusive session identity. That assumption conflicts with
the device protocol: a released free-spinning Wheel can continue emitting while the independent Pan ring begins.
Interleaved legitimate reports therefore caused generation ping-pong and repeated cold openings. The previous
single-axis design avoided cross-axis leakage, but did so by discarding real independent motion and churning the
one display lifecycle.

Change (`RingMotionPlane.h`, `RingScrollRenderer.h/.m`, `Scroll.m`, motion/analyzer tests, project, and rewrite plan):

- Add a pure two-axis plane containing one bounded `RingMotionModel` state for Wheel and one for Pan. They share the
  target/config generation and actual frame interval, but retain independent input timestamps, speed/cadence,
  velocity/decay, remaining-area cap, direction, and biased subpixel accumulator.
- Axis reports no longer publish a generation reset. Same-axis reversal still clears old-sign velocity, subpixels,
  and pending latency on that axis only. Target/config/modifier/click/display, liveness recovery, and compatibility
  fallback resets still clear both axes atomically.
- One renderer, one shared `DisplayLink`, and one output callback remain authoritative. Each frame advances both
  states and combines nonzero horizontal/vertical integer components into one phase-less two-axis pixel-wheel event.
  The link stops only after neither axis has visible future output. The output zero-vector check now tests both
  components instead of their sum, so equal-and-opposite diagonal components are valid.
- Pending first-output latency is consumed only when its own axis produces a pixel. Frame telemetry adds per-axis
  event/output/remaining fields and `axis=mixed`; analyzer schema v4 reconstructs per-axis output and makes any
  `reason=axis-change` reset an explicit regression signal.
- The shared continuous-wheel line pixelator now supports selective X/Y reset, so reversing one physical ring also
  cancels that ring's fractional line bias without erasing the other ring's independent fraction.

Preserved behavior: reports are processed immediately without a timer, confirmation count, axis arbiter, or replay.
Each wheel keeps atomic reversal and its independent initial-distance, velocity, and remaining-area bounds. There is
still one event producer and no second display link or target-distance reservoir. Raw fallback, synthetic marking,
phase-less ordinary output, legacy System/non-Regular/effect routing, effect terminal phases, generation ordering,
parked-tail discard, and cold-start watchdog semantics are unchanged.

Verification: `./dev.sh scroll-tests` passes all cadence, display-lifecycle, output-policy, correlator, motion,
captured replay, and seven analyzer suites. The new pure test exercises vertical -> horizontal -> trailing vertical,
proves both signed frame components coexist, proves a vertical reversal cannot mutate horizontal state, and confirms
that a real session reset clears both. `plutil -lint`, `bash -n dev.sh`, and `git diff --check` pass. The full Debug
Xcode build succeeds; the first sandboxed attempt failed only because existing Swift/Clang cache directories were
not writable, and both normal-cache retries completed with `BUILD SUCCEEDED` after the final selective-subpixel
integration.

Remaining gate/tradeoff: deployment was attempted, and the rebuilt app installed the candidate, but macOS currently
enumerates no active display (`system_profiler SPDisplaysDataType` lists only the GPU). Helpers `97160`, `97188`, and
later launchd retries aborted in the pre-existing `DisplayLink.m` startup assertion with `InvalidArgument` before
HID attachment or renderer use. The exact `com.pixeption.mac-mouse-fix.helper` job was booted out to stop the
10-second crash loop. This is the same no-display environment blocker recorded in Phase 1, not evidence about the
two-axis change. Once a display is available, restart through `./dev.sh run` and perform the exact overlap retest;
its capture must show zero axis-change resets and no display stop/start churn while interleaved Wheel/Pan reports
retain one generation. Simultaneously coasting both independent rings can intentionally create diagonal wheel
events; each component remains independently bounded, so combined vector magnitude can reach `sqrt(2)` times one
axis's maximum if both rings are physically driven at their individual ceilings. Compatibility/effect and wider
application gates for Phase 5 remain open.

## 2026-09-04 — independent Wheel/Pan overlap passes the physical telemetry gate

Symptom retested: beginning horizontal Pan while the released vertical Wheel still emitted reports previously
stuttered because every axis transition reset the shared renderer and display link. The two-axis replacement needed
physical evidence that independent motion can overlap without cross-axis cancellation or lifecycle churn.

Evidence (helper PID `29474`, preserved at
`/tmp/mac-trackball-fix-scroll-phase5-independent-axes.log`):

- Startup selected `ring-live` with `horizontalPan=1 independentAxes=1`, and the exact TB800 attached non-seizing as
  registry ID `4294971676`.
- All 126 raw reports paired with 126 handled CG reports: 96 vertical and 30 horizontal, both directions, with zero
  fallback, sign mismatch, buffer overflow, model rejection, or carry drop. All reports routed to the live renderer.
- Sequences `20–24` interleaved vertical/horizontal input, and sequences `64–81` repeatedly alternated axes. They
  retained generation `5` and produced zero `reason=axis-change` resets. Eleven frame windows reported `axis=mixed`;
  their vertical and horizontal pixel components were both represented in the shared output event stream.
- The renderer processed 975 callbacks and posted 829 nonzero events across 34 summaries at `120 Hz`, with an
  `8.333 ms` maximum callback gap. Display starts occurred only at real cold session starts, not on axis transitions.
- Six horizontal and five vertical direction changes discarded the reversing axis's carried velocity on the same
  update without a generation reset. Mixed output continued around the overlap sequences, providing runtime evidence
  that reversal did not clear the other axis.
- First-output latency was `0.92–21.03 ms`; p95 was `12.54 ms` horizontally and `11.72 ms` vertically. Horizontal
  queue time was `0.50–5.92 ms`, vertical queue time was `0.31–5.23 ms`. The one 21.03 ms horizontal maximum was
  still within the planned integer-output visibility window, not accompanied by queue, display, HID, or tap failure.
- The explicit remaining-area bound held at `582.195 px`; two reports reached the velocity cap. There was no parked
  or stalled-tail discard, display start failure/recovery, or unexplained tap disable.

Conclusion/progression: the prior failure was the rejected axis-as-session design, not the input queue, HID pairing,
target application, or display cadence. The independent two-model plane fixes that specific physical regression: it
retains one renderer generation and one display lifecycle while emitting combined phase-less two-axis events. No
additional code or tuning change was justified by this capture.

Verification: refreshed the bounded recorder, ran `./dev.sh ring-capture-report`, inspected interleaved model,
mixed-frame, reversal, display, target, latency, and tap records, preserved the snapshot, reran the full
`./dev.sh scroll-tests` suite, and ran `git diff --check`. Automated cadence, display lifecycle, output policy,
correlator, motion-plane/property/refresh, captured replay, and analyzer tests all pass.

Preserved behavior/tradeoff: reports remain immediate and each physical ring retains independent cadence, velocity,
subpixels, reversal, and bounds under one event producer. Simultaneous coasting may intentionally produce diagonal
wheel events, whose vector magnitude can exceed a single axis while each component stays independently bounded.
This capture covered Browser and Kitty on display `3`; it did not exercise System/non-Regular/effect fallbacks,
Safari/Telegram/Finder/VS Code/Xcode compatibility, additional displays, or an explicit post-test subjective verdict.
Phase 5 therefore remains open for those gates and a telemetry-confirmed legacy rollback before Phase 6.

## 2026-09-04 — sparse stopped openings felt slow despite healthy delivery

Symptom: an isolated slow ring count after output had stopped felt as though scrolling started late. The delay was
reproducible in the first visible part of the response, but it was not accompanied by a stalled helper or an input
delivery failure.

Current telemetry before attribution (helper sequence `2020` at `23:02:44.619`, preserved at
`/tmp/mac-trackball-fix-scroll-phase5-slow-start-2026-09-04-2302.log`):

- The prior output had stopped and the physical report gap was `694.026 ms`. The report reached the scroll queue in
  `1.107 ms`, and its first integer output arrived in `9.02 ms`; HID/CG pairing, the event tap, and the display-link
  callback stream were healthy. The perceived slow start therefore was not queueing, target-application, HID,
  event-tap, or display latency.
- The one-count report had raw omega `1.441`, mapped distance `11.347 px`, and decay `150.543 ms`. Its resulting
  velocity was only about `76.146 px/s`, so the same bounded distance was distributed too softly after the screen
  had already become still. The existing responsiveness cap was active, but its one-pixel/two-fast-callback
  visibility criterion guaranteed detection rather than a decisive stopped opening.

Confirmed root cause: the response floor did not distinguish a live sparse report, where preserving ongoing motion
is important, from a report arriving after velocity and retained distance were effectively exhausted. Applying a
larger impulse or restoring the rejected legacy `32 px` minimum would add distance and amplify wrong-sign hardware
rebound. Waiting for another report would restore the rejected confirmation delay. The missing distinction was
only the rate at which an already-bounded stopped-opening distance becomes visible.

Change (`RingMotionModel.h`, ring renderer/shadow telemetry, motion/analyzer tests):

- A report starts from stopped output only when pre-report velocity is at most the renderer's existing `1 px/s`
  stop threshold and pre-report remaining distance is at most the existing `1 px` visibility floor. First reports
  meet the same definition. Sparse reports arriving over still-visible motion do not enter this branch.
- Stopped openings now choose a decay no slower than required to expose `2 px` over the existing two-fast-callback
  visibility window. Live sparse updates retain the previous `1 px` rule. This changes only decay/rate: impulse
  distance, retained area, initial-distance cap, velocity cap, remaining-area cap, reversal semantics, and total
  predicted output are unchanged.
- The model and live/shadow logs expose `startsFromStoppedOutput` and
  `stoppedOpeningResponsivenessDecayLimited`; analyzer schema v4 counts the stopped-opening caps separately. The
  renderer and model now share one stop-velocity constant so classification and display-link stopping cannot drift.

Verification: `./dev.sh scroll-tests` passes the complete cadence, display-lifecycle, output-policy, correlator,
motion model/plane/property/refresh, captured replay, and seven analyzer suites. The new captured-shape model test
proves the visibility window receives at least `2 px`, the retained-plus-impulse area is exactly preserved, and no
carry is dropped; the existing live-sparse test proves an active response does not receive the stopped-opening
floor. `git diff --check` and the full Debug Xcode build pass. The final candidate was deployed as helper PID
`83100`; its physical capture is preserved at
`/tmp/mac-trackball-fix-scroll-phase5-stopped-opening-fix.log`:

- All 15 raw reports paired with 15 handled CG reports and all routed through ring-live, with zero fallback, sign
  mismatch, overflow, model reject, axis reset, or carry drop. Four stopped openings exercised the new cap; live
  follow-ups did not.
- Stopped sequences `3`, `6`, and `9` mapped an `8.142 px` count to `49.268 ms` decay with both stopped-opening flags
  set. Sequence `10` mapped `14.829 px` to `95.866 ms`. First integer output across the capture was
  `1.80–14.18 ms`; queue latency was `0.695–2.304 ms` for the stopped examples and no delivery pathology accompanied
  the openings.
- The renderer processed 378 callbacks and 209 output events at `120 Hz` with an `8.333 ms` maximum gap. There was
  no parked/stalled-tail discard, display start failure/recovery, or unexplained tap disable.

Preserved behavior/tradeoff: a very small isolated count after the axis has visually stopped now spends the same
`8–15 px` over a shorter interval, so repeatedly ultra-sparse stopped counts can feel crisper or slightly more
pulsed. Once either meaningful velocity or more than one pixel of retained output remains, the established live
sparse blend is untouched. Because no distance is added, the change does not enlarge an opposite-sign rebound.
Phase 5 remains open for an explicit subjective verdict, compatibility/effect and wider-application coverage,
additional displays, and the telemetry-confirmed legacy rollback.

## 2026-09-05 — subpixel-exhausted tail escaped the stopped-opening response

Symptom: a recent vertical start again felt slow after the two-pixel stopped-opening response was deployed.

Current telemetry before attribution (helper PID `83100`, preserved at
`/tmp/mac-trackball-fix-scroll-phase5-nearly-exhausted-slow-start-2026-09-05-2202.log`):

- The retained session contains 255/255 paired raw/CG reports, zero fallback, sign mismatch, overflow, model reject,
  axis reset, carry drop, display recovery/start failure, or tap disable. Across 256 ring-live latency samples,
  first integer output was `0.62–13.50 ms` and queue time was `0.32–9.82 ms` (`0.52 ms` median). Renderer callbacks
  remained at `120 Hz` with an `8.333 ms` maximum gap. This again rules out the queue, HID correlation, display
  link, target application, and event tap as a general slow-start source.
- The newest distinct weak shape was sequence `4766` at `22:02:34.310`. It arrived `411.004 ms` after a fast
  sequence and reached output in `1.18 ms` with `0.729 ms` queued, but selected `145.229 ms` decay for an
  `18.267 px` one-count response. Only about `0.648 px` of the prior response remained, so there was no meaningful
  integer motion left to overlap.
- The model nevertheless emitted `startsFromStoppedOutput=0` because the old classification also required residual
  analytic velocity at or below `1 px/s`; the short prior decay represented its subpixel remainder as
  `8.831 px/s`. The preceding frame window had already drained remaining output from `48.570 px` to `1.435 px`,
  and the report arrived after it fell below one pixel. This is a visibility-classification failure, not a repeat of
  the already-working two-pixel decay bound.

Confirmed root cause: stopped-opening classification conjoined two different concepts. Remaining area determines
whether any future integer output can still be visible, while the renderer's `1 px/s` threshold determines when to
stop analytic callbacks. A short tau can keep analytic velocity above `1 px/s` even when less than one pixel remains
in total, allowing a visibly fresh report to use the live sparse response.

Change (`RingMotionModel.h`, `RingMotionModelTests.c`):

- An axis now starts from stopped output when pre-report remaining area is at most the existing one-pixel visibility
  floor, independent of its analytic velocity representation. The first report remains stopped by definition.
- More than one pixel of retained motion still selects the existing live sparse behavior. The response continues to
  change decay only: no distance, carry, velocity ceiling, reversal behavior, timer, confirmation gate, or reservoir
  was added.
- Exact captured-shape coverage initializes `8.831 px/s` at `73.349 ms` decay, proving the subpixel remainder is
  below one pixel despite exceeding the renderer stop velocity. The next report must take the stopped-opening cap,
  preserve retained-plus-impulse area exactly, drop no carry, and expose at least two pixels in the visibility
  window. For sequence `4766`'s captured `18.267 px` impulse, the same analytic bound reduces the maximum eligible
  decay from `145.229 ms` to approximately `119.776 ms`.

Verification: `./dev.sh scroll-tests` passes the full cadence, display-lifecycle, output-policy, correlator, motion
model/plane/property/refresh, captured replay, and seven analyzer suites; `git diff --check` passes. The first Xcode
build attempt failed only because the sandbox could not write existing Swift/Clang caches. The normal-cache Debug
build then completed with `BUILD SUCCEEDED`, and `./dev.sh run` deployed the result. Helper PID `5399` selected
`ring-live`, started the non-seizing HID observer, attached the exact TB800 registry ID `4294971676`, reset config,
and re-enabled its event tap without a startup failure.

Remaining verification/tradeoff: a post-deployment physical recurrence is still required to confirm
`startsFromStoppedOutput=1 stoppedOpeningResponsivenessDecayLimited=1` for the formerly missed subpixel-tail shape
and to judge feel. A report arriving while at most one pixel remains may now respond more crisply even if that last
fraction was still decaying at more than `1 px/s`; reports with more than one pixel left retain established sparse
overlap. The broader Phase 5 compatibility/display/effect matrix and legacy rollback remain open.

## 2026-09-05 — the two-pixel stopped-opening floor still felt weak

Symptom: immediately after the subpixel-tail classification fix, another stopped vertical opening felt slow.

Current telemetry before attribution (helper PID `5399`, preserved at
`/tmp/mac-trackball-fix-scroll-phase5-recurrent-slow-start-2026-09-05-2256.log`):

- The replacement classifier is physically verified. Sequence `1071` at `22:56:24.579` arrived after `413.016 ms`
  with only about `0.974 px` retained despite `8.213 px/s` analytic velocity. It now correctly emitted
  `startsFromStoppedOutput=1 stoppedOpeningResponsivenessDecayLimited=1`, selected `119.212 ms` instead of the old
  approximately `145 ms` class, and produced first output in `0.79 ms` with `0.571 ms` queued.
- The newest stopped opening was sequence `1085` at `22:56:39.165`, after `4.800 s` and after the prior renderer
  had logged `action=stop`. HID and CG signs matched, display start returned `result=0`, queue time was `0.670 ms`,
  and first output arrived in `7.24 ms`. The model correctly classified a stopped direction change and applied the
  two-pixel response cap, but the one-count input still had only `8.142 px` total and `49.268 ms` decay. Its next
  physical report arrived `41.979 ms` later and immediately jumped to `145.268 px`, exposing the weak initial
  response as a short velocity notch rather than delayed delivery.
- Across the retained helper session, all 248 raw reports paired with 248 handled CG reports, with zero fallback,
  sign mismatch, overflow, model reject, axis reset, carry drop, display recovery/start failure, or tap disable.
  First output was `0.76–18.05 ms` (`5.66 ms` median), queue time was `0.35–10.41 ms` (`0.62 ms` median), and 3,721
  renderer callbacks retained a maximum `8.333 ms` gap. No queue, HID, target, tap, or display failure explains the
  reported feel.

Confirmed root cause: the classification correction worked, but the two-pixel/two-fast-callback floor remained only
a detectability threshold. The fresh physical report demonstrates that an `8.142 px` stopped response could still
spend three quarters of its area after that initial window and then be followed by a much stronger acceleration
packet. Increasing report distance would also increase the indistinguishable wrong-sign long-idle baseline recorded
in Phase 1, so temporal distribution—not amplitude or another classifier—is the safe tuning dimension.

Change (`RingMotionModel.h`, `RingMotionModelTests.c`):

- A stopped opening now exposes at least `3 px`, rather than `2 px`, over the same two-144-Hz-callback visibility
  window. Live sparse reports retain the established one-pixel rule.
- The captured `8.142 px` response therefore shortens from `49.268 ms` to approximately `30.220 ms`. Total output
  remains exactly `8.142 px`; no distance is added to a deliberate count or an ambiguous wrong-sign baseline.
- Captured-shape coverage reproduces the `4.800 s` stopped reversal, asserts the exact impulse distance, direction
  cancellation, zero carry drop, decay below `31 ms`, and at least three pixels of analytic output in the window.

Verification: `./dev.sh scroll-tests` passes the complete cadence, display-lifecycle, output-policy, correlator,
motion model/plane/property/refresh, captured replay, and seven analyzer suites. The paused-reversal replay's
maximum remaining area changed slightly (`212.673 -> 211.686 px`) because stopped response timing changed; its total
integrated output remained exactly `-237.942 px`. `git diff --check` and the normal-cache Debug Xcode build pass.
`./dev.sh run` deployed the candidate; final helper PID `33989` selected `ring-live`, started the non-seizing HID
observer, attached TB800 registry ID `4294971676`, reset config, and re-enabled its tap without a startup failure.

Preserved behavior/tradeoff: input remains immediate, total distance is unchanged, and reports with visible retained
motion keep their accepted sparse overlap. Very small stopped counts are now more front-loaded and finish sooner,
which can feel crisper or more discrete during deliberately ultra-sparse input. This is preferable to amplifying the
known indistinguishable wrong-sign HID baseline. A physical occurrence on PID `33989` and subjective verdict remain
required; the broader Phase 5 application/display/effect matrix and legacy rollback are still open.

## 2026-09-05 — three-pixel stopped-opening response passes physical telemetry

The deployed helper PID `33989` physically exercised the tuning above. The preserved capture is
`/tmp/mac-trackball-fix-scroll-phase5-three-pixel-stopped-opening-2026-09-05.log`.

- All 47 raw reports paired with 47 CG reports and routed through ring-live, with zero fallback, sign mismatch,
  overflow, model reject, axis reset, or carry drop. Six reversals remained same-update and same-sign.
- Stopped one-count sequences `5` and `10` mapped exactly `8.142 px` and selected `30.218 ms` decay with
  `responsivenessDecayLimited=1 startsFromStoppedOutput=1 stoppedOpeningResponsivenessDecayLimited=1`. Sequence `5`
  followed `22.692 s` of silence and an opposite direction; sequence `10` followed `2.197 s`. This verifies both
  the three-pixel response and preservation of atomic reversal/total distance on real hardware.
- A larger stopped sequence `40` mapped `22.674 px` to `97.865 ms` under the same three-pixel rule. Stopped reports
  whose natural response already exceeded three pixels, such as sequences `6`, `17`, and `41`, were correctly not
  shortened by the responsiveness limiter.
- First output across all 47 reports was `1.01–12.22 ms` (`5.68 ms` median, `10.02 ms` p95); queue time was
  `0.47–4.46 ms` (`0.71 ms` median). The renderer processed 887 callbacks and posted 603 events at `120 Hz` with an
  `8.333 ms` maximum callback gap. There was no parked/stalled discard, display start failure/recovery, or tap
  disable.

Conclusion: the exact stopped-only timing change is physically active and healthy. No further classifier, distance,
queue, or display change is justified by this pass. Subjective acceptance and the broader Phase 5 compatibility,
effect, display, and telemetry-confirmed legacy rollback gates remain open.

## 2026-09-05 — stopped-opening timing was healthy but amplitude still notched

Symptom: after the three-pixel stopped-opening timing fix was physically verified, another vertical start felt slow.

Current telemetry before attribution (helper PID `33989`, preserved at
`/tmp/mac-trackball-fix-scroll-phase5-amplitude-notch-2026-09-05-2318.log`):

- The retained session had 198/198 paired vertical raw/CG reports, zero fallback, sign mismatch, overflow, model
  reject, axis reset, carry drop, display recovery/start failure, or tap disable. First output was `0.60–23.13 ms`
  (`5.655 ms` median, `12.289 ms` p95), queue time was `0.36–20.16 ms` (`0.61 ms` median, `3.274 ms` p95), and
  3,536 callbacks retained an `8.333 ms` maximum gap. Delivery remained healthy.
- Sequence `194` at `23:18:02.893` followed `903.989 ms` of silence, was correctly classified as stopped, applied
  the three-pixel response cap, queued for `3.722 ms`, and reached first integer output in `13.19 ms`. Its measured
  speed was only `1.106 reports/s`, so the acceleration mapping gave the one-count opening `8.924 px` total over
  `33.896 ms`.
- Sequence `195` arrived `46.988 ms` later and immediately mapped to `131.121 px`. The reported feel therefore
  coincided with a roughly `9 px -> 131 px` physical acceleration discontinuity, not a missed stopped classifier,
  slow response tau, queue delay, display-link stall, target-application delay, or HID/correlation failure.

Confirmed root cause: a long silent interval is the only cadence available for the first stopped count, and using
that interval literally in the quadratic distance map can make a real ramp begin with a very small total impulse.
The prior two- and three-pixel changes successfully controlled when that bounded impulse became visible, but could
not remove the amplitude notch. This new evidence justifies a narrowly bounded distance correction. It does not
justify restoring the rejected `32–35 px` unconditional opening or report-confirmation delay: an isolated genuine
count and the known opposite-sign long-idle hardware baseline remain indistinguishable.

Change (`RingMotionModel.h`, live/shadow telemetry, model/analyzer tests):

- When and only when an axis starts from visually stopped output and its measured response speed is below
  `1.5 reports/s`, distance mapping uses `1.5 reports/s`. Raw speed, filtered speed, cadence, direction, and the
  physical report remain unchanged. With the captured user scale this raises sequence `194`'s approximately
  `8.924 px` opening to approximately `12.1 px`, still far below the `5 reports/s` full opening and the rejected
  legacy minimum.
- The existing stopped-only three-pixel/two-fast-callback temporal floor is applied to the resulting distance.
  Reports over visible motion, stopped reports already at or above `1.5 reports/s`, fast motion, reversal
  cancellation, caps, per-axis ownership, fallback routing, and target/display generations are unchanged.
- Live and shadow model telemetry now expose `distanceOmega` and `stoppedOpeningDistanceRaised`; analyzer schema v4
  counts the new branch as `stoppedOpeningDistanceRaiseEvents`. Captured-shape coverage compares the same model
  state with and without the floor, proving identical raw/filtered speed, an `8.924 -> 12.101 px` bounded distance
  change, and at least three pixels in the visibility window. Existing tests isolate the earlier timing-only fixes.

Verification: `./dev.sh scroll-tests` passes the complete cadence, display-lifecycle, output-policy, correlator,
motion model/plane/property/refresh, all captured replays, and seven analyzer suites; `git diff --check` and the full
Debug Xcode build pass. `./dev.sh run` deployed helper PID `46699`. Its post-fix physical capture is preserved at
`/tmp/mac-trackball-fix-scroll-phase5-stopped-amplitude-floor-2026-09-05.log`:

- All 24 raw reports paired with all 24 CG reports and routed through ring-live, with zero fallback, sign mismatch,
  overflow, reject, axis reset, carry drop, display recovery/start failure, or tap disable. First output was
  `2.56–14.61 ms`, queue time was `0.48–5.44 ms`, and 516 callbacks retained an `8.333 ms` maximum gap.
- Stopped sequences `5`, `8`, and `15` physically exercised the branch after `5.874 s`, `4.176 s`, and `1.673 s`.
  Each retained raw/filtered omega `1.000`, logged `distanceOmega=1.500 stoppedOpeningDistanceRaised=1`, mapped the
  count to `11.769 px`, and applied the three-pixel response at `47.203 ms`. Sequence `15` reached output in
  `9.92 ms` with `0.525 ms` queued, then its live `20.011 reports/s` continuation correctly bypassed the floor.

Preserved behavior/tradeoff: this deliberately adds at most the gap between a sub-`1.5 reports/s` stopped mapping
and the `1.5 reports/s` mapping, so an indistinguishable isolated wrong-sign baseline can also become modestly
larger. The bound is approximately `12 px` at the captured sensitivity rather than the rejected `32–35 px`, and it
never applies while more than one pixel remains visible. Subjective acceptance and the broader Phase 5
compatibility, effect, display, and telemetry-confirmed legacy rollback gates remain open.

## 2026-09-06 — replace threshold tuning with one stopped-opening velocity invariant

Symptom: slow starts continued after both the three-pixel timing floor and the `1.5 reports/s` stopped-distance
floor were deployed. The user noted that this had remained regressed across repeated narrow fixes and requested a
different approach.

Current telemetry before attribution (helper PID `46699`, preserved at
`/tmp/mac-trackball-fix-scroll-phase5-recurrent-opening-velocity-notch-2026-09-06.log`):

- The retained window contained 236 ring-live model updates and latency samples, all sourced from HID with zero
  fallback, sign mismatch, overflow, reject, axis reset, carry drop, display recovery/start failure, or tap disable.
  First output was `0.56–18.93 ms` (`5.885 ms` median, `12.198 ms` p95), queue time was `0.39–12.24 ms`
  (`0.735 ms` median, `3.405 ms` p95), and 4,344 callbacks retained an `8.333 ms` maximum gap. This again rules
  out delivery, display cadence, target routing, and tap liveness as the general regression.
- Within the same UI/config session, reset openings consistently began at `439.419 px/s`, while non-first reports
  arriving after visible output stopped clustered around only `233–255 px/s`. Thirteen such reports exercised the
  `1.5 reports/s` distance floor and 19 exercised the three-pixel cap, yet the subjective failure recurred. The
  previous fixes were active but encoded detectability/amplitude thresholds rather than a consistent opening rate.
- The newest uncovered case was sequence `1329` at `10:50:46.892`. It was a stopped reversal after `425.021 ms`,
  queued for `0.504 ms`, and reached first output in `6.93 ms`. At raw omega `2.353`, it was above the distance
  floor; its `17.719 px` response naturally emitted just over three pixels in the visibility window, so it also
  escaped the timing floor. It consequently kept `70.885 ms` decay and opened at only `249.961 px/s`. Sequence
  `1330` arrived `38.979 ms` later and jumped to `2,346.404 px/s` impulse velocity. This is another response-rate
  notch despite healthy classification and delivery.

Confirmed root cause: the model had a responsive first-report envelope, but stopped continuations were governed by
two independent thresholds. Reports on either side of those thresholds could be visually identical openings while
starting at materially different velocities. Raising the thresholds again would merely move the escape boundary;
raising distance also enlarges the indistinguishable long-idle wrong-sign HID baseline. The missing invariant is
that every visually fresh response should open at least as decisively as the accepted first report, regardless of
which cadence/distance bucket produced it.

Change (`RingMotionModel.h`, live/shadow telemetry, motion/analyzer tests):

- Remove the `1.5 reports/s` stopped-distance floor. Distance again comes exclusively from the measured raw and
  filtered report speed, so this replacement does not enlarge a genuine count or the ambiguous wrong-sign baseline.
- For every non-first report whose pre-report remaining area is at most the existing one-pixel visible floor, cap
  decay so its impulse velocity is at least the current configuration's normal first-report velocity. This value is
  derived continuously from the same UI distance map, initial-speed calibration, and start decay rather than a new
  pixel/rate constant. Faster natural openings and every report over visible motion remain unchanged.
- Keep the three-pixel/two-fast-callback rule as the integer-output safety minimum. Telemetry now exposes the more
  general `stoppedOpeningVelocityDecayLimited`; the analyzer separately counts
  `stoppedOpeningVelocityLimitEvents` while retaining support for historical distance-floor captures.
- Exact recent-shape coverage reproduces sequence `1329`, verifies that it already passed the old three-pixel rule,
  preserves the exact `17.719 px` distance and atomic reversal with zero carry, and raises only its impulse rate to
  the normal opening envelope. Live sparse overlap remains an explicit non-match.

Verification: `./dev.sh scroll-tests` passes the complete cadence, display-lifecycle, output-policy, correlator,
motion model/plane/property/refresh, all captured replays, and seven analyzer suites; `git diff --check` and the full
Debug Xcode build pass. `./dev.sh run` deployed helper PID `19326`. Its post-fix physical capture is preserved at
`/tmp/mac-trackball-fix-scroll-phase5-opening-velocity-invariant-2026-09-06.log`:

- All 32 raw reports paired with 32 CG reports and routed through ring-live, with zero fallback, sign mismatch,
  overflow, reject, axis reset, carry drop, display recovery/start failure, or tap disable. First output was
  `1.09–12.43 ms` (`6.65 ms` median), queue time was `0.45–4.94 ms`, and 384 callbacks retained an `8.333 ms`
  maximum gap.
- Stopped sequences `3`, `10`, and `16` exercised the replacement across raw omega `1.362`, `2.907`, and `1.709`.
  Their honest distances remained `10.784`, `21.473`, and `13.254 px`, but decay shortened to `24.540`, `48.867`,
  and `30.162 ms`; every impulse opened at exactly `439.419 px/s`, matching the normal first-report envelope.
  They reached first output in `11.51`, `9.15`, and `6.45 ms` with sub-`0.7 ms` queue time. Live follow-ups bypassed
  the cap and accelerated on the same report.

Preserved behavior/tradeoff: no report is delayed, confirmed, discarded, replayed, or given extra distance. Atomic
reversal, live sparse overlap, current-report acceleration, independent axes, output/carry/velocity caps,
compatibility fallbacks, target generations, and display recovery are unchanged. An isolated ambiguous hardware
baseline now spends its honest small distance more quickly, which can make it crisper, but no larger than its raw
mapping. This deliberately supersedes the ineffective amplitude-floor approach rather than stacking another
classifier or restoring the rejected `32–35 px` opening. Subjective acceptance and the broader Phase 5 application,
effect, display, and telemetry-confirmed rollback gates remain open.

## 2026-09-06 — reversal openings no longer depend on discarded old-sign area

Symptom: another recent vertical opening felt slow after the stopped-opening velocity invariant was deployed.

Current telemetry before attribution (helper PID `19326`, preserved at
`/tmp/mac-trackball-fix-scroll-phase5-second-opening-invariant-recurrence-2026-09-06.log`):

- All `236` handled reports routed through ring-live with `100%` HID pairing, zero fallback, sign mismatch, buffer
  overflow, model rejection, axis reset, carry drop, display recovery/start failure, or tap disable. Ring-live first
  output was `0.780–14.740 ms` (`5.820 ms` median, `11.348 ms` p95), queue time was `0.370–9.010 ms`
  (`0.630 ms` median), and `3,974` renderer callbacks retained an `8.333 ms` maximum gap. The replacement velocity
  invariant fired on `24` stopped openings. This rules out a general input, queue, HID, target, display, or tap
  regression and confirms the preceding fix was active.
- Sequence `2842` at `21:56:24.530` was the remaining weak opening. It reversed after `363.983 ms`, queued for
  `1.151 ms`, reached first integer output in `4.65 ms`, and atomically discarded the old direction. Immediately
  before the report the old response was `10.720 px/s` at `95.680 ms` decay, representing approximately `1.026 px`
  of old-sign area—barely above the one-pixel stopped classifier. The report consequently logged
  `startsFromStoppedOutput=0`, retained `70.885 ms` decay, and opened its honest `20.400 px` new-sign impulse at only
  `287.783 px/s`.
- Other retained reversals immediately outside the same fixed boundary showed the same structural asymmetry:
  sequences `2735`, `2774`, and `2884` opened at approximately `396–406 px/s`, while ordinary reset openings and
  qualified stopped openings used the accepted `439.419 px/s` envelope.

Confirmed root cause: `startsFromStoppedOutput` considered the amount of pre-report area without considering its
sign. That is valid for a same-direction sparse continuation, because old motion can visibly overlap the new
impulse. It is invalid for a direction change: the model's atomic-reversal invariant discards every pixel of the
old sign before applying the current report. Even `1.026 px` or much more old-direction area supplies exactly zero
new-direction output, so allowing it to weaken the opposite opening made response rate depend on state which the
same update necessarily destroys. Moving the one-pixel threshold would only move this escape again.

Change (`Helper/Core/Scroll/RingMotionModel.h`, `Tests/RingMotionModelTests.c`):

- Define a direction change as a fresh output opening in addition to a first report or a same-direction report with
  at most one visible pixel remaining. Every reversal therefore receives the existing stopped-opening response and
  normal-opening-velocity invariants, independent of the amount of old-sign area it atomically discards.
- Exact sequence-`2842` coverage starts with the captured `1.026 px` old-sign remainder, proves that it is above the
  old classifier, and verifies immediate direction replacement, zero carried velocity, unchanged `20.400 px`
  distance, zero carry drop, and a `439.419 px/s` opening derived from the current configuration.
- No new pixel, cadence, speed, or time threshold was added. This extends the preceding structural invariant to the
  direction domain rather than raising another boundary or restoring the rejected `32–35 px` distance floor.

Preserved behavior: reversal still cancels the old sign and delivers the requesting report on the same update.
Current-report distance, raw/filter acceleration, same-direction live sparse overlap, independent axes, integer
visibility bound, output/area/velocity caps, target/config/click generations, compatibility fallbacks, parked/stall
recovery, and display ownership are unchanged. No report is delayed, confirmed, discarded, replayed, or given extra
distance. The known indistinguishable wrong-sign HID baseline is not enlarged; its honest distance is merely spent
at the accepted opening rate when it reverses direction.

Verification:

- `./dev.sh scroll-tests` passes the full cadence, display-lifecycle, output-policy, correlator, motion
  model/plane/property/refresh, captured replay, and seven analyzer suites under warning-as-error builds.
- The exact captured replay passes as described above; existing active/paused reversal, rebound, sparse, target
  reset, horizontal, packetization, and fixed/variable-refresh cases remain green. `git diff --check` passes.
- `./dev.sh build` and `./dev.sh run` both completed with `BUILD SUCCEEDED`. The final deployed Debug helper PID
  `15664` selected ring-live, started the non-seizing observer, attached TB800 registry ID `4294971676`, reset its
  configuration, and re-enabled its tap without a startup failure.
- The post-deployment physical capture is preserved at
  `/tmp/mac-trackball-fix-scroll-phase5-direction-aware-opening-2026-09-06.log`. All `34` raw reports paired with all
  `34` CG reports and routed through ring-live, with zero fallback, sign mismatch, overflow, reject, axis reset,
  carry drop, display recovery/start failure, or tap disable. First output was `0.620–15.020 ms` (`5.695 ms`
  median, `11.450 ms` p95), queue time was `0.350–4.160 ms`, and `358` callbacks retained an `8.333 ms` maximum
  gap.
- Physical reversals `7` and `23` arrived after `236.988 ms` and `269.841 ms` while approximately `4–5 px` of
  old-sign area remained. Both logged `startsFromStoppedOutput=1`, zero carried velocity, and
  `stoppedOpeningVelocityDecayLimited=1`; their honest `30.129 px` and `26.776 px` distances opened at exactly
  `439.419 px/s`. Reversal `14` also logged the direction-aware stopped-opening classification but naturally opened
  faster at `574.934 px/s`, so it correctly required no velocity cap. Following reports accelerated immediately.

Remaining verification/tradeoff: the direction-aware classification and capped/naturally-fast branches are now
physically verified. A very slow reversal over still-visible old-direction motion is temporally crisper than before,
because old-sign continuity cannot survive atomic cancellation; its requested distance is unchanged. The user's
subjective verdict and the wider Phase 5 application, horizontal/effect, available-display, and telemetry-confirmed
rollback gates remain open.

## 2026-09-06 — weak same-direction carry must not bypass opening protection

Symptom: slow starts recurred after the direction-aware opening fix. Current PID `15664` telemetry is preserved at
`/tmp/mac-trackball-fix-scroll-phase5-continuity-opening-before-2026-09-06.log`. All 243 handled reports paired with
HID and routed live, with zero fallback, sign mismatch, overflow, rejection, carry drop, axis reset, display recovery,
start failure, or tap disable. First output was `0.640–14.660 ms` (median `5.730 ms`), queue p95 `2.640 ms`, and
4,073 callbacks had maximum gap `8.333 ms`. These measurements show healthy helper delivery; they do not measure
target-application presentation latency.

At `22:48:30.299`, sequence `1878` followed a `340.009 ms` same-direction gap. About `1.513 px` of old area remained
at `13.610 px/s`. Because that exceeded the binary one-pixel classifier, the model spread the new `21.703 px` over
`158.493 ms` and produced only `146.476 px/s`, despite first output in `4.25 ms` with `0.551 ms` queued. The next
report arrived `28.004 ms` later and accelerated immediately. Eleven retained same-direction updates had total
velocity below the normal `439.419 px/s` opening. Correspondence to the subjective complaint is inferred; the weak
response and escape from the classifier are captured directly.

Root cause: a binary amount-of-carry predicate treated a small fading tail as sufficient justification for the full
sparse envelope. Reversal protection was active and correct. Raising the stopped threshold again would merely move
the boundary, so the live side now uses the actual relative contribution of visible carry.

Change (`RingMotionModel.h`, `RingScrollRenderer.m`, `RingMotionModelTests.c`): retain the accepted stopped/reversal
rules and continuously blend the weak live response toward normal opening velocity, weighted by new impulse area
divided by new impulse plus visible retained area. Visible carry excludes the existing one-pixel stopped floor,
making the decay bound continuous at that boundary. Responses already faster than the normal opening retain their
natural envelope. All old area remains present through the existing area-preserving decay conversion; no distance
is added, no sign is changed, and no report is deferred. Live telemetry records `MFSCROLL_RING_OPENING` when the
continuity bound applies.

Verification: the full `./dev.sh scroll-tests` suite passes, including all captured replays, cadence, display
lifecycle, output policy, correlator, independent axes, refresh/packetization and randomized boundedness, and seven
analyzer tests. A 10,001-state sweep from zero through ten pixels of carry proves continuous, monotonic decay across
the old boundary and exact area preservation. Captured-state replay retains `21.703 px` plus `1.513 px` carry and
changes decay to `51.364 ms`, producing `451.988 px/s` with zero carry loss. `git diff --check` passes.

The initial sandboxed build could not write existing Swift/Clang caches. `./dev.sh run` with normal cache access
completed with `BUILD SUCCEEDED` and deployed helper PID `31568`, selecting ring-live and attaching the TB800.
Its physical capture is preserved at `/tmp/mac-trackball-fix-scroll-phase5-continuity-opening-after-2026-09-06.log`:
64/64 reports paired and routed live; 11 reversals; zero fallback, sign mismatch, overflow, reject, axis reset,
carry loss, display failure/recovery, or tap disable. First output was `0.680–17.640 ms` (median `4.960 ms`, p95
`11.634 ms`), queue median `0.520 ms`, p95 `2.759 ms`, and 864 callbacks retained an `8.333 ms` maximum gap.
The continuity bound physically fired on sequences `2`, `27`, `50`, and `52`, producing respectively `442.555`,
`452.141`, `443.737`, and `434.573 px/s`. This confirms the new branch is active on real reports; subjective
acceptance and uncaptured horizontal/effect/application/display cases remain open.

Intentional tradeoff: weak live sparse continuations are now crisper, with progressively more of the original
overlap as retained motion dominates. This supersedes the prior blanket exemption for every live response over one
pixel; the captured same-direction escape is the new evidence requiring that change. Very sparse physical reports
may feel more discrete, since their honest distance is spent sooner. Established cadence still begins on report two,
all motion uses one analytic state per axis, and fast response, reversal, target/effect/display ownership and caps
remain intact. Physical feel and the wider application/display/effect matrix must not be claimed from model tests.

## 2026-09-08 — user chooses normal opening distance over smaller hardware rebound

Symptom/evidence: PID `31568` retained 205 paired live reports with zero fallback, sign mismatch, overflow, reject,
carry loss, display failure/recovery, or tap disable. First output was `0.85–14.53 ms` (median `6.25 ms`), with
3,810 callbacks retaining an `8.333 ms` maximum gap. The capture is preserved at
`/tmp/mac-trackball-fix-scroll-stronger-opening-before-2026-09-08.log`.
At `23:40:55.534`, sequence `8472` followed `70.749617 s` idle and received only `8.142 px` at `18.528 ms` decay;
the next count arrived `34.968 ms` later and requested `171.512 px`. Multiple shorter paused starts reproduced the
same small opening. Normal reset openings in the same configuration received `35.153 px`. Delivery and the existing
opening-velocity protection were healthy; shortening decay could not restore missing opening distance.

The user explicitly approved stronger isolated starts after being told they also amplify the indistinguishable
wrong-direction HID baseline. This overrides the previous rejection of the normal-distance floor: its rebound
failure mode still exists and is now an accepted tradeoff, not claimed eliminated. The association of these captured
small impulses with subjective hesitation remains inferred.

Change: `RingMotionModel.h` gives visually stopped starts, including atomic reversals, at least the configuration's
normal first-report distance, bounded by maximum initial distance. Raw speed, filtered speed, cadence history and
faster natural distances are retained. Ongoing same-direction motion retains measured distance and the prior
continuity response. No timer, confirmation, delayed replay or second motion reservoir is introduced. The existing
velocity and remaining-area ceilings still apply. `RingScrollRenderer.m` records `stoppedOpeningDistanceRaised=1`
with sequence, distance and decay in `MFSCROLL_RING_OPENING`.

Verification: `./dev.sh scroll-tests` and `git diff --check` pass. New captured-parameter tests cover a `70.749617 s`
same-direction restart and reversal, `8.142 -> 35.153 px`, unchanged measured speeds, immediate faster follow-up,
and bounded output. The historical timing-only tests explicitly disable the new distance policy so their prior
invariants remain independently checked. All production-default captured replays, independent axes, fixed/variable
refresh, packetization, randomized bounds, cadence, lifecycle, output, correlator and seven analyzer suites pass.

Tradeoff: genuine isolated starts and indistinguishable wrong-sign hardware reports now both get the stronger
response. Ultra-sparse stopped reports can move farther. Sparse, reversal and rebound replay totals intentionally
change; live overlap, cancellation, target generations and effect/legacy routing remain intact. Subjective feel and
the wider physical app/display/effect matrix remain manual verification items.

Deployment: `./dev.sh run` completed with `BUILD SUCCEEDED`; helper PID `65365` selected ring-live and attached the
TB800. The preserved post-deployment capture is `/tmp/mac-trackball-fix-scroll-stronger-opening-after-2026-09-08.log`.
All 45 physical reports paired and routed live with zero fallback, sign mismatch, rejection, carry loss, display
failure/recovery or tap disable. First output was `0.88–14.57 ms` (median `5.79 ms`); 549 callbacks retained an
`8.333 ms` maximum gap. Sequences `6` and `13` physically logged `stoppedOpeningDistanceRaised=1`, `35.153 px`, and
`70.885 ms` decay, confirming the stronger opening is active. The older analyzer's distance-raise counter only reads
model records; these new separate opening markers were verified directly.

## 2026-09-09 — preserve unsigned frequency through low-speed reversals

Request/evidence: the user requested immediate response and direction-independent frequency estimation at low speed.
The pre-change PID `65365` snapshot contained 221/221 paired physical reports, no fallback/sign mismatch/overflow,
222 model updates (one input had rolled out), 19 reversals, no rejection/carry drop, and no display failure/recovery
or tap disable. First output was `0.81–14.47 ms` (median `6.47 ms`); queue median was `0.66 ms`, and 3,158 callbacks
had maximum gap `8.333 ms`. This measures helper delivery, not application presentation. For example, sequence
`526` at `08:56:11.087` reversed after `322.993 ms` and logged `cadenceMs=0` despite a measured raw rate of `3.096`.

Root cause/design: raw speed already uses absolute physical units divided by the interval across either direction,
but every reversal reset the time-based speed filter to raw speed and erased cadence. Low-speed changes of direction
therefore lost valid timing history. This is a user-directed consistency change, not a proven cure for the subjective
slow start. The earlier `08:44:10` and `08:44:52` counter-motion captures were reset openings, so their normal `35 px`
first responses predate the September 8 distance-floor change; reverting that floor would not remove those examples.

Change (`RingMotionModel.h`, live/shadow telemetry, `RingMotionModelTests.c`): preserve and update unsigned speed and
cadence on a reversal when both current raw speed and previous filtered speed are below the existing slow-band end
and fast-friction start, and the interval is within the existing cadence-memory horizon. There is no new tuning
constant. Other reversals retain the raw-speed reset and cadence clearing. The current sign still cancels all old-sign
output on the same update; only scalar timing history survives. Live and shadow telemetry expose qualifying reports
as `MFSCROLL_RING_FREQUENCY action=preserve-slow-reversal` with sequence, generation, axis, raw/filtered rate and cadence.

Verification: the full `./dev.sh scroll-tests` suite and `git diff --check` pass. New tests compare identical timestamp
streams with constant versus alternating signs, requiring identical raw/filtered frequency and cadence from report
two onward, immediate new-sign frame output, zero opposite carry, and the existing opening-velocity floor. Boundary
tests exclude either rate at/above the slow limit, fast-to-slow and slow-to-fast reversals, expired memory and session
resets. Existing captured sparse, active/paused reversal, rebound, horizontal, target-reset, independent-axis,
refresh/packetization, randomized-bound, legacy-policy, correlator and analyzer suites remain green.

Preserved behavior/tradeoff: no input gate, timer, direction vote, delayed replay or second reservoir. Normal opening
distance, visibility/velocity protection, fast output bounds, same-direction integration, per-axis ownership, target
and effect resets remain intact. A slow reversal may now use learned sparse timing, but still obeys the accepted
opening-rate bound; exact low-speed distance/decay can differ through the retained filter. An ambiguous first hardware
count remains immediate and cannot be identified as unwanted by this change. Physical low-speed reversal feel and
the wider app/display/effect matrix remain manual verification items.

Deployment: the initial sandboxed build failed on Swift/Clang cache writes; `./dev.sh run` with normal cache access
completed with `BUILD SUCCEEDED` and deployed helper PID `3201`, selecting ring-live and attaching the TB800.
The pre-change snapshot is `/tmp/mac-trackball-fix-scroll-frequency-before-2026-09-09.log`; the post-deployment
snapshot is `/tmp/mac-trackball-fix-scroll-frequency-after-2026-09-09.log`. All 39 post-deployment raw reports paired
and routed live, with zero fallback, sign mismatch, overflow, reject, carry drop, display failure/recovery or tap
disable. First output was `0.94–13.56 ms` (median `6.93 ms`), queue median `0.67 ms`, and 557 callbacks retained
the `8.333 ms` maximum gap. Physical reversals `12` at `09:01:33.999` and `13` at `09:01:34.983` logged the new
action after `374.995 ms` and `984.013 ms`, retaining/updating cadence to `216.716 ms` and `600.364 ms` instead of
clearing it. Both discarded all old-sign carry and opened at `439.419 px/s` with the existing `35.153 px` distance.
Sequence `19`, after `6.900 s`, correctly cleared expired cadence. This verifies the new branch on hardware;
subjective feel and uncaptured horizontal/effect/display/application cases remain pending.

## 2026-09-11 — correlation misses must not mix CG acceleration into raw frequency

Symptom/evidence: during the slow-start investigation, current unified telemetry from helper PID `803` contained
84 live reports between `09:09:57` and `09:18:26`. First output was `0.68–15.66 ms` (median approximately `6 ms`),
with an `8.333 ms` maximum recorded callback gap and no recorded display recovery/start failure or tap disable.
The normal-distance opening policy was active. Arc sequence `3846` at `09:17:19.064` followed `429.016 ms` of
physical-input silence, received `35.153 px`, and produced output in `7.34 ms`. These records measure helper
delivery, not application presentation or the cause of physical silence.

At `09:17:19.123`, sequence `3848` missed raw correlation and used `source=cg-line-fallback units=3`. The raw-count
model interpreted those accelerated CG units over `28.013 ms` as `107.095 counts/s`, raised the filter from
`27.966` to `95.284`, and hit `27,846.950 px/s` output. Sequence `3849` recovered HID, but retained a `54.244`
filtered rate against `40.021` raw. This is a confirmed source-domain mismatch and filter contamination. Its
association with the subjective slow-start complaint remains inferred; the capture does not prove why pairing missed.

Change (`RingInputCorrelator.h`, `Scroll.m`, `RingMotionModelTests.c`): require paired nonzero HID units for live
raw-model eligibility. A miss logs route fallback `reason=raw-correlation-miss` and immediately continues through
the existing CG-aware legacy pipeline. The existing generation-ordered handoff clears both raw axis states before
legacy output; repeated misses stay on legacy without repeated live resets. The next paired report cancels legacy
and opens clean raw state. Shadow prediction also excludes misses so its raw frequency cannot be contaminated.
Correlation itself still returns the original CG fallback units without waiting or discarding the physical report.

This supersedes the earlier acceptance of CG-line fallback inside the raw live model: the new captured saturation
demonstrates that those domains cannot share its acceleration/filter state. No report is held for pairing, no raw
count is guessed from CG magnitude, and no distance reservoir or confirmation gate is introduced. Opening distance,
unsigned slow-reversal frequency, same-axis cancellation, paired Wheel/Pan overlap, and output caps are unchanged.

Verification: the full `./dev.sh scroll-tests` suite passes, including cadence, display lifecycle, output policy,
correlator, motion/plane/property/refresh, all captured traces, and seven analyzer tests. New captured-parameter
coverage demonstrates the old `107 counts/s` contamination and saturation, preserves full fallback magnitudes for
legacy, exercises repeated misses and both signs/axes, clears both axes on handoff, rejects an old generation,
and verifies clean immediate raw re-entry and faster follow-up. These pure checks do not simulate macOS posting.
`git diff --check` and `./dev.sh build` pass. The first sandboxed build could not write existing Swift/Clang caches;
the normal-cache retry completed with `BUILD SUCCEEDED` and existing unrelated warnings.

Remaining tradeoff/manual verification: compatibility handoff discards bounded old motion on both axes and the next
paired report begins at normal opening speed. Repeated intermittent pairing can therefore cause discontinuities,
especially during independent-axis overlap. Physical miss/re-entry, sparse and fast input, active/paused reversal,
stop/rebound, target/effect changes, each available display and the wider application matrix remain required; no
physical cure for the subjective complaint is claimed from the model tests.

Deployment: `./dev.sh run` completed with `BUILD SUCCEEDED` and restarted the helper as PID `73052`.
Fresh physical Readdown telemetry on display `3` confirms ring-live output: sequence `17` at `09:28:29.764`
reopened after `1161.998 ms` with `35.153 px`, `439.419 px/s` impulse velocity and `10.74 ms` first output.
Sequence `18` reversed after `2072.965 ms`, cleared all opposite carry, and reached output in `12.84 ms`;
sequence `19` accelerated on its `63.988 ms` follow-up. Recorded callbacks retained an `8.333 ms` maximum gap.
These are adjacent-path physical checks; a post-deployment correlation miss has not yet been verified.

## Required regression pass

For every material scroll change, test the affected case plus adjacent behaviors:

1. Fresh single slow report: visible response on the first display frame.
2. Extremely slow repeated reports: continuous glide without event-three activation.
3. Slow to fast: acceleration and smoothness blend immediately on the new report.
4. Fast to slow: no velocity notch, delayed reservoir, or long unwanted tail.
5. Stop after fast motion: no same-direction secondary burst.
6. Stop with hardware rebound: no amplified opposite burst.
7. Deliberate reversal during active motion: old coast stops and the first opposite report is delivered.
8. Deliberate slow reversal after a pause: no timer-based dead zone.
9. Scroll after an idle/parked display: no need to move the mouse first.
10. App switch and content boundary: new target responds and no old phase leaks across.
11. Each attached display, including scrolling without moving the pointer first.
12. Horizontal scrolling, zoom/effect paths, Safari rubber-banding, Chromium, Telegram, Finder, and VS Code/Xcode.

After testing, inspect:

- no unexplained `MFSCROLL_TAP` disable;
- normal input queue time;
- first-output latency within roughly one or two display frames;
- output cadence while animation is actively producing pixels;
- recovery records only when callbacks were actually stale;
- no distance retained from a cancelled direction or previous target.

## How to add an entry

Append, do not rewrite history. Include:

- date and concise symptom;
- exact log timestamps/records and helper PID when available;
- confirmed root cause versus inference;
- files/commit involved;
- behavior intentionally preserved;
- commands and manual cases used for verification;
- known ambiguity or remaining risk.
