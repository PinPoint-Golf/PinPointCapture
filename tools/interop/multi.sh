#!/bin/bash
# UC-6: three devices paired to one host at the same time.
#
# Codes are single-use and PPS reissues one only when a pairing completes, so the
# three cannot be captured up front. The test pairs a device, drops a marker in
# its Documents directory, and waits; this script sees the marker, captures the
# freshly published QR and writes it back.
#
# ⛔ RV 4.4c / 7.2b — each URI carries a PSK. It goes into the simulator's own
# container, is never echoed, and the whole handoff directory is removed at the end.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$HERE"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
DEST="platform=iOS Simulator,name=$SIM_NAME"

capture_uri() {
  local w shot uri
  w=$("$SCRATCH/winid" PinPoint 2>/dev/null | head -1 | cut -f1)
  [ -z "$w" ] && return 1
  shot=$(mktemp -t ppcp-multi).png
  screencapture -x -o -l"$w" -t png "$shot" 2>/dev/null
  uri=$("$SCRATCH/qrdecode" "$shot" 2>/dev/null | grep '^ppcp:' | head -1)
  rm -f "$shot"
  [ -n "$uri" ] && printf '%s' "$uri"
}

udid=$(xcrun simctl list devices booted -j | python3 -c "
import json,sys
for rt,l in json.load(sys.stdin)['devices'].items():
    for d in l:
        if d.get('state')=='Booted': print(d['udid']); raise SystemExit")
# ⛔ **Re-resolve every time.** `test-without-building` reinstalls the app, which
# gives it a NEW container UUID — so a path resolved before the run points at the
# previous install. The first attempt at this test watched the stale directory,
# never saw the test's marker, and reported that PPS had not republished. It had.
handoff_dir() {
  local c
  c=$(xcrun simctl get_app_container "$udid" org.pinpointstudio.capture data 2>/dev/null)
  [ -n "$c" ] && printf '%s' "$c/Documents/ppcp-handoff"
}
rm -rf "$(handoff_dir)" 2>/dev/null
echo "container resolved per-poll (it changes on reinstall)"

first=$(capture_uri) || { echo "no QR on screen — is the pairing panel visible?"; exit 1; }
echo "captured code 1"

testlog=$(mktemp -t ppcp-multi-test)
TEST_RUNNER_PPCP_PAIRING_URI="$first" \
xcodebuild test-without-building -project PinPointCapture.xcodeproj \
    -scheme PinPointCapture -configuration Debug -destination "$DEST" \
    -derivedDataPath build \
    -only-testing:PinPointCaptureTests/MultiDeviceTests \
    -default-test-execution-time-allowance 300 >"$testlog" 2>&1 &
testpid=$!

# Serve codes 2 and 3 as the test asks for them.
for want in 2 3; do
  served=0
  for _ in $(seq 1 120); do
    kill -0 $testpid 2>/dev/null || break
    handoff=$(handoff_dir)
    if [ -n "${handoff:-}" ] && [ -f "$handoff/want-$want.txt" ] \
       && [ ! -f "$handoff/uri-$want.txt" ]; then
      sleep 1                                   # let PPS publish the new code
      uri=$(capture_uri)
      if [ -n "${uri:-}" ]; then
        printf '%s' "$uri" > "$handoff/uri-$want.txt"
        echo "served code $want"; served=1; break
      fi
    fi
    sleep 0.5
  done
  [ $served -eq 0 ] && echo "⚠ never served code $want (test may have moved on or PPS did not republish)"
done

wait $testpid; rc=$?
echo
grep -E '^(MULTI|✘|✔ Test "Three)' "$testlog" | head -20
echo
echo "=== host panel now says ==="
w=$("$SCRATCH/winid" PinPoint | head -1 | cut -f1)
shot=$(mktemp -t ppcp-host).png
screencapture -x -o -l"$w" -t png "$shot" 2>/dev/null
"$SCRATCH/ocrtext" "$shot" 2>/dev/null | grep -viE '^$' | head -14
rm -f "$shot"
rm -rf "$(handoff_dir)" 2>/dev/null              # ⛔ the URIs carried PSKs
rm -f "$testlog"
exit $rc
