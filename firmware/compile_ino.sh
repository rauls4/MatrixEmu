#!/usr/bin/env bash
# Compile an Arduino .ino to a real ESP32-S3 application .bin.
# The iPhone cannot run this. Use a Mac or Linux host with arduino-cli
# and the esp32:esp32 core. idf.py does not compile .ino sketches.
#
#   firmware/compile_ino.sh firmware/player/MatrixEmuPlayer.ino \
#     firmware/player/MatrixEmuPlayer.bin
#
# FQBN defaults to esp32:esp32:esp32s3. Override with FQBN=...
set -euo pipefail

FQBN="${FQBN:-esp32:esp32:esp32s3}"

usage() {
  echo "usage: $0 <sketch.ino> [output.bin]" >&2
  echo "  board FQBN is ${FQBN} (set FQBN= to override)" >&2
  exit 2
}

die() {
  echo "compile_ino: $*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage

INO="$1"
[[ -f "$INO" ]] || die "not a file: $INO"
case "$INO" in
  *.ino) ;;
  *) die "expected a .ino sketch, got: $INO" ;;
esac

INO="$(cd "$(dirname "$INO")" && pwd)/$(basename "$INO")"
SKETCH_NAME="$(basename "$INO" .ino)"
SRC_DIR="$(dirname "$INO")"

if [[ $# -eq 2 ]]; then
  OUT="$2"
else
  OUT="${SRC_DIR}/${SKETCH_NAME}.bin"
fi
case "$OUT" in
  /*) ;;
  *) OUT="$(pwd)/$OUT" ;;
esac

install_hint() {
  cat >&2 << 'H'
Install Arduino CLI and the ESP32 core, then rerun this script.
The core is a large download; this script will not install it for you.

  brew install arduino-cli
  arduino-cli core update-index
  arduino-cli core install esp32:esp32

On macOS the core lives in ~/Library/Arduino15 (not ~/.arduino15).
H
}

if ! command -v arduino-cli >/dev/null 2>&1; then
  if command -v idf.py >/dev/null 2>&1; then
    echo "compile_ino: idf.py is on PATH but it does not compile Arduino .ino files." >&2
    idf.py --version >&2 || true
  else
    echo "compile_ino: neither arduino-cli nor idf.py is on PATH." >&2
  fi
  install_hint
  exit 1
fi

if ! arduino-cli core list 2>/dev/null | awk 'NR>1 { print $1 }' | grep -qx 'esp32:esp32'; then
  echo "compile_ino: arduino-cli is installed ($(arduino-cli version | head -1)) but core esp32:esp32 is not." >&2
  install_hint
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/compile_ino.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/sketch/${SKETCH_NAME}" "$WORKDIR/build"
cp "$INO" "$WORKDIR/sketch/${SKETCH_NAME}/${SKETCH_NAME}.ino"

# Extra translation units next to the .ino. The sketch directory name must
# match the .ino; the copy above satisfies that even if the source folder does not.
find "$SRC_DIR" -maxdepth 1 -type f \( \
  -name '*.h' -o -name '*.hpp' -o -name '*.hh' -o \
  -name '*.cpp' -o -name '*.cc' -o -name '*.c' -o -name '*.S' \
\) | while IFS= read -r extra; do
  cp "$extra" "$WORKDIR/sketch/${SKETCH_NAME}/$(basename "$extra")"
done

echo "compile_ino: $(arduino-cli version | head -1)"
echo "compile_ino: arduino-cli compile -b ${FQBN}"
arduino-cli compile -b "$FQBN" --output-dir "$WORKDIR/build" "$WORKDIR/sketch/${SKETCH_NAME}"

APP_SRC="$WORKDIR/build/${SKETCH_NAME}.ino.bin"
if [[ ! -f "$APP_SRC" ]]; then
  echo "compile_ino: build directory did not contain ${SKETCH_NAME}.ino.bin:" >&2
  ls -la "$WORKDIR/build" >&2
  exit 1
fi

magic="$(od -An -tu1 -N1 "$APP_SRC" | tr -d '[:space:]')"
if [[ "$magic" != "233" ]]; then
  die "refusing to write ${OUT}: first byte is ${magic}, expected 233 (ESP image magic 0xE9)"
fi

mkdir -p "$(dirname "$OUT")"
cp "$APP_SRC" "$OUT"

stem="$OUT"
case "$stem" in
  *.bin) stem="${stem%.bin}" ;;
esac

copy_if() {
  local src="$1"
  local dest="$2"
  if [[ -f "$src" ]]; then
    cp "$src" "$dest"
    echo "compile_ino: $(wc -c < "$dest" | tr -d '[:space:]') bytes  $dest"
  fi
}

copy_if "$WORKDIR/build/${SKETCH_NAME}.ino.bootloader.bin" "${stem}.bootloader.bin"
copy_if "$WORKDIR/build/${SKETCH_NAME}.ino.partitions.bin" "${stem}.partitions.bin"
copy_if "$WORKDIR/build/boot_app0.bin" "${stem}.boot_app0.bin"

if [[ -f "$WORKDIR/build/flash_args" ]]; then
  sed \
    -e "s/${SKETCH_NAME}.ino.bootloader.bin/$(basename "${stem}.bootloader.bin")/g" \
    -e "s/${SKETCH_NAME}.ino.partitions.bin/$(basename "${stem}.partitions.bin")/g" \
    -e "s/boot_app0.bin/$(basename "${stem}.boot_app0.bin")/g" \
    -e "s/${SKETCH_NAME}.ino.bin/$(basename "$OUT")/g" \
    "$WORKDIR/build/flash_args" > "${stem}.flash_args"
  echo "compile_ino: flash args  ${stem}.flash_args"
fi

echo "compile_ino: $(wc -c < "$OUT" | tr -d '[:space:]') bytes  $OUT"
echo "compile_ino: ESP32-S3 application image (magic 0xE9). Not a MatrixEmu animation; the emulator will reject it (no segment at 0x3FC00000)."
