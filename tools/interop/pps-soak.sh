#!/bin/bash
# Soak the SHIPPING pairing path against PinPointStudio, N times.
#
# Each iteration re-captures the QR from the screen and decodes it, because the
# code expires every five minutes and may be single-use. PPS must be showing its
# pairing screen throughout.
#
# ⛔ RV 4.4c / 7.2b — the payload carries the PSK. It lives in a shell variable
# and an environment variable for the length of one xcodebuild invocation. It is
# never echoed, never written to a file, and the screen capture that carried it is
# deleted immediately after decoding.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$HERE"

N="${1:-10}"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
DEST="platform=iOS Simulator,name=$SIM_NAME"
OUT=$SCRATCH/pps-soak-results.tsv

echo "simulator: $SIM_NAME    iterations: $N"
echo -e "run\tverdict\tdetail" > "$OUT"
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null 2>&1 || true

# Read PPS's own words. ⛔ The client's verdict is a ONE-SIDED ORACLE: PPC can
# complete a handshake and believe it settled while the host logged a failure, and
# a soak that scored only the client would call that a pass. Captured before and
# after each dial so a message already on screen is not mistaken for a new one.
host_text() {
  local w shot
  w=$("$SCRATCH/winid" PinPoint 2>/dev/null | head -1 | cut -f1)
  [ -z "$w" ] && return 0
  shot=$(mktemp -t ppcp-host).png
  screencapture -x -o -l"$w" -t png "$shot" 2>/dev/null
  "$SCRATCH/ocrtext" "$shot" 2>/dev/null | grep -viE 'expires in|^$' | sort -u
  rm -f "$shot"
}

