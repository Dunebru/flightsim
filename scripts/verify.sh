#!/usr/bin/env bash
# verify.sh: the project's CI-style gate. Regenerates the Xcode project, runs every test suite,
# builds the app, installs and launches it on the iPhone and iPad simulators, checks it is still
# running after launch, and saves screenshots. Exits non-zero on the first failure.
#
# Usage:
#   scripts/verify.sh            simulator gate
#   scripts/verify.sh --device   also build, install and launch on a connected iPhone
#   FLIGHT_DEVICE_ID=<udid>      pick a specific device (default: first connected iPhone)
#
# Full logs go to artifacts/verify/<timestamp>/. Only status lines are printed.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.shreyas.flightsim"
SCHEME="Flight"
IPHONE_SIM="iPhone 17 Pro"
IPAD_SIM="Flight iPad"
LAUNCH_SETTLE_SECONDS=4
OUT="artifacts/verify/$(date +%Y%m%d-%H%M%S)"
DERIVED="build/dd"
WITH_DEVICE=0

for arg in "$@"; do
  case "$arg" in
    --device) WITH_DEVICE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

mkdir -p "$OUT"
START=$(date +%s)
# No silent exits: any command that fails outside run_logged reports where it happened.
trap 'rc=$?; echo "VERIFY FAILED (exit $rc) at line $LINENO: $BASH_COMMAND" >&2; exit $rc' ERR

step() { printf '==> %s\n' "$1"; }

# run_logged <log-name> <command...>: runs quietly, prints the log tail and exits on failure.
run_logged() {
  local name="$1"; shift
  if "$@" >"$OUT/$name.log" 2>&1; then
    printf '    ok: %s\n' "$name"
  else
    printf '    FAILED: %s (full log: %s/%s.log)\n' "$name" "$OUT" "$name"
    grep -nE "error:|✘|failed|FAILED|fatal" "$OUT/$name.log" | head -20 | cut -c1-220 || true
    echo "    --- last lines ---"
    tail -n 15 "$OUT/$name.log" | cut -c1-220
    exit 1
  fi
}

settle() { perl -e "select(undef,undef,undef,$1)"; }

# capture <udid> <file> <log-name>: simctl screenshots occasionally fail right after a launch
# ("Failed to create image data"), most likely while the simulator is still rotating into
# landscape. Retry up to three times, two seconds apart, then fail loudly.
capture() {
  local attempt
  for attempt in 1 2 3; do
    if xcrun simctl io "$1" screenshot "$2" >"$OUT/$3.log" 2>&1; then
      [ "$attempt" -gt 1 ] && printf '    ok: %s (attempt %s)\n' "$3" "$attempt" || printf '    ok: %s\n' "$3"
      return
    fi
    settle 2
  done
  printf '    FAILED: %s after 3 attempts (log: %s/%s.log)\n' "$3" "$OUT" "$3"
  tail -n 3 "$OUT/$3.log" | cut -c1-200
  exit 1
}

# test_summary <log>: counts Swift Testing runs and confirms none failed.
test_summary() {
  local log="$1" runs failed
  runs=$(grep -c "Test run with" "$log" || true)
  failed=$(grep "Test run with" "$log" | grep -vc " passed" || true)
  if [ "$runs" -eq 0 ] || [ "$failed" -ne 0 ]; then
    echo "    FAILED: $runs test runs, $failed not passing"; exit 1
  fi
  printf '    %s test runs, all passed (%s tests)\n' "$runs" \
    "$(grep -oE 'Test run with [0-9]+ test' "$log" | awk '{s+=$4} END {print s}')"
}

sim_udid() {
  xcrun simctl list devices available | grep -F "    $1 (" | head -1 | grep -oE '[0-9A-F-]{36}'
}

