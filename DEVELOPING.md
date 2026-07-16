# Developing mac-trackball-fix

A fork of [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) (MMF), retargeted at the
Kensington Expert Mouse TB800 trackball.

> **License note:** the MMF License lets you do anything you want with the source privately.
> Its restrictions only kick in if you *publish* a compiled program. If this fork ever ships,
> re-read `License` — the monetization/licensing clauses are the part that matters.

---

## 1. Quick start

Requirements: macOS 12 or later, Apple Silicon for the provided script, and Xcode with the macOS
SDK and Command Line Tools installed.

```bash
./dev.sh run                              # build + run the Helper with live logs
```

Then grant **Accessibility** permission when macOS prompts (System Settings → Privacy &
Security → Accessibility). Without it the Helper starts but installs no event tap, so
nothing happens and you get no error.

`./dev.sh` commands: `build`, `run`, `app`, `test`, `install`, `publish-check`, `publish`,
`logs`, `logs-dump`, `stop`, `clean`.

> **Run it in the foreground.** `./dev.sh run &` dies instantly with
> `Assertion failed: (!signal_handler_did_exist), UNIXSignals.m, line 133`. That's not a bug in
> the script: `UNIXSignals.m:133` asserts SIGTERM's previous disposition is `SIG_DFL` and
> deliberately rejects `SIG_IGN` — and bash sets `SIGINT`/`SIGQUIT` to `SIG_IGN` for
> backgrounded jobs, which `exec` inherits. Give it its own terminal tab.

### Publishing

`./dev.sh publish` creates an arm64 Release archive, signs it with a Developer ID Application
certificate, submits it to Apple for notarization, staples the ticket, verifies it with Gatekeeper,
and writes a distributable ZIP plus SHA-256 checksum under `dist/publish-<timestamp>/`.

Prerequisites:

1. Install a `Developer ID Application` certificate and its private key in the login Keychain.
2. Store notarization credentials in the Keychain:

   ```bash
   xcrun notarytool store-credentials mac-trackball-fix \
     --apple-id you@example.com \
     --team-id YOUR_TEAM_ID
   ```

3. Validate local prerequisites, then publish:

   ```bash
   NOTARY_PROFILE=mac-trackball-fix ./dev.sh publish-check
   NOTARY_PROFILE=mac-trackball-fix ./dev.sh publish
   ```

Optional environment variables:

- `DEVELOPER_ID_APPLICATION`: exact Keychain identity when more than one Developer ID certificate
  is installed. The script otherwise selects the first matching identity.
- `PUBLISH_TEAM_ID`: overrides the Team ID derived from the certificate name.
- `PUBLISH_DIR`: overrides the timestamped output directory.
- `NOTARY_TIMEOUT`: notarization wait timeout, default `30m`.

The command produces the signed and notarized artifact locally. It does not create a GitHub release,
upload files, generate a Sparkle appcast, or sign a Sparkle update feed. No Apple credentials are
stored in the repository. The existing Release build phase increments `CFBundleVersion` in both
source Info.plists; keep that version bump when the release is accepted.

---

## 2. The two processes (and why running it failed)

MMF is **two** executables:

| Process | Role |
|---|---|
| **Mac Mouse Fix.app** (`App/`) | The GUI. Writes config, enables/disables the Helper. Does no input handling. |
| **Mac Mouse Fix Helper.app** (`Helper/`) | The real driver. Owns the CGEvent taps, remapping, scroll engine. |

The Helper is **embedded inside the main app** at:

```
Mac Mouse Fix.app/Contents/Library/LoginItems/Mac Mouse Fix Helper.app
```

**The Helper cannot run standalone.** `Locator.m:39` asserts `mainAppBundle != nil`, and
resolves the main app by walking *up* from its own bundle path. Run the Helper straight out
of `Build/Products/Debug/Mac Mouse Fix Helper.app` and it dies immediately:

```
Assertion failed: (mainAppBundle != nil), function +[Locator mainAppBundle], file Locator.m, line 39.
```

