#!/usr/bin/env bash
#
# One command for the deterministic end-to-end suite.
#
# Every screen it runs is backed by a committed API fixture, so no part
# of this needs the UAT backend - or any network beyond the loopback
# interface the fixture server binds to. That is the whole point: the
# previous /home and /orders baselines were photographs of whatever the
# backend held that morning, and they would have failed the day an outlet
# closed, for a reason nobody could have reproduced.
#
#   ./scripts/run_e2e.sh --app <dir>          the positive suite
#   ./scripts/run_e2e.sh --negatives          the failure cases too
#   ./scripts/run_e2e.sh --device RZ8T11QETWM pick a device explicitly
#
# Exits non-zero if ANY layer fails: an API assertion, a quiescence
# blocker, a screenshot comparison, or a negative case that passed when
# it was supposed to fail.
set -uo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The application under test. There is no default: the suite below lives
# in that application, not in this repository.
APP_DIR="${MYTEST_APP_DIR:-}"
OUT_DIR="${MYTEST_OUT_DIR:-$PLATFORM_DIR/out/e2e}"
MOCK_PORT="${MYTEST_MOCK_PORT:-8080}"
TARGET="${MYTEST_TARGET:-lib/main_mytest.dart}"
FLAVOR="${MYTEST_FLAVOR:-}"
DEVICE="${MYTEST_DEVICE:-}"
RUN_NEGATIVES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --negatives) RUN_NEGATIVES=1; shift ;;
    --device)    DEVICE="$2"; shift 2 ;;
    --app)       APP_DIR="$2"; shift 2 ;;
    --out)       OUT_DIR="$2"; shift 2 ;;
    -h|--help)   sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

if [ -z "$APP_DIR" ]; then
  echo "no application named. Pass --app <dir> or set MYTEST_APP_DIR." >&2
  exit 64
fi
FLAVOR_ARGS=()
if [ -n "$FLAVOR" ]; then
  FLAVOR_ARGS=(--flavor "$FLAVOR")
fi

# The runner picks the sole attached device when there is one. Naming it
# here only matters on a machine with several.
if [ -z "$DEVICE" ]; then
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1}' | head -1)"
fi
if [ -z "$DEVICE" ]; then
  echo "no device attached. \`adb devices\` lists none." >&2
  exit 1
fi

MYTEST=(dart run "$PLATFORM_DIR/packages/flutter_testsmith_cli/bin/testsmith.dart")

# The positive suite. `fixture:` inside each flow names the API state, so
# the runner refuses to run one without arranging it - which is why there
# is no scenario named on this command line.
POSITIVE=(
  "mytest/tests/home.yaml"
  "mytest/tests/orders.yaml"
  "mytest/tests/profile.yaml"
  # UI action, API assertion, UI action, API assertion, then the picture.
  "mytest/tests/journey.yaml"
)

# Flows that MUST fail. A suite that only ever checks things pass cannot
# tell a working check from a check that no longer runs.
NEGATIVE=(
  "mytest/tests/negative/home_stalled.yaml"
  "mytest/tests/negative/home_changed.yaml"
)

mkdir -p "$OUT_DIR"
failures=0
summary=()

run_flow() {
  local flow="$1" expect="$2" name out status
  name="$(basename "$flow" .yaml)"
  out="$OUT_DIR/$name"

  echo
  echo "──────────────────────────────────────────────────"
  echo "  $flow  (expecting $expect)"
  echo "──────────────────────────────────────────────────"

  "${MYTEST[@]}" run "$APP_DIR/$flow" \
    --app "$APP_DIR" \
    -d "$DEVICE" \
    --mock-api "$MOCK_PORT" \
    -t "$TARGET" \
    ${FLAVOR_ARGS[@]+"${FLAVOR_ARGS[@]}"} \
    --out "$out"
  status=$?

  if [ "$expect" = "pass" ] && [ $status -eq 0 ]; then
    summary+=("  PASS  $name")
  elif [ "$expect" = "fail" ] && [ $status -ne 0 ]; then
    summary+=("  PASS  $name (failed, as it must)")
  elif [ "$expect" = "fail" ]; then
    summary+=("  FAIL  $name PASSED, and this flow exists to fail")
    failures=$((failures + 1))
  else
    summary+=("  FAIL  $name (exit $status)")
    failures=$((failures + 1))
  fi
}

for flow in "${POSITIVE[@]}"; do
  run_flow "$flow" pass
done

if [ $RUN_NEGATIVES -eq 1 ]; then
  # `home_changed` serves changed data and must be compared against the
  # UNCHANGED picture - that is the regression it is demonstrating. The
  # baseline is therefore copied in for the run and removed afterwards,
  # rather than committed as a second 780KB duplicate of the first.
  BASE="$APP_DIR/visual_baselines"
  for variant in dashboard_changed; do
    cp "$BASE/home@dashboard_populated.png" "$BASE/home@$variant.png"
    cp "$BASE/home@dashboard_populated.json" "$BASE/home@$variant.json"
  done

  for flow in "${NEGATIVE[@]}"; do
    run_flow "$flow" fail
  done

  rm -f "$BASE"/home@dashboard_changed.*
fi

echo
echo "=================================================="
echo "  deterministic E2E"
echo "=================================================="
printf '%s\n' "${summary[@]}"
echo
echo "  device   $DEVICE"
echo "  reports  $OUT_DIR/<flow>/report.html"
echo

if [ $failures -ne 0 ]; then
  echo "  RESULT: FAIL ($failures of ${#summary[@]})"
  exit 1
fi

echo "  RESULT: PASS (${#summary[@]} flows)"
