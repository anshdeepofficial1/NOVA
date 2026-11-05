#!/usr/bin/env bash
set -euo pipefail

missing=0
for command_name in cargo rustc node npm git; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf 'OK      %s: %s\n' "$command_name" "$(command -v "$command_name")"
  else
    printf 'MISSING %s\n' "$command_name"
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "Install the missing development tools, then run this check again."
  exit 1
fi

echo "Host prerequisites are present. Runtime integrations are not installed by this script."