This is almost certainly the "it requires Helper or something" failure. The fix is to build
the **`App`** scheme (which embeds the Helper) and run the *embedded* copy — which is exactly
what `./dev.sh run` does. It bypasses launchd/SMAppService entirely, so there's no
enable-in-the-GUI dance and no 10-second launchd restart throttle.

### Schemes

Scheme names ≠ target names. Targets are `Mac Mouse Fix` / `Mac Mouse Fix Helper`; the
schemes you build are:

- **`App`** — builds the app **and embeds the Helper**. This is the one to use.
- **`Helper - Direct`** — `launchStyle="0"`, launches the Helper directly from Xcode.
- **`Helper - Launchd start` / `Helper - External Start`** — `launchStyle="1"`: Xcode *waits*
  for launchd (or you) to start the Helper, then attaches. Useful for debugging the real
  launchd-managed install; overkill for day-to-day work.

### The upstream `./run` script

The upstream `./run` script is **not** the build system — it's a localization/markdown tool.
It's also doubly broken here:

1. `mac-mouse-fix-scripts/` is a git submodule that ships empty → `run.py` not found.
2. `run.py:189` asserts the checkout directory is named `mac-mouse-fix`. This fork is
   `mac-trackball-fix`, so it throws `AssertionError` even after the submodule is restored.

Use `./dev.sh` / `xcodebuild` for building. The `mac-mouse-fix-scripts` submodule is not required
for normal builds; initialize it only if you need to repair and use the upstream localization
workflow.

---

## 3. Testing

**There is no automated test suite.** Worth knowing before you plan any work:

- The **`Tests`** target is `product-type.application` — a scratch playground app
  (`Tests/main.m`, `Tests/FixDockSwipes.m`) that you *Run*, not *Test*.
  `xcodebuild test -scheme Tests` fails with *"not configured for the test action"*. Expected.
- The only XCTest bundle is **`Localization Screenshot Taker`**, which exists to screenshot
  localized UI — not to test behavior.

So verification for scroll/button work is **manual**: run the Helper, use the trackball, read
the logs. Debug builds log scroll internals via `DDLogDebug` (see §5).

Minimum regression pass for input changes:

1. Slow and fast vertical ring scrolling, including stopping and resuming within 500 ms.
2. Horizontal scrolling and an immediate direction reversal at a content boundary.
3. Normal zoom and **Invert Zoom Direction**.
4. **Scroll & Zoom Mode** and **Zoom Mode**, exiting with left, right, and another mouse button.
5. Global and per-app button mappings while switching the frontmost application.
6. Export settings, change a visible setting, import, and confirm both the UI and Helper reload.
7. If multiple displays are attached, start a fresh scroll on each display without moving the
   pointer first.

---

## 4. Code map

```
App/
  UI/Main/Tabs/
    GeneralTabController.swift  Config import/export; update UI is disabled
    ScrollTabController.swift   Trackball tuning and direction controls
    ButtonTab/                  Global and per-app remap editor
    AboutTabController.swift    Header-only About tab
Helper/
  AccessibilityCheck.m       Entry point; polls for Accessibility, then boots everything
  HelperState.swift          Frontmost-app overrides and latched trackball modes
  Core/
    Scroll/                  ← the scroll engine
      Scroll.m               Event tap + main processing pipeline (~1300 lines, the core)
      ScrollAnalyzer.m       Tick timing plus smoothed units-per-tick
      ScrollModifiers.swift  Maps keyboard/button mods → input/effect modifications
      ScrollUtility.m        Axis + direction helpers
    Buttons/                 Click/hold state machine (ClickCycle.swift, Buttons.swift)
    Actions/Actions.m        ← executes a remap's action array (where new actions go)
    Modifiers/               Keyboard + button modifier state
    Remap/                   Remap table lookup & swizzling
    Config/ScrollConfig.swift  All scroll tuning knobs, acceleration curves
    Touch/TouchSimulator     Synthesizes trackpad gestures (zoom, swipe, dock swipe)
  Utility/ModificationUtility.m  postMouseButtonClicks:, postMouseButton:down:
Shared/
  Constants.h                Bundle IDs, action-dict string keys, launchd labels
  Config/default_config.plist  Default remaps + scroll params
  Config/Config.m            Persistence, repair, and per-app override merging
  MessagePort/               App ↔ Helper IPC (CFMessagePort)
  HelperServices/            launchd / SMAppService registration
```

