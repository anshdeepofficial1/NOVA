#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
LIVE_DIR="$ROOT_DIR/os/debian-live"
PACKAGE_LIST="$LIVE_DIR/config/package-lists/nova-desktop.list.chroot"
GRUB_CONFIG="$LIVE_DIR/config/bootloaders/grub-pc/config.cfg"
ISOLINUX_CONFIG="$LIVE_DIR/config/bootloaders/isolinux/isolinux.cfg"
FIRSTBOOT_SCRIPT="$LIVE_DIR/config/includes.chroot/usr/local/sbin/nova-firstboot-init"
FIRSTBOOT_UNIT="$LIVE_DIR/config/includes.chroot/usr/lib/systemd/system/nova-firstboot.service"
FIRSTBOOT_HOOK="$LIVE_DIR/config/hooks/live/9000-enable-nova-firstboot.hook.chroot"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "NOVA live-build configuration validation failed: $*" >&2
  exit 1
}

for tool in lb awk sort uniq grep cp mktemp grub-script-check; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

for path in \
  "$LIVE_DIR/auto/config" \
  "$LIVE_DIR/auto/clean" \
  "$LIVE_DIR/auto/build" \
  "$LIVE_DIR/build.sh" \
  "$LIVE_DIR/config/archives/debian-backports.list.chroot" \
  "$LIVE_DIR/config/archives/debian-backports.list.binary" \
  "$PACKAGE_LIST" \
  "$GRUB_CONFIG" \
  "$ISOLINUX_CONFIG" \
  "$FIRSTBOOT_SCRIPT" \
  "$FIRSTBOOT_UNIT" \
  "$FIRSTBOOT_HOOK"; do
  [[ -s "$path" ]] || fail "required file is missing or empty: $path"
done

for path in "$LIVE_DIR/auto/config" "$LIVE_DIR/auto/clean" "$LIVE_DIR/auto/build" "$LIVE_DIR/build.sh"; do
  [[ -x "$path" ]] || fail "build script is not executable: $path"
done

# Verify first boot will actually be installed and enabled, not just documented.
[[ -x "$FIRSTBOOT_SCRIPT" ]] || fail "installed NOVA first-boot script must be executable"
[[ -x "$FIRSTBOOT_HOOK" ]] || fail "live-build first-boot enable hook must be executable"
bash -n "$FIRSTBOOT_SCRIPT"
sh -n "$FIRSTBOOT_HOOK"
grep -Fq 'systemctl enable nova-firstboot.service' "$FIRSTBOOT_HOOK" || fail "NOVA first-boot service is not enabled"
grep -Fq 'ExecStart=/usr/local/sbin/nova-firstboot-init' "$FIRSTBOOT_UNIT" || fail "first-boot service has incorrect executable"
grep -Fq 'ConditionPathExists=!/run/live/medium' "$FIRSTBOOT_UNIT" || fail "first-boot service must never mark live ISO boots"
grep -Fq 'StateDirectory=nova' "$FIRSTBOOT_UNIT" || fail "first-boot state directory is not protected"

CONFIG="$LIVE_DIR/auto/config"
grep -Fq -- '--distribution trixie' "$CONFIG" || fail "distribution is not pinned to Trixie"
grep -Fq -- '--architectures amd64' "$CONFIG" || fail "architecture is not pinned to amd64"
grep -Fq -- '--binary-images iso-hybrid' "$CONFIG" || fail "hybrid ISO output is not enabled"
grep -Fq -- '--bootloaders "syslinux grub-efi"' "$CONFIG" || fail "both BIOS and UEFI bootloaders must be configured"
grep -Fq -- '--uefi-secure-boot enable' "$CONFIG" || fail "Secure Boot must be enabled, not silently downgraded"
grep -Fq -- '--checksums sha256' "$CONFIG" || fail "in-image SHA-256 checksums are not enabled"
grep -Fq -- '--utc-time true' "$CONFIG" || fail "UTC image timestamps are not enabled"
grep -Fq -- 'console=ttyS0,115200n8' "$CONFIG" || fail "serial kernel console is required for headless boot validation"

# Retain the graphical menu and mirror GRUB input/output to serial so that
# firmware-to-kernel transitions are observable in headless boot tests.
grep -Fq 'set timeout=8' "$GRUB_CONFIG" || fail "GRUB must auto-boot the default live entry after a visible timeout"
grep -Fq 'serial --unit=0 --speed=115200' "$GRUB_CONFIG" || fail "GRUB serial port is not initialized"
grep -Fq 'terminal_input --append serial' "$GRUB_CONFIG" || fail "GRUB serial input is not enabled"
grep -Fq 'terminal_output --append serial' "$GRUB_CONFIG" || fail "GRUB serial output is not enabled"
grep -Fq 'source /boot/grub/theme.cfg' "$GRUB_CONFIG" || fail "default NOVA GRUB theme configuration must be preserved"
grep -Fq 'insmod gfxterm' "$GRUB_CONFIG" || fail "graphical GRUB terminal must remain available"
grep -Fq 'terminal_output gfxterm' "$GRUB_CONFIG" || fail "graphical GRUB output must remain the primary display"
grub-script-check "$GRUB_CONFIG" >/dev/null || fail "custom GRUB configuration has invalid syntax"

# Debian Live defaults Syslinux derivatives to an indefinite timeout. Keep
# the menu visible but automatically start the default live entry after 5s.
grep -Fxq 'include menu.cfg' "$ISOLINUX_CONFIG" || fail "ISOLINUX must include the Debian Live menu entries"
grep -Fxq 'default vesamenu.c32' "$ISOLINUX_CONFIG" || fail "ISOLINUX must use the graphical menu"
grep -Fxq 'prompt 0' "$ISOLINUX_CONFIG" || fail "ISOLINUX must allow automatic menu timeout"
grep -Fxq 'timeout 50' "$ISOLINUX_CONFIG" || fail "ISOLINUX must automatically boot after five seconds"

for archive in "$LIVE_DIR/config/archives/debian-backports.list.chroot" "$LIVE_DIR/config/archives/debian-backports.list.binary"; do
  grep -Eq '^[[:space:]]*deb https?://deb\.debian\.org/debian trixie-backports ' "$archive" || fail "unexpected or missing Debian Trixie Backports source in $archive"
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

# Run live-build against a disposable copy. This checks that the Trixie
# live-build parser accepts the full option set without touching repo state.
cp -a "$LIVE_DIR/auto" "$LIVE_DIR/config" "$TEMP_DIR/"
(
  cd "$TEMP_DIR"
  ./auto/config
  lb config noauto --validate
  lb config noauto --dump > resolved-live-build-config.txt
)

echo "NOVA live-build configuration is valid (Debian Trixie, amd64, BIOS auto-boot, UEFI, Secure Boot, graphical+serial GRUB)."
