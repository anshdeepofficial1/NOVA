#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
LIVE_DIR="$ROOT_DIR/os/debian-live"
PACKAGE_LIST="$LIVE_DIR/config/package-lists/nova-desktop.list.chroot"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "NOVA live-build configuration validation failed: $*" >&2
  exit 1
}

for tool in lb awk sort uniq grep cp mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

for path in \
  "$LIVE_DIR/auto/config" \
  "$LIVE_DIR/auto/clean" \
  "$LIVE_DIR/auto/build" \
  "$LIVE_DIR/build.sh" \
  "$LIVE_DIR/config/archives/debian-backports.list.chroot" \
  "$LIVE_DIR/config/archives/debian-backports.list.binary" \
  "$PACKAGE_LIST"; do
  [[ -s "$path" ]] || fail "required file is missing or empty: $path"
done

for path in "$LIVE_DIR/auto/config" "$LIVE_DIR/auto/clean" "$LIVE_DIR/auto/build" "$LIVE_DIR/build.sh"; do
  [[ -x "$path" ]] || fail "build script is not executable: $path"
done

CONFIG="$LIVE_DIR/auto/config"
grep -Fq -- '--distribution trixie' "$CONFIG" || fail "distribution is not pinned to Trixie"
grep -Fq -- '--architectures amd64' "$CONFIG" || fail "architecture is not pinned to amd64"
grep -Fq -- '--binary-images iso-hybrid' "$CONFIG" || fail "hybrid ISO output is not enabled"
grep -Fq -- '--bootloaders "syslinux grub-efi"' "$CONFIG" || fail "both BIOS and UEFI bootloaders must be configured"
grep -Fq -- '--uefi-secure-boot enable' "$CONFIG" || fail "Secure Boot must fail closed rather than silently downgrade"
grep -Fq -- '--checksums sha256' "$CONFIG" || fail "in-image SHA-256 checksums are not enabled"
grep -Fq -- '--utc-time true' "$CONFIG" || fail "UTC image timestamps are not enabled"
grep -Fq -- 'console=ttyS0,115200n8' "$CONFIG" || fail "serial console boot argument is required for headless boot smoke tests"

for archive in "$LIVE_DIR/config/archives/debian-backports.list.chroot" "$LIVE_DIR/config/archives/debian-backports.list.binary"; do
  grep -Eq '^[[:space:]]*deb https://deb\.debian\.org/debian trixie-backports ' "$archive" || fail "unexpected or missing Debian Trixie Backports source in $archive"
done

grep -Fxq 'waydroid/trixie-backports' "$PACKAGE_LIST" || fail "Waydroid must be selected explicitly from Trixie Backports"

required_packages=(
  kde-plasma-desktop
  kwin-wayland
  xwayland
  sddm
  network-manager
  firefox-esr
  flatpak
  plasma-discover
  debian-installer-launcher
)
for package in "${required_packages[@]}"; do
  grep -Fxq "$package" "$PACKAGE_LIST" || fail "required image package is missing: $package"
done

duplicates="$(awk '{ sub(/#.*/, ""); for (i = 1; i <= NF; i++) print $i }' "$PACKAGE_LIST" | sort | uniq -d)"
[[ -z "$duplicates" ]] || fail "duplicate package entries found: $duplicates"

# Run live-build against a disposable copy. This checks that the real Trixie
# live-build parser accepts the full option set without touching repo state.
cp -a "$LIVE_DIR/auto" "$LIVE_DIR/config" "$TEMP_DIR/"
(
  cd "$TEMP_DIR"
  ./auto/config
  lb config noauto --validate
  lb config noauto --dump > resolved-live-build-config.txt
)

echo "NOVA live-build configuration is valid (Debian Trixie, amd64, BIOS+UEFI, Secure Boot, SHA-256)."