### Scroll pipeline (`Scroll.m`)

```
eventTapCallback()                     ← CGEventTap, kCGEventScrollWheel
  ├── records line + point deltas and rejects unsupported event types
  └── dispatch_async(_scrollQueue) → heavyProcessing()
        ├── ScrollUtility axisForVerticalDelta:horizontalDelta:  → picks ONE axis
        ├── ScrollAnalyzer → smoothed interval + line-delta units
        ├── velocity = units / interval
        ├── trackball tuning → pixels for this tick
        ├── Animator + drag/Bezier curve                         → smooth interpolation
        └── sendOutputEvents() → sendScroll() / TouchSimulator
```

### Fork feature map

| Feature | UI/config | Runtime implementation |
|---|---|---|
| Five scroll-tuning sliders | `ScrollTabController.swift`, `Scroll.tuning.*` | `ScrollConfig.swift`, `Scroll.m`, `ScrollAnalyzer.m` |
| Invert zoom / ball scroll | `Scroll.invertZoom`, `Scroll.invertBallScroll` | `Scroll.m`, `ModifiedDragOutputTwoFingerSwipe.m` |
| Scroll & Zoom / Zoom modes | Button action dictionaries | `HelperState.swift`, `Actions.m`, `Buttons.swift` |
| Shift + Primary Click | Remap effects table; optional `flags` key | `ModificationUtility.m`, `Actions.m` |
| Per-app button mappings | `AppOverrides.<bundleID>.Root.Remaps` | `RemapTableController.m`, `Config.m`, `HelperState.swift` |
| Config import/export | General tab | `GeneralTabController.swift`, `Config`, `MFMessagePort` |
| Header-only About tab | About tab | `AboutTabController.swift`, `FORCE_LICENSED` build flag |
| Disabled upstream updates | General/menu UI | `AppDelegate.m`, `CoolSUUpdater.m`, `SparkleUpdaterController.m` |

### Config and override behavior

The live config is a property list under:

```text
~/Library/Application Support/com.pixeption.mac-mouse-fix/config.plist
```

The main app owns edits and persistence; it sends `configFileChanged` over `MFMessagePort`, and the
Helper reloads the file. The old external-file FSEvent reload path is disabled, so copying a plist
over the live config without the reload/message sequence does not update a running Helper.

Per-app mappings are sparse overrides under `AppOverrides.<bundleID>.Root.Remaps`. They are merged
over the global remap table by trigger and modification precondition. `HelperState` follows
`NSWorkspace.didActivateApplicationNotification`, applies the frontmost app's merged config, and
reloads remaps. These are button overrides; scroll tuning remains global.

New config keys must be nil-tolerant. Existing configs are not automatically backfilled merely
because a key was added to `default_config.plist`. For the five tuning values, keep all three
fallback sources synchronized:

1. `Shared/Config/default_config.plist`
2. `Helper/Core/Config/ScrollConfig.swift`
3. `App/UI/Main/Tabs/ScrollTabController.swift`

### Rules for coding agents

- Build the `App` scheme so the Helper is embedded. Do not run the standalone Helper product.
- Use `./dev.sh`; do not treat the upstream `./run` localization tool as the build entry point.
- Preserve unrelated work in a dirty tree and keep fork changes marked with `Fork:` where the
  surrounding source uses that convention.
- Keep `PRODUCT_BUNDLE_IDENTIFIER`, `Shared/Constants.h`, `sm_launchd.plist`, URL metadata, and
  entitlement/keychain groups synchronized.
