#!/bin/bash
# Soak the app's live-link path against ppcp-sim, N times, and report the rate.
#
# Builds ONCE and then loops sim + test-without-building, so an iteration is
# seconds rather than a compile. The point is a failure *rate*: "intermittent"
# spans 5% and 50%, and those point at different things.
#
#   ./soak.sh <iterations> [scenario]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

N="${1:-20}"
SCENARIO="${2:-reference-host}"
SIM_NAME=$(xcrun simctl list devices available 2>/dev/null \
  | grep -Eo 'iPhone [0-9A-Za-z ]+' | tail -1 | sed 's/ *$//')
DEST="platform=iOS Simulator,name=$SIM_NAME"
PPCP_SIM=../libppcp/build/dev/tools/ppcp-sim/ppcp-sim
DECL=../libppcp/tools/scenarios/${SCENARIO}.json
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$HERE"
OUT=$SCRATCH/soak-results.tsv

echo "simulator: $SIM_NAME"
echo "iterations: $N   scenario: $SCENARIO"
echo

xcodebuild build-for-testing -project PinPointCapture.xcodeproj -scheme PinPointCapture \
  -configuration Debug -destination "$DEST" -derivedDataPath build -jobs 8 \
  >/dev/null 2>&1 || { echo "build-for-testing failed"; exit 1; }
# Boot the simulator BEFORE the first counterpart starts. A cold boot is tens of
# seconds and ppcp-sim's window is finite; the first run otherwise fails with a
# refused connection that looks like a protocol fault and is not one.
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null 2>&1 || true
echo "built once, simulator booted; looping"
echo -e "run\tverdict\tdetail" > "$OUT"

pass=0; fail=0
for i in $(seq 1 "$N"); do
  portfile=$(mktemp -t soak-port)
  simlog=$(mktemp -t soak-sim)
  testlog=$(mktemp -t soak-test)

  "$PPCP_SIM" --role host --listen 0 --port-file "$portfile" \
      --declaration "$DECL" --scenario "$SCENARIO" \
      --expect violations=0 --run-ms 45000 >"$simlog" 2>&1 &
  simpid=$!

  port=""
  for _ in $(seq 1 25); do [ -s "$portfile" ] && { port=$(cat "$portfile"); break; }; sleep 0.2; done
  if [ -z "$port" ]; then
    echo -e "$i\tSIM_NO_PORT\t-" >> "$OUT"; fail=$((fail+1))
    kill $simpid 2>/dev/null; rm -f "$portfile" "$simlog" "$testlog"; continue
  fi

  TEST_RUNNER_PPCP_CONFORM_PORT=$port \
  TEST_RUNNER_PPCP_CONFORM_ROW=e31 \
  TEST_RUNNER_PPCP_CONFORM_SCENARIO=$SCENARIO \
  xcodebuild test-without-building -project PinPointCapture.xcodeproj \
      -scheme PinPointCapture -configuration Debug -destination "$DEST" \
      -derivedDataPath build \
      -only-testing:PinPointCaptureTests/ConformanceHarnessTests \
      -default-test-execution-time-allowance 120 >"$testlog" 2>&1
  testrc=$?

  wait $simpid; simrc=$?

  # The e31 test's own verdict, and the simulator's independent one.
  if grep -q '✘.*composition root' "$testlog" || [ $testrc -ne 0 ]; then
    detail=$(grep -oE '✘ Test "[^"]+"|error: .*' "$testlog" | head -1 | cut -c1-90)
    echo -e "$i\tTEST_FAIL\t${detail:-rc=$testrc}" >> "$OUT"; fail=$((fail+1))
    cp "$testlog" "$SCRATCH/soak-fail-$i-test.log"
    cp "$simlog"  "$SCRATCH/soak-fail-$i-sim.log"
  elif [ $simrc -ne 0 ]; then
    echo -e "$i\tSIM_VIOLATION\t$(grep -iE 'violation|expect' "$simlog" | head -1 | cut -c1-90)" >> "$OUT"
    fail=$((fail+1))
    cp "$simlog" "$SCRATCH/soak-fail-$i-sim.log"
  else
    errs=$(grep -oE 'errors [0-9]+' "$simlog" | tail -1)
    echo -e "$i\tPASS\t${errs:-}" >> "$OUT"; pass=$((pass+1))
  fi
  printf "  run %2d/%s  pass=%d fail=%d\n" "$i" "$N" "$pass" "$fail"
  rm -f "$portfile" "$simlog" "$testlog"
done

echo
echo "=== PPC against ppcp-sim ==="
echo "pass $pass / $((pass+fail))   fail $fail"
[ $fail -gt 0 ] && { echo; echo "failures:"; grep -v PASS "$OUT" | tail -20; }
echo
echo "results: $OUT"
