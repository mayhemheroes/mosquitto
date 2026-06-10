#!/usr/bin/env bash
#
# mosquitto/mayhem/build.sh — build eclipse-mosquitto's six MQTT-PACKET-handling OSS-Fuzz harnesses
# as sanitized libFuzzer targets (+ standalone reproducers).
#
# The fuzzed surface is the mosquitto BROKER's MQTT packet read path on attacker-controlled bytes.
# Every harness routes through fuzzing/broker/fuzz_packet_read_base.c, which builds a fake client
# `struct mosquitto`, copies the fuzz input into context->in_packet, and calls one packet handler:
#   broker_fuzz_read_handle      -> handle__packet      (the top-level MQTT command dispatcher)
#   broker_fuzz_handle_connect   -> handle__connect     (CONNECT  0x10)
#   broker_fuzz_handle_publish   -> handle__publish     (PUBLISH  0x30)
#   broker_fuzz_handle_subscribe -> handle__subscribe   (SUBSCRIBE 0x82)
#   broker_fuzz_handle_unsubscribe -> handle__unsubscribe (UNSUBSCRIBE 0xA2)
#   broker_fuzz_handle_auth      -> handle__auth        (AUTH 0xF0, MQTT v5)
# Input layout (see fuzz_packet_read_base.c): byte[0]=client state, byte[1]=protocol level, byte[2..]
# = a raw MQTT packet (command byte + remaining-length-encoded payload). The seed corpus in
# mayhem/testsuite/ is 1662 real MQTT packets generated from mosquitto's own broker test sequences.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile the broker + common libs WITH $SANITIZER_FLAGS, so the fuzzed
# packet-handling code (not just the harness) is instrumented. This mirrors OSS-Fuzz's
# fuzzing/scripts/oss-fuzz-build.sh (cJSON static + `make WITH_FUZZING=yes`) but builds only the
# broker static archive + the six packet harnesses (no LPM / sqlite plugin fuzzers).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS= builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF-3 so Mayhem triage can read symbols (clang-19 default is DWARF-5; §6.2 item 10).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ── 1) cJSON (broker's only required direct dep here) is built+installed to /usr/local by the
#       Dockerfile's root stage (install needs privileges). When running build.sh outside that
#       image, build it into a local prefix so we never need root. ───────────────────────────────
if [ ! -f /usr/local/lib/libcjson.a ] && ! pkg-config --exists libcjson 2>/dev/null; then
  CJSON_SRC="$SRC/cJSON"
  [ -d "$CJSON_SRC" ] || git clone --depth 1 https://github.com/ralight/cJSON "$CJSON_SRC"
  ( cd "$CJSON_SRC"
    cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS=-fPIC -DENABLE_CJSON_TEST=OFF \
      -DCMAKE_INSTALL_PREFIX="$SRC/cjson-prefix" .
    make -j"$MAYHEM_JOBS"
    make install )
  export CPATH="$SRC/cjson-prefix/include${CPATH:+:$CPATH}"
  export LIBRARY_PATH="$SRC/cjson-prefix/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi

# ── 2) Build mosquitto's common + lib + broker static archive WITH sanitizers ──────────────────────
# WITH_FUZZING=yes implies static libs + -DWITH_FUZZING. CFLAGS/CXXFLAGS carry $SANITIZER_FLAGS so the
# broker code itself is instrumented. We only build the dirs the packet harnesses link against
# (libcommon, lib, src) — skipping the sqlite-backed persistence plugins that the packet fuzzers
# don't use.
MK_ARGS=(WITH_STATIC_LIBRARIES=yes WITH_DOCS=no WITH_FUZZING=yes WITH_EDITLINE=no WITH_HTTP_API=no)
export CFLAGS="$SANITIZER_FLAGS"
export CXXFLAGS="$SANITIZER_FLAGS"

make "${MK_ARGS[@]}" -C libcommon -j"$MAYHEM_JOBS"
make "${MK_ARGS[@]}" -C lib       -j"$MAYHEM_JOBS"
make "${MK_ARGS[@]}" -C src mosquitto_broker.a -j"$MAYHEM_JOBS"

BROKER_A="$SRC/src/mosquitto_broker.a"
COMMON_A="$SRC/libcommon/libmosquitto_common.a"
ls -la "$BROKER_A" "$COMMON_A"