- Changes to config normally need both app-side UI/persistence and Helper-side reload/runtime
  handling. Confirm the IPC path rather than assuming the file watcher will reload it.
- Add user-facing strings to `Localization/Localizable.xcstrings`; programmatic UI still needs
  localization and Accessibility identifiers.
- Programmatic views inside the tab stacks need explicit vertical hugging. The tab controller
  measures content using a temporary 99999×99999 window, and flexible views otherwise produce a
  nonsense tab size.
- There is no behavioral XCTest suite. Do not report `xcodebuild test` as a valid verification
  command; use the manual regression pass above.
- Keep scroll-path logging scalar where possible. `%@` values are private-redacted by `os_log`.

---

## 5. Debugging

```bash
./dev.sh run                  # foreground Helper, logs straight to stdout
./dev.sh logs                 # stream a launchd-started Helper's logs (App + Helper)
MMF_LOG_ALL=1 ./dev.sh logs   # ...plus system frameworks (TCC / launchd / XPC issues)
./dev.sh logs-dump 30m        # past logs — sparse, see below
```

### How logging actually works (this is not obvious)

The CocoaLumberjack setup in `Logging.m` is **dead code** — it lives inside an `#if 0`, so
`kMFOSLogSubsystem` is never registered. What's live is `Logging.h:49-52`, which redefines
`DDLogError/Warn/Info/Debug` as `os_log_with_type(OS_LOG_DEFAULT, …)`.

Three consequences, each of which will silently give you an empty or misleading log:

1. **`OS_LOG_DEFAULT` has no subsystem and no category.** There is nothing app-specific to
   filter on. `--predicate 'subsystem == "com.nuebling.mac-mouse-fix"'` matches **zero** lines
   from this build. It *does* match the official MMF release (which still uses Lumberjack), so
   if a copy of upstream MMF is on the machine you can end up reading *its* logs and never
   notice. `./dev.sh logs` filters on `senderImagePath CONTAINS "Mac Mouse Fix"` instead —
   the image that emitted the line — which is both accurate and ~10x less noisy than
   filtering by process.
2. **`log stream --level debug` is required.** Without it os_log drops info+debug, i.e. nearly
   all of MMF's logging. The default stream looks almost empty and it is not obvious why.
3. **`log show` can't replace it.** os_log does not persist info/debug to disk, so
   `logs-dump` is sparse by design. To debug something, start `./dev.sh logs` in a second tab
   *first*, then reproduce.

### `<private>`

os_log redacts `%@` arguments, so you'll see `Set remaps to: <private>`. To unredact
(root, resets on reboot):

```bash
sudo log config --mode "private_data:on"
```

`Helper/Core/Config/DevToggles.h` has `MF_TEST` + `devToggles_C/_Lo/_Hi` — scratch globals for
live-tuning constants without rebuilding.

---

## 6. Fork-specific and local test-machine notes

The bundle-ID rules below apply to every checkout. The Trash, SteerMouse, and Karabiner observations
describe the current development machine and may become stale.

### Bundle ID drift — FIXED (it was not latent; it was the "can't enable" bug)

`project.pbxproj` had been re-signed to `com.pixeption.*` (team `TT89YA5782`) while
`Shared/Constants.h` still hardcoded the upstream `com.nuebling.*` identifiers. This was
originally noted here as latent and non-fatal. **That was wrong** — it was the reason the Helper
could not be enabled.

The mechanism: `FileMonitor.m:62` resolves the main app via

```objc
NSWorkspace URLForApplicationWithBundleIdentifier:kMFBundleIDApp   /// com.nuebling.mac-mouse-fix
```

Nothing on this machine has that bundle ID any more, so LaunchServices returned **nil**, and
`FileMonitor.m:64` reads nil as *"Mac Mouse Fix cannot be found on the system anymore"* →
`uninstallCompletely()` → trashes the Application Support config, removes the launchd plist, and
disables the Helper. `FileMonitor` watches the folder enclosing the app, so **every rebuild** fired
an FSEvent into that path and re-triggered it. The Helper disabled itself moments after enabling.

