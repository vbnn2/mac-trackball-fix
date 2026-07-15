#!/bin/bash
#
# dev.sh — build/run/test helper for mac-trackball-fix
#
# The Helper is the process that actually does the input remapping. It CANNOT run
# standalone: Locator.m asserts that it lives inside the main app bundle at
#   Mac Mouse Fix.app/Contents/Library/LoginItems/Mac Mouse Fix Helper.app
# So every flow here builds the *App* scheme (which embeds the Helper) and then runs
# the embedded Helper binary directly. That skips launchd/SMAppService entirely, which
# is what makes fast iteration possible.
#
# Usage: ./dev.sh <command>
#   build     Build the app (embeds the Helper)
#   run       Build, then run the embedded Helper in the foreground with live logs
#   app       Build, then launch the main app GUI
#   test      Build + run the "Tests" scratch app (there is NO unit test suite)
#   install   Build, then copy the app to /Applications (stable path for permissions)
#   stop      Kill any running Helper / app instances
#   logs      Stream the App's + Helper's own logs live (MMF_LOG_ALL=1 to include system logs)
#   logs-dump [since]  Show past logs (default 15m). Sparse: os_log doesn't persist info/debug.
#   clean     Wipe DerivedData for this project

set -euo pipefail

PROJECT="Mouse Fix.xcodeproj"
APP_SCHEME="App"            # scheme name; builds the "Mac Mouse Fix" target
APP_NAME="Mac Mouse Fix"    # product name (.app on disk)
HELPER_NAME="Mac Mouse Fix Helper"
TEST_SCHEME="Tests"
CONFIG="${CONFIG:-Debug}"

cd "$(dirname "$0")"

# Ask xcodebuild where the products actually land, rather than hardcoding the
# DerivedData hash (it changes if the project path changes).
build_dir() {
  xcodebuild -project "$PROJECT" -scheme "$APP_SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}'
}

APP_PATH() { echo "$(build_dir)/$APP_NAME.app"; }
HELPER_BIN() { echo "$(APP_PATH)/Contents/Library/LoginItems/$HELPER_NAME.app/Contents/MacOS/$HELPER_NAME"; }

do_build() {
  echo "==> Building '$APP_SCHEME' ($CONFIG)…"
  # The App scheme has the Helper as a dependency and embeds it, so this builds both.
  xcodebuild -project "$PROJECT" -scheme "$APP_SCHEME" -configuration "$CONFIG" \
    -destination 'platform=macOS' build \
    | grep -E "error:|warning: (unused|unin)|BUILD (SUCCEEDED|FAILED)" || true
  # xcodebuild's exit code is swallowed by the pipe above; re-check the product exists.
  [ -x "$(HELPER_BIN)" ] || { echo "!! Build did not produce a Helper binary"; exit 1; }
}

do_stop() {
  echo "==> Stopping running instances…"
  # Match on the binary name; -f so we catch the DerivedData path too.
  pkill -f "$HELPER_NAME" 2>/dev/null || true
  pkill -f "/$APP_NAME.app/Contents/MacOS/" 2>/dev/null || true
  sleep 0.3
}

