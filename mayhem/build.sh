#!/usr/bin/env bash
#
# mayhem/build.sh — build pkg's fuzz harnesses (in-tree tests/fuzz/*.c + the ported text_diff harness),
# an instrumented `pkg` CLI, and the project's own ATF/kyua test suite (normal flags) for test.sh.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. All dependencies are apt
# packages baked into the image or vendored under external/, so a re-run needs no network.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Project, sanitized + DWARF 3, in an out-of-tree build dir (gitignored via mayhem/.gitignore).
mkdir -p mayhem/build-fuzz
(
  cd mayhem/build-fuzz
  # The Makefiles take `CFLAGS?=`/LDFLAGS from the make environment (configure ignores them), so pass them there.
  "$SRC/configure" CC="$CC"
  # -D_MUM_UNALIGNED_ACCESS=0 is what upstream's own `configure --with-ubsan` adds: libucl's mum hash
  # otherwise does benign misaligned loads that UBSan (halting) aborts on for every parsed key.
  # -fsanitize=fuzzer-no-link adds SanCov to the library itself (the engine only instruments the harness TU);
  # without it every libFuzzer target records ~0 edges in Mayhem. Kept unconditional, even with empty SANITIZER_FLAGS.
  CFLAGS="-O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -D_MUM_UNALIGNED_ACCESS=0" LDFLAGS="$SANITIZER_FLAGS" make -j"$MAYHEM_JOBS"
)
FUZZ_BUILD="$SRC/mayhem/build-fuzz"

# 1b) The `pkg` CLI as a raw file-input target needs real coverage instrumentation to get edges in Mayhem
# (binary-only tracing of the sanitized CLI recorded 0 edges and a failed smoke test), so build it once more
# with AFL instrumentation (`afl: true` in Mayhemfile_pkg). Same sanitizer/DWARF flags; no libFuzzer SanCov.
# lsan_off is linked in too: run as root, `pkg info` drops to `nobody`, after which LeakSanitizer dies with
# a fatal error at exit on every input (Mayhem's regression-testing phase then fails the whole run).
mkdir -p mayhem/build-afl
(
  cd mayhem/build-afl
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o lsan_off.o
  "$SRC/configure" CC=afl-clang-fast
  CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -D_MUM_UNALIGNED_ACCESS=0" \
    LDFLAGS="$SANITIZER_FLAGS $SRC/mayhem/build-afl/lsan_off.o" make -j"$MAYHEM_JOBS"
)
cp "$SRC/mayhem/build-afl/src/pkg" /mayhem/pkg-afl

# 2) Harnesses: each linked twice (libFuzzer engine + standalone run-once driver), LSan switched off.
INCS=(-I"$SRC/compat" -I"$SRC/external/libucl/include" -I"$SRC/external/uthash" -I"$SRC/external/include"
      -I"$SRC/external/sqlite" -I"$SRC/external/lua/src" -I"$SRC/libpkg" -I"$FUZZ_BUILD" -I"$FUZZ_BUILD/libpkg")
LIBS=(-L"$FUZZ_BUILD/libpkg" -lpkg_flat -lm -lbsd -larchive -lbz2 -lz -llzma -pthread -lssl -lcrypto)

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

build_harness() {
  local src="$1" name cc="$CC"
  name="$(basename "${src%.*}")"
  [ "${src##*.}" = cpp ] && cc="$CXX"
  $cc -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -DTESTING "${INCS[@]}" "$src" /tmp/lsan_off.o \
      $LIB_FUZZING_ENGINE "${LIBS[@]}" -o "/mayhem/$name"
  $cc -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -DTESTING "${INCS[@]}" "$src" /tmp/lsan_off.o \
      /tmp/standalone_main.o "${LIBS[@]}" -o "/mayhem/$name-standalone"
}

# tests/fuzz/fuzz_config.c is skipped: it calls the file-static config_parse_abi_options(), so it cannot
# link (upstream's own tests/fuzz/Makefile.in leaves it out of FUZZ_TARGETS too).
# A harness of the same name under mayhem/ (fuzz_message.c) replaces the in-tree one.
for src in "$SRC"/tests/fuzz/fuzz_*.c "$SRC/mayhem/fuzz_text_diff.cpp"; do
  base="$(basename "$src")"
  [ "$base" = fuzz_config.c ] && continue
  [ -f "$SRC/mayhem/$base" ] && src="$SRC/mayhem/$base"
  build_harness "$src"
done

# 3) The project's own test suite (ATF tests run by kyua), NORMAL flags, separate build dir.
mkdir -p mayhem/build-tests
(
  cd mayhem/build-tests
  "$SRC/configure" --with-tests CC="$CC"
  CFLAGS="-O2 -pipe $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" make -j"$MAYHEM_JOBS"
)
