#!/bin/bash
# Builds the optional whisper.cpp dictation helper (build/whisper/hiveminds-whisper) with plain clang.
# No cmake or Xcode needed. It builds once per pinned whisper.cpp version and is reused after that.
# build-app.sh calls this; set HIVEMINDS_NO_WHISPER=1 to leave the helper out of the app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.9.5
SHA256=ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720
OUT=build/whisper
BIN="$OUT/hiveminds-whisper"
STAMP="$OUT/.built-$VERSION-$(shasum -a 256 Helpers/whisper-helper/main.cpp | cut -c1-12)"

if [ -x "$BIN" ] && [ -e "$STAMP" ]; then exit 0; fi

mkdir -p "$OUT"
SRC="$OUT/whisper.cpp-$VERSION"
if [ ! -d "$SRC" ]; then
  echo "Downloading whisper.cpp ${VERSION}…"
  curl -fsSL -o "$OUT/whisper.tgz" "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$VERSION.tar.gz"
  echo "$SHA256  $OUT/whisper.tgz" | shasum -a 256 -c - >/dev/null
  tar xzf "$OUT/whisper.tgz" -C "$OUT"
  rm "$OUT/whisper.tgz"
fi

echo "Building the whisper helper (one time, about a minute)…"
OBJ="$OUT/obj"
rm -rf "$OBJ" && mkdir -p "$OBJ"
printf '#pragma once\n#define GGML_VERSION "%s"\n#define GGML_COMMIT "v%s"\n' "$VERSION" "$VERSION" > "$OBJ/ggml-version.h"
G="$SRC/ggml/src"
FLAGS=(-O3 -DNDEBUG -mcpu=apple-m1 -mmacosx-version-min=26.0
  -D_DARWIN_C_SOURCE -D_XOPEN_SOURCE=600 -DGGML_SCHED_MAX_COPIES=4
  -DWHISPER_VERSION=\"$VERSION\"
  -DGGML_USE_CPU -DGGML_USE_BLAS -DGGML_USE_ACCELERATE -DGGML_BLAS_USE_ACCELERATE
  -DACCELERATE_NEW_LAPACK -DACCELERATE_LAPACK_ILP64
  -I"$OBJ" -I"$SRC/include" -I"$SRC/ggml/include" -I"$G" -I"$G/ggml-cpu")

SOURCES=(
  "$SRC/src/whisper.cpp" "$SRC/src/aneforge/whisper-aneforge.cpp"
  "$G/ggml.c" "$G/ggml.cpp" "$G/ggml-alloc.c" "$G/ggml-backend.cpp" "$G/ggml-backend-reg.cpp"
  "$G/ggml-backend-meta.cpp" "$G/ggml-backend-dl.cpp" "$G/ggml-opt.cpp" "$G/ggml-quants.c" "$G/ggml-threading.cpp" "$G/gguf.cpp"
  "$G"/ggml-cpu/*.c "$G"/ggml-cpu/*.cpp "$G"/ggml-cpu/arch/arm/*.c "$G"/ggml-cpu/arch/arm/*.cpp "$G"/ggml-cpu/tiled/*.cpp
  "$G/ggml-blas/ggml-blas.cpp"
  Helpers/whisper-helper/main.cpp
)

pids=()
i=0
for f in "${SOURCES[@]}"; do
  case "$f" in
    *.c) clang -std=c11 "${FLAGS[@]}" -c "$f" -o "$OBJ/$i.o" & ;;
    *) clang++ -std=c++17 "${FLAGS[@]}" -c "$f" -o "$OBJ/$i.o" & ;;
  esac
  pids+=($!)
  i=$((i + 1))
  if [ $((i % 8)) -eq 0 ]; then for p in "${pids[@]}"; do wait "$p"; done; pids=(); fi
done
for p in "${pids[@]}"; do wait "$p"; done

clang++ -mmacosx-version-min=26.0 "$OBJ"/*.o -framework Accelerate -framework Foundation -o "$BIN"
rm -rf "$OBJ" "$OUT"/.built-*
touch "$STAMP"
echo "Built $BIN"
