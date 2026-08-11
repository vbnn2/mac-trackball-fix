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
