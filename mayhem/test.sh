#!/usr/bin/env bash
#
# mosquitto/mayhem/test.sh — RUN mosquitto's libcommon CUnit unit-test suite (built by
# mayhem/build.sh with normal flags) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: these are real known-answer assertions over the MQTT-relevant common code —
# base64, UTF-8 validation, MQTT topic matching, string/property parsing, file helpers. The suite
# runs ~95 tests / ~34k CUnit asserts and reports per-test pass/fail. A no-op / exit(0) patch (or any
# change that alters parsing/matching behaviour) FAILS this oracle. This script only RUNS the
# pre-built `libcommon_test` binary; it never compiles.
#
# (mosquitto's full integration suite needs a running broker + python harness, so it is NOT
# self-contained; the libcommon unit binary is the self-contained NORMAL-flags subset.)
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

TEST_BIN="$SRC/test/unit/libcommon/libcommon_test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -x "$TEST_BIN" ]; then
  echo "missing $TEST_BIN — run mayhem/build.sh first" >&2
  emit_ctrf "cunit-libcommon" 0 1 0; exit 2
fi

echo "=== running $TEST_BIN ==="
out="$(cd "$(dirname "$TEST_BIN")" && ./"$(basename "$TEST_BIN")" 2>&1)"; rc=$?
echo "$out"

# CUnit prints:  tests   <total>   <ran>   <passed>   <failed>   <inactive>
# Parse the "tests" line of the Run Summary table ($4 = passed, $5 = failed).
read -r PASSED FAILED < <(printf '%s\n' "$out" | awk '
  /^[[:space:]]*tests[[:space:]]+[0-9]/ { print $4, $5; exit }
')
: "${PASSED:=0}" "${FAILED:=0}"

# If we could not parse a summary, fall back to the binary exit code.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "could not parse CUnit summary; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cunit-libcommon" 1 0 0; exit 0; }
  emit_ctrf "cunit-libcommon" 0 1 0; exit 1
fi

emit_ctrf "cunit-libcommon" "$PASSED" "$FAILED" 0