# ── 3) Build each packet harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer ──────
HARNESS_DIR="$SRC/mayhem/harnesses"

# Mirror the flags the upstream fuzzing/broker/Makefile uses for the harness translation units.
HARNESS_DEFS="-DWITH_BRIDGE -DWITH_BROKER -DWITH_CONTROL -DWITH_EPOLL -DWITH_MEMORY_TRACKING \
-DWITH_PERSISTENCE -DWITH_SOCKS -DWITH_SYSTEMD -DWITH_SYS_TREE -DWITH_TLS -DWITH_TLS_PSK \
-DWITH_UNIX_SOCKETS -DWITH_WEBSOCKETS=WS_IS_BUILTIN -DWITH_FUZZING"
HARNESS_INC="-I$SRC -I$SRC/include -I$SRC/src -I$SRC/lib -I$SRC/common -I$SRC/deps -I$HARNESS_DIR"
HARNESS_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -Wall -pthread $HARNESS_DEFS $HARNESS_INC"
# argon2 is pulled by password handling inside the broker archive.
LINK_LIBS="-lssl -lcrypto -lcjson -lm $COMMON_A -Wl,-Bdynamic -Wl,-Bstatic -largon2 -Wl,-Bdynamic"

BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

# Shared base TU (C) — compiled once.
$CC $HARNESS_FLAGS -c "$HARNESS_DIR/fuzz_packet_read_base.c" -o "$BUILD/fuzz_packet_read_base.o"

# StandaloneFuzzTargetMain (C) — compiled once; provides main() for the *-standalone reproducers.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

for harness in \
    broker_fuzz_read_handle \
    broker_fuzz_handle_connect \
    broker_fuzz_handle_publish \
    broker_fuzz_handle_subscribe \
    broker_fuzz_handle_unsubscribe \
    broker_fuzz_handle_auth ; do

  # libFuzzer target -> /mayhem/<name>
  $CXX $HARNESS_FLAGS "$HARNESS_DIR/$harness.cpp" "$BUILD/fuzz_packet_read_base.o" \
      "$BROKER_A" $LIB_FUZZING_ENGINE $LINK_LIBS \
      -o "/mayhem/$harness"

  # standalone reproducer (no libFuzzer runtime, run-once over input files) -> /mayhem/<name>-standalone
  $CXX $HARNESS_FLAGS "$HARNESS_DIR/$harness.cpp" "$BUILD/fuzz_packet_read_base.o" \
      "$BUILD/standalone_main.o" "$BROKER_A" $LINK_LIBS \
      -o "/mayhem/$harness-standalone"

  echo "built $harness (+ standalone)"
done

# ── 4) Build mosquitto's OWN libcommon unit-test suite with NORMAL flags (no sanitizer) so test.sh
#       only RUNS it. These are CUnit known-answer tests over the MQTT-relevant common code:
#       base64 / UTF-8 validation / topic matching / string + property parsing / file helpers — the
#       exact primitives the fuzzed packet handlers rely on. They assert values, so a no-op/exit(0)
#       patch cannot pass. Built into the in-place tree (separate object set from the sanitized libs
#       is unnecessary — the unit Makefile compiles its own TUs with normal flags and links the
#       non-sanitized libmosquitto_common.a built below). ─────────────────────────────────────────
echo "=== building libcommon unit-test suite (normal flags) ==="
TEST_MK=(WITH_STATIC_LIBRARIES=yes WITH_DOCS=no WITH_EDITLINE=no WITH_HTTP_API=no)
# Rebuild libmosquitto_common.a with NORMAL flags (the unit test links it; we don't want the
# sanitized variant under the non-sanitized test binary). The objects from step 2 are sanitized,
# so `clean` first to force a fresh compile — the fuzzers are already linked, so this is safe.
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  make "${TEST_MK[@]}" -C libcommon clean
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  make "${TEST_MK[@]}" -C libcommon -j"$MAYHEM_JOBS"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  make "${TEST_MK[@]}" -C test/unit/libcommon build -j"$MAYHEM_JOBS"
ls -la "$SRC/test/unit/libcommon/libcommon_test"

echo "build.sh complete:"
ls -la /mayhem/broker_fuzz_* 2>&1 || true
