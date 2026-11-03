#!/usr/bin/env bash
#
# mayhem/test.sh — RUN pkg's OWN functional test suite (ATF tests driven by kyua, built by mayhem/build.sh
# into mayhem/build-tests with normal flags). exit 0 = pass. PATCH-grade oracle: after an agent patches the
# source, the grader rebuilds (build.sh) then runs this.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run every ATF test case under kyua. The result store goes to a throwaway file so HOME (which differs
# between CI and the air-gapped PATCH re-run identity) does not matter.
TESTS_DIR="$SRC/mayhem/build-tests/tests"
[ -f "$TESTS_DIR/Kyuafile" ] || { echo "missing $TESTS_DIR/Kyuafile — mayhem/build.sh did not build the tests" >&2; emit_ctrf "kyua" 0 1 0; exit 1; }
command -v kyua >/dev/null || { echo "kyua not installed" >&2; emit_ctrf "kyua" 0 1 0; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
cd "$TESTS_DIR"
kyua test --results-file="$WORK/results.db" 2>&1 | tee "$WORK/out.txt"

# Result lines look like `frontend/add:add_basic  ->  passed  [0.1s]`; expected_failure counts as passed.
passed=$(grep -cE '  ->  (passed|expected_failure)' "$WORK/out.txt" || true)
skipped=$(grep -cE '  ->  skipped' "$WORK/out.txt" || true)
failed=$(grep -E '  ->  ' "$WORK/out.txt" | grep -cvE '  ->  (passed|expected_failure|skipped)' || true)

# Guard against a neutered/missing run: pkg has ~570 ATF cases, so an empty run is a failure, not a pass.
if [ $((passed + failed + skipped)) -lt 100 ]; then
  echo "kyua ran only $((passed + failed + skipped)) test cases — expected hundreds" >&2
  failed=$((failed + 1))
fi
emit_ctrf "kyua" "$passed" "$failed" "$skipped"