pass=0; fail=0; stale=0; noqr=0; disagree=0; limit=0
i=0
while [ $i -lt "$N" ]; do
  i=$((i+1))
  shot=$(mktemp -t ppcp-qr).png
  # ⚠ Capture PPS's WINDOW, not the display. It works while the window is behind
  # others, so the Simulator taking focus mid-run stops mattering; and nothing
  # else on the screen is captured, which is the right default for a tool that
  # grabs a picture of someone's desktop every thirty seconds.
  winid=$("$SCRATCH/winid" PinPoint 2>/dev/null | head -1 | cut -f1)
  if [ -n "$winid" ]; then
    screencapture -x -o -l"$winid" -t png "$shot" 2>/dev/null
  else
    screencapture -x -t png "$shot" 2>/dev/null      # fall back to the display
  fi
  uri=$("$SCRATCH/qrdecode" "$shot" 2>/dev/null | grep '^ppcp:' | head -1)
  rm -f "$shot"                       # ⛔ the capture carried the PSK

  # ⛔ **Never dial a code we have already spent.** The last run consumed the code
  # on iteration 1 and then re-presented it three times; PPS correctly rejected
  # each, and those rejections were my harness rather than a defect. A code is
  # single-use, so wait for a genuinely new one instead of manufacturing failures.
  if [ -n "$uri" ]; then
    sig=$(printf '%s' "$uri" | shasum | cut -c1-16)
    if [ "$sig" = "${lastsig:-}" ]; then
      waited=$((${waited:-0}+1))
      if [ $waited -le 20 ]; then
        printf "  run %2d/%s  code unchanged — waiting for a fresh one (%ds)\n" "$i" "$N" "$((waited*5))"
        sleep 5; i=$((i-1)); continue
      fi
      echo -e "$i\tSTALE_UNCHANGED\tPPS did not issue a new code within 100s" >> "$OUT"
      echo "  code never refreshed — stopping"; break
    fi
    lastsig=$sig; waited=0
  fi

  if [ -z "$uri" ]; then
    noqr=$((noqr+1))
    echo -e "$i\tNO_QR\tno ppcp: code on screen" >> "$OUT"
    printf "  run %2d/%s  no QR on screen (%d in a row)\n" "$i" "$N" "$noqr"
    # ⛔ Stop rather than spin. Two in a row means the code expired and PPS is
    # waiting on a human to click "Get new code" — every further iteration would
    # burn a minute to learn the same thing.
    [ $noqr -ge 2 ] && { echo "  code expired — stopping early"; break; }
    sleep 3; continue
  fi

  before=$(host_text)
  testlog=$(mktemp -t ppcp-soak)
  TEST_RUNNER_PPCP_PAIRING_URI="$uri" \
  xcodebuild test-without-building -project PinPointCapture.xcodeproj \
      -scheme PinPointCapture -configuration Debug -destination "$DEST" \
      -derivedDataPath build \
      -only-testing:PinPointCaptureTests/PairingSoakTests \
      -default-test-execution-time-allowance 120 >"$testlog" 2>&1
  rc=$?
  unset uri                           # out of the environment as soon as it is used

  # The outcome case is the finding — RV §4 routes six distinct failures.
  noqr=0
  outcome=$(grep -oE 'SOAK outcome=[a-zA-Z]+[^"]*' "$testlog" | head -1)
  detail=$(grep -oE 'SOAK (rendezvous|phase)=[^"]*' "$testlog" | head -2 | tr '\n' ' ')

  sleep 1                      # let PPS finish writing its line
  after=$(host_text)
  # Lines the host gained during this iteration.
  hostnew=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null \
            | grep -iE 'fail|error|alert|refus|reject|denied|cannot|unable' \
            | grep -viE 'device disconnected|link closed' \
            | tr '\n' ' ' | cut -c1-110)

  # ⛔ PPS holds ONE link at a time — adoptLink() refuses a second outright. That
  # refusal is a documented limit, not a pairing defect, and scoring it as one
  # would be the third time in this investigation I reported my own harness as a
  # finding. Named separately so it cannot be mistaken for either.
  onelink=$(printf '%s' "$hostnew" | grep -icE 'one phone at a time|second phone' || true)
  if [ "${onelink:-0}" -gt 0 ]; then
    echo -e "$i\tONE_LINK_LIMIT\tPPS still holds the previous link" >> "$OUT"
    limit=$((${limit:-0}+1))
    printf "  run %2d/%s  one-link limit — PPS had not released the previous link\n" "$i" "$N"
    sleep 6; continue
  fi

  if [ $rc -eq 0 ] && [ -n "$hostnew" ]; then
    # ⛔ The finding. The client settled and the host says otherwise.
    echo -e "$i\tDISAGREE\tclient=settled host=$hostnew" >> "$OUT"; disagree=$((disagree+1))
    printf "  run %2d/%s  DISAGREE  client settled, host said: %s\n" "$i" "$N" "$hostnew"
  elif [ $rc -eq 0 ]; then
    echo -e "$i\tPASS\t${detail:-}" >> "$OUT"; pass=$((pass+1))
    printf "  run %2d/%s  PASS   %s\n" "$i" "$N" "$(echo "$detail" | cut -c1-70)"
  else
    case "$outcome" in
      *expired*) echo -e "$i\tSTALE_CODE\t$outcome" >> "$OUT"; stale=$((stale+1))
                 printf "  run %2d/%s  stale code (not a fault)\n" "$i" "$N" ;;
      *)         echo -e "$i\tFAIL\t${outcome:-${detail:-rc=$rc}} | host=${hostnew:-'(nothing new)'}" >> "$OUT"; fail=$((fail+1))
                 cp "$testlog" "$SCRATCH/pps-fail-$i.log"
                 printf "  run %2d/%s  FAIL   %s\n" "$i" "$N" "${outcome:-rc=$rc}" ;;
    esac
  fi
  rm -f "$testlog"
  # ⚠ The test disconnects at its end, but PPS has to *notice* before it will
  # adopt another. Without this the next iteration races the release and looks
  # like an intermittent refusal.
  sleep 4
done

echo
echo "=== PPC against PinPointStudio ==="
echo "pass $pass   fail $fail   DISAGREE $disagree   one-link $limit   stale $stale   of $N"
[ $disagree -gt 0 ] && echo "⚠ $disagree run(s) where PPC believed it settled and PPS reported a failure"
[ $fail -gt 0 ] && { echo; echo "failures:"; grep -P '\tFAIL' "$OUT" | head -20; }
echo "results: $OUT"
