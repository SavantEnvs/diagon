#!/usr/bin/env bash
#
# mayhem/build.sh — build Diagon sanitized + the libFuzzer harness, plus the normal-flags test build.
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem; offline: every dependency
# comes from /opt/diagon-deps (pre-fetched by the Dockerfile) and the apt-installed JRE/Boost.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
DEPS=/opt/diagon-deps

configure() {  # configure <build-dir> <flags> [extra cmake args...]
  local dir="$1" flags="$2"; shift 2
  mkdir -p "$dir"
  cp -f "$DEPS/antlr.jar" "$dir/antlr.jar"   # tools/CMakeLists.txt would otherwise curl it
  cmake -S . -B "$dir" \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" \
    -DANTLR_BUILD_CPP_TESTS=OFF \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DFETCHCONTENT_SOURCE_DIR_JSON="$DEPS/json" \
    -DFETCHCONTENT_SOURCE_DIR_ANTLR="$DEPS/antlr4" \
    -DFETCHCONTENT_SOURCE_DIR_KGT="$DEPS/kgt" \
    "$@"
}

# 1) Diagon + deps with ASan/UBSan and DWARF 3 (the fuzzed code is instrumented, not just the harness).
# fuzzer-no-link: coverage-instrument the project itself (the harness links the engine).
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
configure mayhem/build "$FUZZ_FLAGS"
cmake --build mayhem/build -j"$MAYHEM_JOBS" --target diagon_lib

# 2) Harness: libFuzzer binary + run-once standalone reproducer. The static archives are interdependent
#    (translators <-> diagon_base/antlr/screen/kgt), so link them as one group.
LIBS=$(find mayhem/build -name '*.a' | sort)
BOOST_LIBS=$(ls /usr/lib/*/libboost_graph.a /usr/lib/*/libboost_regex.a 2>/dev/null || true)
INCS="-I$SRC/src -I$SRC/mayhem/build/src"
$CXX $FUZZ_FLAGS -std=c++17 -c mayhem/lsan_off.cc -o mayhem/build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o mayhem/build/standalone_main.o
$CXX $FUZZ_FLAGS -std=c++17 $INCS -c mayhem/fuzz_diagon.cpp -o mayhem/build/fuzz_diagon.o
$CXX $FUZZ_FLAGS $LIB_FUZZING_ENGINE mayhem/build/fuzz_diagon.o mayhem/build/lsan_off.o \
  -Wl,--start-group $LIBS -Wl,--end-group $BOOST_LIBS -o /mayhem/fuzz_diagon
$CXX $FUZZ_FLAGS mayhem/build/fuzz_diagon.o mayhem/build/standalone_main.o mayhem/build/lsan_off.o \
  -Wl,--start-group $LIBS -Wl,--end-group $BOOST_LIBS -o /mayhem/fuzz_diagon-standalone

# 3) Test suite with normal flags (clean, independent build): upstream's golden-file runner
#    input_output_test and the diagon CLI that test.sh drives.
configure mayhem/build-tests "$COVERAGE_FLAGS" -DDIAGON_BUILD_TESTS=ON
cmake --build mayhem/build-tests -j"$MAYHEM_JOBS" --target diagon input_output_test
