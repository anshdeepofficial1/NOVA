#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "The current NOVA native package target is Linux. Cross-platform sidecar targets are not configured yet." >&2
  exit 1
fi

for command_name in cargo rustc install; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

TARGET_TRIPLE="$(rustc --print host-tuple 2>/dev/null || true)"
if [[ -z "$TARGET_TRIPLE" ]]; then
  TARGET_TRIPLE="$(rustc -Vv | sed -n 's/^host: //p' | head -n 1)"
fi

if [[ -z "$TARGET_TRIPLE" ]]; then
  echo "Could not determine the Rust host target triple." >&2
  exit 1
fi

case "$TARGET_TRIPLE" in
  x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu)
    ;;
  *)
    echo "Unsupported NOVA desktop sidecar target: $TARGET_TRIPLE" >&2
    echo "The first native desktop release currently targets Linux x86_64 and aarch64." >&2
    exit 1
    ;;
esac

echo "Generating the NOVA application icon set..."
npm run icons --workspace @nova/shell

echo "Building NOVA host daemon for $TARGET_TRIPLE..."
cargo build --release --locked --target "$TARGET_TRIPLE" -p nova-daemon

BINARY_SOURCE="$ROOT_DIR/target/$TARGET_TRIPLE/release/nova-daemon"
BINARY_DEST_DIR="$ROOT_DIR/apps/shell/src-tauri/binaries"
BINARY_DEST="$BINARY_DEST_DIR/nova-daemon-$TARGET_TRIPLE"

if [[ ! -s "$BINARY_SOURCE" ]]; then
  echo "Expected NOVA daemon binary was not created: $BINARY_SOURCE" >&2
  exit 1
fi

mkdir -p "$BINARY_DEST_DIR"
install -m 0755 "$BINARY_SOURCE" "$BINARY_DEST"

echo "Staged Tauri sidecar: $BINARY_DEST"
