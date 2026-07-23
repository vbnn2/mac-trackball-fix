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
| `MFSCROLL_INPUT cont=1` | Synthetic continuous pixel output seen again by the event tap |
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
