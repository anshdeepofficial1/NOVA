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
  - non-empty ISO 9660 image and matching SHA-256 checksum
  - BIOS and UEFI El Torito entries
  - UEFI FAT boot image, fallback loader and Secure Boot signatures
  - generated GRUB menu, serial console and automatic live boot
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

for tool in file xorriso sha256sum stat grep mdir mcopy sbverify grub-script-check; do
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
grep -Eiq 'efi\.img' "$REPORT_DIR/el-torito.txt" || fail "UEFI El Torito boot image path is missing from the catalog"

# Validate the actual EFI FAT image instead of trusting only the catalog flag.
EFI_IMAGE="$REPORT_DIR/efi.img"
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/efi.img "$EFI_IMAGE" > "$REPORT_DIR/efi-extract.txt" 2>&1 || fail "could not extract /boot/grub/efi.img from the ISO"
[[ -s "$EFI_IMAGE" ]] || fail "extracted UEFI boot image is empty"
mdir -i "$EFI_IMAGE" ::/EFI/BOOT > "$REPORT_DIR/efi-boot-directory.txt" 2>&1 || fail "UEFI boot image has no EFI/BOOT directory"

for loader in BOOTX64.EFI grubx64.efi; do
  loader_path="$REPORT_DIR/$loader"
  mcopy -i "$EFI_IMAGE" "::/EFI/BOOT/$loader" "$loader_path" > "$REPORT_DIR/mcopy-$loader.txt" 2>&1 || fail "UEFI fallback loader is missing: $loader"
  [[ -s "$loader_path" ]] || fail "UEFI loader is empty: $loader"
  sbverify --list "$loader_path" > "$REPORT_DIR/signature-$loader.txt" 2>&1 || fail "UEFI loader has no verifiable Secure Boot signature: $loader"
done

# Inspect the exact GRUB files shipped in the ISO. Kernel arguments alone are
# insufficient if GRUB itself is not visible to the headless serial harness.
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/config.cfg "$REPORT_DIR/grub-config.cfg" > "$REPORT_DIR/grub-config-extract.txt" 2>&1 || fail "generated GRUB config.cfg is missing from the ISO"
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/grub.cfg "$REPORT_DIR/grub-menu.cfg" > "$REPORT_DIR/grub-menu-extract.txt" 2>&1 || fail "generated GRUB grub.cfg is missing from the ISO"
grep -Fq 'serial --unit=0 --speed=115200' "$REPORT_DIR/grub-config.cfg" || fail "generated GRUB config does not initialize serial COM1"
grep -Fq 'terminal_output --append serial' "$REPORT_DIR/grub-config.cfg" || fail "generated GRUB config does not mirror output to serial"
theme_line="$(grep -nF 'source /boot/grub/theme.cfg' "$REPORT_DIR/grub-config.cfg" | head -n 1 | cut -d: -f1)"
timeout_line="$(grep -nF 'set timeout=8' "$REPORT_DIR/grub-config.cfg" | head -n 1 | cut -d: -f1)"
default_line="$(grep -nF 'set default=0' "$REPORT_DIR/grub-config.cfg" | head -n 1 | cut -d: -f1)"
[[ -n "$theme_line" && -n "$timeout_line" && -n "$default_line" ]] || fail "generated GRUB boot policy is incomplete"
(( timeout_line > theme_line && default_line > theme_line )) || fail "GRUB default/timeout policy must be applied after the theme"
grep -Fq 'source /boot/grub/config.cfg' "$REPORT_DIR/grub-menu.cfg" || fail "generated GRUB menu does not load NOVA's GRUB configuration"
grep -Eiq 'Live system' "$REPORT_DIR/grub-menu.cfg" || fail "generated GRUB menu has no live system entry"
grep -Fq 'console=ttyS0,115200n8' "$REPORT_DIR/grub-menu.cfg" || fail "generated live menu does not pass the serial console to Linux"
grub-script-check "$REPORT_DIR/grub-config.cfg" > "$REPORT_DIR/grub-config-syntax.txt" 2>&1 || fail "generated GRUB console configuration has invalid syntax"
grub-script-check "$REPORT_DIR/grub-menu.cfg" > "$REPORT_DIR/grub-menu-syntax.txt" 2>&1 || fail "generated GRUB menu has invalid syntax"

xorriso -indev "$ISO" -ls /live > "$REPORT_DIR/live-files.txt" 2>&1 || fail "the /live directory is missing from the ISO"
grep -Eiq 'vmlinuz' "$REPORT_DIR/live-files.txt" || fail "live kernel is missing"
grep -Eiq 'initrd' "$REPORT_DIR/live-files.txt" || fail "live initrd is missing"
grep -Eiq 'filesystem\.squashfs' "$REPORT_DIR/live-files.txt" || fail "live SquashFS root filesystem is missing"

{
  printf 'ISO: %s\n' "$ISO"
  printf 'Bytes: %s\n' "$ISO_SIZE"
  printf 'SHA-256: '
  sha256sum "$ISO" | awk '{print $1}'
  printf 'BIOS El Torito boot entry: present\n'
  printf 'UEFI El Torito boot image: present\n'
  printf 'UEFI fallback loader: present and Secure Boot signed\n'
  printf 'GRUB graphical menu + serial console: present\n'
  printf 'Live kernel/initrd/SquashFS: present\n'
} | tee "$REPORT_DIR/summary.txt"

echo "NOVA ISO structural and boot-chain validation passed."
