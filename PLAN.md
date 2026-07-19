# Scroll Engine Stabilization Record

## Status

The scroll-engine continuation work is complete as of 2026-07-18. Real TB800 testing accepted the Regular
TouchAnimator path, and normal use confirmed that its current smooth-scroll behavior should be preserved.

The rejected display-synchronized target/reservoir experiment has been removed. It produced visible bursts from
sparse hardware reports and added a second animation lifecycle without improving the accepted path. There is now one
animated output pipeline to reset, reverse, rebind to a display, and snapshot across config changes.

## Final defaults

- Smoothness preset: `regular`
- Sensitivity: `0.10`
- Acceleration: `1.0` (`gamma = 1.2`)
- Maximum Speed: `0.50`
- Smoothness: `0.50`
- Slow Smoothness: `0.90`
- Adaptive Until: `0.125`
- Glide: `0.75`
- Fast Scroll: `0.0` and hidden from the UI

The seven visible tuning values must remain synchronized in:

1. `Shared/Config/default_config.plist`
2. `Helper/Core/Config/ScrollConfig.swift`
3. `App/UI/Main/Tabs/ScrollTabController.swift`

Existing user configs are not overwritten by repository defaults.

## Accepted behavior

The Regular path retains the hardware-tested behavior described in `DEVELOPING.md`:

- line-unit velocity and time-aware filtering;
- report-rate-independent maximum output;
- separately bounded first-report distance and overload carry;
- stronger release friction only near the speed ceiling;
- adaptive slow-speed smoothing with one-report late-tail protection;
- phase-less high-resolution wheel output for compatibility across Telegram and Chromium;
- immediate coast cancellation with undelayed reversal input;
- app-switch and display-rebinding safeguards;
- `MFSCROLL_LEGACY`, `MFSCROLL_OUTPUT`, `MFSCROLL_TAIL`, and `MFSCROLL_LATENCY` telemetry.

Zoom, rotate, pinch, swipe, precise, and quick-scroll effects continue through TouchAnimator and retain their existing
phase and curve behavior.

## Verification

Run after scroll-related changes:

```bash
git diff --check
plutil -lint Shared/Config/default_config.plist
./dev.sh build
```

Behavioral validation still requires the real device. Before a release, check slow/fast scrolling, abrupt stops,
direction reversal, horizontal scrolling, Safari rubber-banding, Chrome, Finder, VS Code/Xcode, zoom modes, app
switching, and each attached display. Use `./dev.sh logs-record` only when a specific regression needs telemetry.

Do not add another smoothing layer or revive the removed target follower without a new design motivated by a concrete,
captured regression.