case "${1:-run}" in
  build)
    do_build
    echo "==> App: $(APP_PATH)"
    ;;

  run)
    # Must run in the FOREGROUND. UNIXSignals.m:133 asserts that SIGTERM's previous
    # disposition is SIG_DFL, and deliberately rejects SIG_IGN too. Bash sets SIGINT/SIGQUIT
    # to SIG_IGN for backgrounded jobs, and exec inherits that -> instant assertion failure:
    #   Assertion failed: (!signal_handler_did_exist), UNIXSignals.m, line 133
    # So `./dev.sh run &` will crash. Run it in its own terminal instead.
    do_build
    do_stop
    echo "==> Running Helper (Ctrl-C to stop)"
    echo "    $(HELPER_BIN)"
    echo "    NOTE: needs Accessibility permission — grant it to this binary when prompted."
    echo "    NOTE: run this in the foreground; './dev.sh run &' trips an assert in UNIXSignals.m."
    echo
    exec "$(HELPER_BIN)"
    ;;

  app)
    do_build
    do_stop
    echo "==> Launching app GUI…"
    open "$(APP_PATH)"
    ;;

  test)
    # There is NO XCTest suite in this project. The "Tests" target is a scratch *app*
    # (product-type.application, see Tests/main.m) used to poke at APIs by hand — so it
    # gets Run, not Tested. `xcodebuild test` fails with "not configured for the test
    # action", which is expected, not a misconfiguration to fix.
    echo "==> Building + running the 'Tests' scratch app…"
    echo "    (This project has no unit tests; this is a manual playground target.)"
    xcodebuild -project "$PROJECT" -scheme "$TEST_SCHEME" -configuration "$CONFIG" \
      -destination 'platform=macOS' build \
      | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
    open "$(build_dir)/$TEST_SCHEME.app"
    ;;

  install)
    do_build
    do_stop
    echo "==> Installing to /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$(APP_PATH)" /Applications/
    echo "==> Installed. Launching…"
    open "/Applications/$APP_NAME.app"
    ;;

  logs)
    # How MMF logging actually works (the CocoaLumberjack setup in Logging.m is dead code,
    # sitting inside an `#if 0`; kMFOSLogSubsystem is never registered):
    #   Logging.h:49-52 redefines DDLogError/Warn/Info/Debug to os_log_with_type(OS_LOG_DEFAULT,…).
    #   OS_LOG_DEFAULT carries NO subsystem and NO category, so there is nothing app-specific to
    #   filter on — `--predicate 'subsystem == "com.nuebling.mac-mouse-fix"'` matches zero lines
    #   from this build. (It DOES match the official MMF release, which still uses Lumberjack —
    #   an easy way to get fooled into reading another copy's logs.)
    #
    # Hence filter on senderImagePath: the image that emitted the line. MMF's own DDLog calls come
    # from the MMF binary; CoreFoundation/AppKit/XPC noise comes from their own dylibs. This keeps
    # ~600 real lines instead of ~3-10k, and beats `NOT subsystem BEGINSWITH "com.apple"`, which
    # still lets libsystem_info et al. through.
    #
    # `--level debug` is REQUIRED: without it os_log drops info+debug, which is nearly all of
    # MMF's logging (DDLogInfo/DDLogDebug), leaving an almost-empty stream.
    #
    # Note on <private>: os_log redacts %@ arguments, so many lines read "Set remaps to: <private>".
    # To unredact (needs root, resets on reboot):
    #     sudo log config --mode "private_data:on"
    if [ "${MMF_LOG_ALL:-0}" = "1" ]; then
      PREDICATE='process CONTAINS "Mac Mouse Fix"'
      echo "==> Streaming ALL logs from the MMF processes, incl. system frameworks (noisy)…"
    else
      PREDICATE='senderImagePath CONTAINS "Mac Mouse Fix"'
      echo "==> Streaming MMF's own logs (App + Helper). Ctrl-C to stop…"
      echo "    (MMF_LOG_ALL=1 ./dev.sh logs  to also include system framework logs)"
    fi
    echo
    exec log stream --level debug --style compact --predicate "$PREDICATE"
    ;;

  logs-dump)
    # Past logs rather than a live stream. os_log does NOT persist info/debug to disk, so this
    # shows far less than `logs` does live — a fallback for "it already broke and I had no
    # stream running", not a replacement.
    SINCE="${2:-15m}"
    echo "==> Dumping MMF logs from the last $SINCE…"
    echo "    NOTE: os_log doesn't persist info/debug, so this is sparse by design."
    echo "    For the full picture run './dev.sh logs' in another tab and reproduce the issue."
    echo
    exec log show --last "$SINCE" --info --debug --style compact \
      --predicate 'senderImagePath CONTAINS "Mac Mouse Fix"'
    ;;

  stop)
    do_stop
    ;;

  clean)
    echo "==> Cleaning…"
    xcodebuild -project "$PROJECT" -scheme "$APP_SCHEME" clean >/dev/null
    rm -rf ~/Library/Developer/Xcode/DerivedData/Mouse_Fix-*
    echo "==> Clean."
    ;;

  *)
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