Now aligned to `com.pixeption.*` in:

- `Shared/Constants.h` — `kMFBundleIDApp`, `kMFBundleIDHelper`, `kMFLaunchdHelperIdentifierSM`
- `Shared/HelperServices/sm_launchd.plist` — `Label` (must match `kMFLaunchdHelperIdentifierSM`)
- `Helper/SupportFiles/Helper.entitlements` — keychain group (`App.entitlements` had already been
  changed; the Helper had not, so the two were in *different* keychain groups)
- `App/SupportFiles/Info.plist` — `CFBundleURLName`

Keep `Constants.h` in sync with `PRODUCT_BUNDLE_IDENTIFIER` — these constants are not cosmetic.

Note `kMFOSLogSubsystem` (`Logging.m:39`) is deliberately **not** renamed: it's inside an `#if 0`
and is dead code (see §5).

The many other `com.nuebling.*` strings in the tree are dispatch-queue labels
(`com.nuebling.mac-mouse-fix.buttons`, `.scroll`, …) and are cosmetic — they don't affect identity.

### A copy of official MMF 3.0.8 is in the Trash

`~/.Trash/Mac Mouse Fix.app` is the real upstream build (bundle ID `com.nuebling.mac-mouse-fix`,
signed by Noah Nuebling / team `LM5Z78756B`). Before the rename it collided with this fork: it
owns the launchd label `com.nuebling.mac-mouse-fix.helper` and the same CFMessagePort names, so
launchd would start *its* Helper (out of the Trash) instead of the fork's — that Helper then
saw itself in the Trash and quit, and `KeepAlive` respawned it in a loop.

After the rename the two no longer share a label, so this is harmless. It still holds an
Accessibility grant and a BTM record, so emptying the Trash is worthwhile hygiene.

### SteerMouse is installed

`jp.plentycom.boa.SteerMouse` is registered with launchd on this machine. It's another mouse
driver with its own event taps — a prime suspect for "MMF's remap didn't apply" or duplicated
scroll. Quit it when testing.

### Karabiner

Karabiner-Elements sits *upstream* of MMF's taps and is already used here to make the TB800's
extra buttons report as standard mouse buttons. So MMF sees Karabiner's post-remap view of the
device, not the raw hardware. Keep that in mind when a button "isn't detected".

---

## 7. Hardware: Kensington Expert Mouse TB800

Read off the live device (`ioreg -c IOHIDDevice -r -l`), not from a datasheet:

- **Vendor 0x047D (1149) / Product 0x8169 (33129)**, `"Expert Mouse TB800 EQ 2.4GHz"`, USB 2.4GHz receiver.
- Mouse collection, **Report ID 1**:

| Usage | Field | Range | Bits |
|---|---|---|---|
| GD 0x30 / 0x31 | X, Y | −32767…32767 | 16 |
| GD 0x38 | **Wheel** (scroll ring) | −127…127 | 8 |
| Consumer 0x238 | **AC Pan** (horizontal) | −127…127 | 8 |

Two conclusions that shaped the implemented scroll engine:

1. **No Resolution Multiplier (GD 0x48).** The TB800 does *not* negotiate HID hi-res
   scrolling, so macOS reports its scroll as **line-based, not continuous** —
   `kCGScrollWheelEventIsContinuous == 0`. MMF's tap therefore *does* process it.
   The "smooth" feel comes from the free-spinning ring emitting many reports quickly,
   and from **multi-unit deltas** (the 8-bit field carries far more than ±1) — not from
   pixel-precise scrolling.
2. **Wheel and AC Pan share Report ID 1**, although captured macOS events presented them as
   separate single-axis scroll events rather than diagonal events.

The receiver also exposes keyboard (page 7) and consumer (page 12) collections that
enumerate their full usage ranges — those are arrays, not real axes. Don't read the presence
of a usage number in that dump as a physical control.
