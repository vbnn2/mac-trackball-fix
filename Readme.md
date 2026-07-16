# Mac Trackball Fix

Mac Trackball Fix is a fork of
[Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix), tuned for the Kensington Expert
Mouse TB800 and similar free-spinning trackballs.

The app and helper binaries still use the upstream product name, **Mac Mouse Fix**. This repository
is an independent fork and does not use the upstream update channel.

## What changed from the original repository

### Trackball scrolling

- Reworked the scroll engine around the magnitude of the device's line deltas, rather than treating
  every event as a single mouse-wheel detent.
- Added trackball-tuned **Sensitivity**, **Acceleration**, **Smoothness**, **Glide**, and
  **Fast Scroll** controls.
- Increased the slow-scroll continuity window for sparse free-spinning ring input.
- Added independent **Invert Zoom Direction** and **Invert Ball Scrolling** settings.
- Fixed dropped direction-change ticks, stale display-link selection, and scroll events that could
  remain latched until unrelated pointer input.

### Trackball actions

- Added **Scroll & Zoom Mode**: the ball scrolls in any direction and the ring zooms until a mouse
  button is clicked.
- Added **Zoom Mode**: the ring zooms while the ball continues moving the pointer normally.
- Added a **Shift + Primary Click** action. The action format also supports other modifier flags.

### Configuration and UI

- Added per-app button mappings selected from the Buttons tab. Overrides follow the frontmost app
  and inherit untouched mappings from **All Apps**.
- Added **Export Settings…** and **Import Settings…** to the General tab. Import validates the
  plist and keeps a `config.backup.plist` copy of the previous settings.
- Reduced the About tab to app identity, version, and upstream attribution.
- Disabled Sparkle update checks so this fork cannot offer an incompatible upstream build.
- Aligned the app, helper, launchd, URL-scheme, entitlement, and keychain identifiers under
  `com.pixeption.*`.

### Development and distribution

- Added `dev.sh` for repeatable build, run, install, logging, cleanup, and manual-test workflows.
- Added an arm64 Developer ID signing and Apple notarization pipeline that produces a ZIP and
  SHA-256 checksum locally.

## Requirements

- macOS 12 or later
- Apple Silicon for the provided `dev.sh` workflow
- Xcode with the macOS SDK and Command Line Tools
- Accessibility permission for the embedded helper

The source license comes from Mac Mouse Fix and has special terms for distributing compiled builds.
Read [License](License) before publishing this fork.

## Build and run

Build the app and its embedded helper:

```bash
./dev.sh build
```

For fast input-driver development, run the embedded helper in the foreground:

```bash
./dev.sh run
```

Grant the helper Accessibility access in **System Settings → Privacy & Security → Accessibility**
when prompted. Keep `./dev.sh run` in the foreground; backgrounding it with `&` causes the helper's
signal-handler assertion to fail.

To launch the GUI or install a stable copy:

```bash
./dev.sh app
./dev.sh install
```

Useful commands:

| Command | Purpose |
|---|---|
| `./dev.sh build` | Build the `App` scheme, including the embedded helper |
| `./dev.sh run` | Build and run the embedded helper with foreground logs |
| `./dev.sh app` | Build and launch the GUI |
| `./dev.sh install` | Copy the built app to `/Applications` and launch it |
| `./dev.sh logs` | Stream live app/helper debug logs |
| `./dev.sh logs-dump 30m` | Show the limited logs persisted by macOS |
| `./dev.sh test` | Build and run the manual `Tests` playground app |
| `./dev.sh stop` | Stop running app/helper instances |
| `./dev.sh clean` | Clean the project and its DerivedData |
| `./dev.sh publish-check` | Validate signing and notarization prerequisites |
| `./dev.sh publish` | Create a signed, notarized arm64 distributable |

There is no automated behavioral test suite. Scroll and button changes must be verified with the
real device and live logs.

## Project structure

```text
App/                 macOS settings UI and helper lifecycle
Helper/              event taps, scrolling, gestures, actions, and remapping
Shared/              config, constants, IPC, resources, and shared utilities
Tests/               manual playground app; not an XCTest suite
Localization/        app localization catalog
Mouse Fix.xcodeproj  Xcode targets, schemes, signing, and build settings
dev.sh               supported development and publishing entry point
DEVELOPING.md        architecture, debugging, and coding-agent notes
```

See [DEVELOPING.md](DEVELOPING.md) before changing the input pipeline, config schema, app overrides,
signing identifiers, or build scripts.

## Upstream

This fork keeps the original Mac Mouse Fix architecture and attribution. For the general-purpose
application, documentation, and official releases, use the
[upstream project](https://github.com/noah-nuebling/mac-mouse-fix).
