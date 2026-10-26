#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
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

# Diagon's functional suite is golden files: test/<Translator>[_opt=val]/<case>/{input,output}.
# Each case is run through the built `diagon` CLI (a dynamically linked binary, so the sabotage shim
# neuters it) and its stdout compared byte-for-byte with the committed golden `output`. Upstream's own
# runner (input_output_test) additionally replays every case in-process.
DIAGON=mayhem/build-tests/diagon
RUNNER=mayhem/build-tests/input_output_test
for b in "$DIAGON" "$RUNNER"; do
  [ -x "$b" ] || { echo "missing $b — mayhem/build.sh should have built it" >&2; exit 1; }
done

passed=0; failed=0
tmp=$(mktemp); trap 'rm -f "$tmp" "$tmp.exp"' EXIT
for dir in test/*/; do
  name=$(basename "$dir"); translator=${name%%_*}; opts=()
  if [ "$name" != "$translator" ]; then
    IFS='_' read -ra kv <<<"${name#*_}"
    for o in "${kv[@]}"; do opts+=("--$o"); done
  fi
  for c in "$dir"*/; do
    { cat "$c/output"; echo; } > "$tmp.exp"   # the CLI prints the translation followed by a newline
    if "$DIAGON" "$translator" "${opts[@]}" < "$c/input" 2>/dev/null | cmp -s - "$tmp.exp"; then
      passed=$((passed+1))
    else
      failed=$((failed+1)); echo "FAIL: $c (translator=$translator ${opts[*]:-})" >&2
    fi
  done
done

# Known answers pinned independently of the golden files.
kat() {  # kat <expected> <translator> [args...]
  local expected="$1" got; shift
  got=$("$DIAGON" "$@" 2>/dev/null)
  if [ "$got" = "$expected" ]; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL: kat $* -> [$got]" >&2; fi
}
kat $'    1\n1 + ─\n    2' Math -- "1+1/2"
kat $'1\n─\n2' Math -- "1/2"
kat '\frac{1}{2}' Math --style=Latex -- "1/2"

if "$RUNNER" 2>/dev/null | grep -q -e '\[FAIL\]' -e '\[Create output\]'; then
  failed=$((failed+1)); echo "FAIL: input_output_test reported mismatches" >&2
elif "$RUNNER" >/dev/null 2>&1; then
  passed=$((passed+1))
else
  failed=$((failed+1)); echo "FAIL: input_output_test exited non-zero" >&2
fi

[ "$passed" -gt 0 ] || failed=$((failed+1))
emit_ctrf "diagon-golden" "$passed" "$failed" 0
