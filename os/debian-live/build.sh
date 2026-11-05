#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
cd "$SCRIPT_DIR"

CLEAN_MODE="purge"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash os/debian-live/build.sh [--reuse-cache]

Options:
  --reuse-cache   Keep live-build's downloaded package cache while cleaning
                  the generated chroot, binary image and stage state.
  -h, --help      Show this help.

The default is a full purge before configuration/build. This avoids stale
live-build configuration and cached stage state. The build never writes to a
physical disk image; it produces an ISO in this directory.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reuse-cache) CLEAN_MODE="all"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script with sudo: sudo bash os/debian-live/build.sh" >&2
  exit 1
fi

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  echo "The first NOVA image is amd64-only; build on an amd64 host." >&2
  exit 1
fi

for tool in lb debootstrap mksquashfs xorriso dpkg-deb sha256sum file git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing build dependency: $tool" >&2
    exit 1
  fi
done

if [[ ! -s config/includes.chroot/usr/local/bin/nova-daemon ]]; then
  echo "NOVA daemon binary is missing. Build and stage it into config/includes.chroot/usr/local/bin/ first." >&2
  exit 1
fi

mapfile -t NOVA_PACKAGES < <(find config/packages.chroot -maxdepth 1 -type f -name '*.deb' -print | sort)
if [[ ${#NOVA_PACKAGES[@]} -eq 0 ]]; then
  echo "NOVA Desktop .deb is missing. Run npm run desktop:build and stage its package into config/packages.chroot/ first." >&2
  exit 1
fi

for package in "${NOVA_PACKAGES[@]}"; do
  package_arch="$(dpkg-deb --field "$package" Architecture)"
  case "$package_arch" in
    amd64|all) ;;
    *)
      echo "Unsupported staged NOVA package architecture '$package_arch': $package" >&2
      exit 1
      ;;
  esac
done

# The workflow invokes this script through sudo while the checkout remains
# owned by the runner user. Explicit safe.directory avoids Git's ownership
# guard without changing global Git configuration.
git_in_repo() {
  git -c "safe.directory=$ROOT_DIR" -C "$ROOT_DIR" "$@"
}

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git_in_repo log -1 --format=%ct 2>/dev/null || true)"
fi
if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
  echo "SOURCE_DATE_EPOCH must be a Unix timestamp or the source must be a Git checkout." >&2
  exit 1
fi
export SOURCE_DATE_EPOCH
export TZ=UTC

echo "Validating the version-controlled Debian Live configuration..."
bash "$ROOT_DIR/scripts/validate-live-build-config.sh"

echo "Cleaning generated live-build state (mode: $CLEAN_MODE)..."
if [[ "$CLEAN_MODE" == "purge" ]]; then
  lb clean --purge
else
  lb clean --all
fi

echo "Generating live-build configuration from auto/config..."
bash ./auto/config
lb config noauto --validate
lb config noauto --dump > nova-live-build-config.txt

echo "Building NOVA Debian Trixie amd64 live ISO..."
bash ./auto/build

ISO_BASENAME="live-image-amd64.hybrid.iso"
ISO_PATH="$SCRIPT_DIR/$ISO_BASENAME"
if [[ ! -s "$ISO_PATH" ]]; then
  echo "Expected ISO was not created: $ISO_PATH" >&2
  find "$SCRIPT_DIR" -maxdepth 3 -type f -name '*.iso' -print >&2 || true
  exit 1
fi

(
  cd "$SCRIPT_DIR"
  sha256sum "$ISO_BASENAME" > "$ISO_BASENAME.sha256"
)

NOVA_COMMIT="$(git_in_repo rev-parse HEAD 2>/dev/null || printf 'unknown')"
LIVE_BUILD_VERSION="$(lb --version 2>/dev/null | head -n 1 || true)"
ISO_SHA256="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
BUILDINFO_PATH="$ISO_PATH.buildinfo"

cat > "$BUILDINFO_PATH" <<EOF
{
  "project": "NOVA OS",
  "distribution": "Debian 13 (Trixie)",
  "architecture": "amd64",
  "image_type": "iso-hybrid",
  "source_commit": "$NOVA_COMMIT",
  "source_date_epoch": $SOURCE_DATE_EPOCH,
  "live_build_version": "$LIVE_BUILD_VERSION",
  "iso_file": "$ISO_BASENAME",
  "sha256": "$ISO_SHA256"
}
EOF

echo "Validating ISO format, BIOS/UEFI boot catalog, live kernel and root filesystem..."
bash "$ROOT_DIR/scripts/validate-iso.sh" \
  --iso "$ISO_PATH" \
  --checksum "$ISO_PATH.sha256" \
  --report-dir "$SCRIPT_DIR/validation"

echo
echo "NOVA ISO build and structural validation completed."
echo "ISO:        $ISO_PATH"
echo "SHA-256:    $ISO_PATH.sha256"
echo "Build info: $BUILDINFO_PATH"
echo "Build log:  $SCRIPT_DIR/build.log"
