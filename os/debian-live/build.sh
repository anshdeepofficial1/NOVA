#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script with sudo: sudo bash ./build.sh" >&2
  exit 1
fi

for tool in lb debootstrap mksquashfs xorriso; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing build dependency: $tool" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -s config/includes.chroot/usr/local/bin/nova-daemon ]]; then
  echo "NOVA daemon binary is missing. Build it and stage it into config/includes.chroot/usr/local/bin/ first." >&2
  exit 1
fi

if ! compgen -G "config/packages.chroot/*.deb" >/dev/null; then
  echo "NOVA Desktop .deb is missing. Run npm run desktop:build and stage the package into config/packages.chroot/ first." >&2
  exit 1
fi

bash "$SCRIPT_DIR/auto/config"
lb build

ISO_PATH="$SCRIPT_DIR/live-image-amd64.hybrid.iso"
if [[ ! -s "$ISO_PATH" ]]; then
  echo "Expected ISO was not created at $ISO_PATH" >&2
  find "$SCRIPT_DIR" -maxdepth 2 -type f -name '*.iso' -print >&2 || true
  exit 1
fi

echo "NOVA ISO built: $ISO_PATH"
sha256sum "$ISO_PATH"