# run_on_sim <name> <label>: boot, install, launch, confirm alive, screenshot.
run_on_sim() {
  local name="$1" label="$2" udid
  udid=$(sim_udid "$name") || { echo "    FAILED: simulator '$name' not found"; exit 1; }
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  run_logged "boot-$label" xcrun simctl bootstatus "$udid" -b
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  run_logged "install-$label" xcrun simctl install "$udid" "$DERIVED/Build/Products/Debug-iphonesimulator/Flight.app"
  run_logged "launch-$label" xcrun simctl launch "$udid" "$BUNDLE_ID"
  settle "$LAUNCH_SETTLE_SECONDS"
  if ! xcrun simctl spawn "$udid" launchctl list | grep -F "$BUNDLE_ID" | grep -qE '^[0-9]+'; then
    echo "    FAILED: app not running on $name ${LAUNCH_SETTLE_SECONDS}s after launch (crashed?)"; exit 1
  fi
  echo "    ok: running on $name"
  capture "$udid" "$OUT/$label.png" "screenshot-$label"
  # The app is landscape-only; a simulator held in portrait captures it sideways. Rotate upright.
  local w h
  w=$(sips -g pixelWidth "$OUT/$label.png" | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$OUT/$label.png" | awk '/pixelHeight/ {print $2}')
  if [ "$h" -gt "$w" ]; then sips -r 270 "$OUT/$label.png" >/dev/null; fi

  # Second screen: the in-flight HUD, opened directly by a launch argument.
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  run_logged "launch-hud-$label" xcrun simctl launch "$udid" "$BUNDLE_ID" -FlightStartScreen hud
  settle "$LAUNCH_SETTLE_SECONDS"
  if ! xcrun simctl spawn "$udid" launchctl list | grep -F "$BUNDLE_ID" | grep -qE '^[0-9]+'; then
    echo "    FAILED: HUD not running on $name ${LAUNCH_SETTLE_SECONDS}s after launch (crashed?)"; exit 1
  fi
  capture "$udid" "$OUT/$label-hud.png" "screenshot-hud-$label"
  w=$(sips -g pixelWidth "$OUT/$label-hud.png" | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$OUT/$label-hud.png" | awk '/pixelHeight/ {print $2}')
  if [ "$h" -gt "$w" ]; then sips -r 270 "$OUT/$label-hud.png" >/dev/null; fi
  # A frozen simulator display returns the same stale frame for every capture while the app
  # process looks healthy (seen 2026-11-07). The menu and the HUD are different screens, so
  # identical captures mean the evidence is invalid.
  if cmp -s "$OUT/$label.png" "$OUT/$label-hud.png"; then
    echo "    FAILED: menu and HUD screenshots on $name are identical (stale simulator display?)"; exit 1
  fi
  echo "    ok: HUD running on $name (screenshots differ)"
}

device_udid() {
  if [ -n "${FLIGHT_DEVICE_ID:-}" ]; then echo "$FLIGHT_DEVICE_ID"; return; fi
  local json="$OUT/devices.json"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || return 1
  /usr/bin/python3 -I - "$json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
# Physical iPhones only: a booted simulator also reports tunnelState "connected" (this picked
# the iPhone 17 Pro simulator as "the device" until 2026-11-07). A paired phone on Wi-Fi reports
# "disconnected" until devicectl connects on demand; "unavailable" means unreachable.
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if (hw.get("deviceType") == "iPhone" and hw.get("reality") == "physical"
            and conn.get("tunnelState") in ("connected", "disconnected")
            and conn.get("transportType") not in (None, "")):
        print(hw["udid"]); break
else:
    sys.exit(1)
PY
}

# ---------------------------------------------------------------------------

step "Fetch pinned assets"
run_logged fetch-assets scripts/fetch-assets.sh

step "Generate Xcode project"
run_logged xcodegen xcodegen generate --quiet

step "FlightKit tests (macOS host)"
run_logged flightkit-tests swift test --package-path Packages/FlightKit
test_summary "$OUT/flightkit-tests.log"

step "Tools tests (macOS host)"
run_logged tools-tests swift test --package-path Tools
test_summary "$OUT/tools-tests.log"

step "Build app for iOS Simulator"
run_logged app-build-sim xcodebuild -project Flight.xcodeproj -scheme "$SCHEME" \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED" build
WARNINGS=$( { grep -E "warning: " "$OUT/app-build-sim.log" || true; } | { grep -v appintentsmetadataprocessor || true; } | sort -u | wc -l | tr -d ' ')
echo "    compiler warnings: $WARNINGS"

step "Run on $IPHONE_SIM"
run_on_sim "$IPHONE_SIM" iphone-sim

step "Run on $IPAD_SIM"
run_on_sim "$IPAD_SIM" ipad-sim

if [ "$WITH_DEVICE" -eq 1 ]; then
  step "Physical device"
  UDID=$(device_udid) || { echo "    FAILED: no connected iPhone (unlock it, same Wi-Fi or cable)"; exit 1; }
  run_logged app-build-device xcodebuild -project Flight.xcodeproj -scheme "$SCHEME" \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
  APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/Flight.app"
  # The bundle must be a fresh device build, not a stale one or a simulator slice.
  if ! vtool -show-build "$APP_PATH/Flight" 2>/dev/null | grep -q "platform IOS$"; then
    echo "    FAILED: $APP_PATH/Flight is not an iOS device binary"; exit 1
  fi
  if [ "$(stat -f %m "$APP_PATH/Flight.debug.dylib" 2>/dev/null || stat -f %m "$APP_PATH/Flight")" -lt "$START" ]; then
    echo "    FAILED: device build at $APP_PATH is older than this run (stale product)"; exit 1
  fi
  echo "    device: $(xcrun devicectl list devices 2>/dev/null | grep "$UDID" | awk '{print $1, $(NF-3), $(NF-2), $(NF-1)}' | head -1)"
  # An interrupted install can leave the phone refusing updates ("needs to be updated by the
  # developer"); seen 2026-11-07. Uninstall our own app and retry once, and say so.
  if ! xcrun devicectl device install app --device "$UDID" "$APP_PATH" >"$OUT/install-device.log" 2>&1; then
    echo "    install failed; uninstalling com.shreyas.flightsim and retrying once"
    xcrun devicectl device uninstall app --device "$UDID" "$BUNDLE_ID" >>"$OUT/install-device.log" 2>&1 || true
    run_logged install-device-retry xcrun devicectl device install app --device "$UDID" "$APP_PATH"
  else
    echo "    ok: install-device"
  fi
  run_logged launch-device xcrun devicectl device process launch --terminate-existing \
    --device "$UDID" "$BUNDLE_ID"
  settle "$LAUNCH_SETTLE_SECONDS"
  run_logged processes-device xcrun devicectl device info processes --device "$UDID"
  if ! grep -q "Flight.app/Flight" "$OUT/processes-device.log"; then
    echo "    FAILED: app not running on device ${LAUNCH_SETTLE_SECONDS}s after launch"; exit 1
  fi
  echo "    ok: running on device"
fi

echo "VERIFY PASSED in $(( $(date +%s) - START ))s. Artifacts: $OUT"
