#!/usr/bin/env bash
set -Eeuo pipefail

ISO=""
CHECKSUM=""
REPORT_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/validate-iso.sh --iso PATH [--checksum PATH] [--report-dir PATH]

Checks:
  - non-empty ISO 9660 image
  - checksum file (defaults to PATH.sha256)
  - El Torito BIOS and UEFI boot entries
  - live kernel, initrd and SquashFS root filesystem
USAGE
}

fail() {
  echo "NOVA ISO validation failed: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --checksum) CHECKSUM="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$ISO" ]] || fail "--iso is required"
[[ -s "$ISO" ]] || fail "ISO does not exist or is empty: $ISO"

for tool in file xorriso sha256sum stat grep; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing validation dependency: $tool"
done

if [[ -z "$CHECKSUM" ]]; then
  CHECKSUM="$ISO.sha256"
fi
[[ -s "$CHECKSUM" ]] || fail "SHA-256 checksum file is missing: $CHECKSUM"

if [[ -z "$REPORT_DIR" ]]; then
  REPORT_DIR="$(dirname -- "$ISO")/validation"
fi
mkdir -p "$REPORT_DIR"

ISO_SIZE="$(stat -c '%s' "$ISO")"
(( ISO_SIZE >= 134217728 )) || fail "image is unexpectedly small ($ISO_SIZE bytes)"

FILE_DESCRIPTION="$(file --brief "$ISO")"
printf '%s\n' "$FILE_DESCRIPTION" | tee "$REPORT_DIR/file.txt"
grep -Eiq 'ISO 9660' <<< "$FILE_DESCRIPTION" || fail "file(1) does not identify an ISO 9660 image"

(
  cd "$(dirname -- "$CHECKSUM")"
  sha256sum --check "$(basename -- "$CHECKSUM")"
) | tee "$REPORT_DIR/checksum.txt"

xorriso -indev "$ISO" -report_el_torito plain > "$REPORT_DIR/el-torito.txt" 2>&1 || fail "xorriso could not read the El Torito boot catalog"
grep -Eiq 'BIOS' "$REPORT_DIR/el-torito.txt" || fail "BIOS El Torito boot entry is missing"
grep -Eiq 'UEFI' "$REPORT_DIR/el-torito.txt" || fail "UEFI El Torito boot entry is missing"

xorriso -indev "$ISO" -ls /live > "$REPORT_DIR/live-files.txt" 2>&1 || fail "the /live directory is missing from the ISO"
grep -Eiq 'vmlinuz' "$REPORT_DIR/live-files.txt" || fail "live kernel is missing"
grep -Eiq 'initrd' "$REPORT_DIR/live-files.txt" || fail "live initrd is missing"
grep -Eiq 'filesystem\.squashfs' "$REPORT_DIR/live-files.txt" || fail "live SquashFS root filesystem is missing"

{
  printf 'ISO: %s\n' "$ISO"
  printf 'Bytes: %s\n' "$ISO_SIZE"
  printf 'SHA-256: '
  sha256sum "$ISO" | awk '{print $1}'
  printf 'BIOS boot entry: present\n'
  printf 'UEFI boot entry: present\n'
  printf 'Live kernel/initrd/SquashFS: present\n'
} | tee "$REPORT_DIR/summary.txt"

echo "NOVA ISO structural validation passed."
