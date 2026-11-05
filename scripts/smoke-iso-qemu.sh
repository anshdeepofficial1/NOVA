#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
ISO_DEFAULT="$ROOT_DIR/os/debian-live/live-image-amd64.hybrid.iso"
ISO="$ISO_DEFAULT"
FIRMWARE="both"
TIMEOUT_SECONDS="600"
MEMORY_MIB="4096"
CPUS="2"
LOG_DIR="$ROOT_DIR/os/debian-live/validation/qemu"

usage() {
  cat <<'USAGE'
Usage:
  scripts/smoke-iso-qemu.sh [options]

Options:
  --iso PATH             NOVA ISO path
  --firmware MODE        both (default), uefi or bios
  --timeout-seconds N    Per-firmware boot timeout (default: 600)
  --memory-mib N         Guest memory in MiB (default: 4096)
  --cpus N               Virtual CPU count (default: 2)
  --log-dir PATH         Directory for serial and QEMU logs
  -h, --help             Show this help

This is a headless, non-installing smoke test. It boots the live ISO and waits
for systemd to expose a serial login prompt. It creates no virtual disk and
does not exercise the installer or claim that the graphical desktop works.
USAGE
}

fail() {
  echo "NOVA QEMU ISO smoke test failed: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --firmware) FIRMWARE="$2"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="$2"; shift 2 ;;
    --memory-mib) MEMORY_MIB="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -s "$ISO" ]] || fail "ISO not found: $ISO"
case "$FIRMWARE" in
  both|uefi|bios) ;;
  *) fail "firmware must be both, uefi or bios" ;;
esac

for value in "$TIMEOUT_SECONDS" "$MEMORY_MIB" "$CPUS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "timeout, memory and CPU values must be positive integers"
done

for tool in qemu-system-x86_64 grep; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing QEMU test dependency: $tool"
done

mkdir -p "$LOG_DIR"
QEMU_PID=""
TEMP_VARS=""

cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if [[ -n "$TEMP_VARS" ]]; then
    rm -f "$TEMP_VARS"
  fi
}
trap cleanup EXIT

run_firmware_test() {
  local mode="$1"
  local serial_log="$LOG_DIR/$mode.serial.log"
  local qemu_log="$LOG_DIR/$mode.qemu.log"
  local -a args=(
    -machine q35
    -accel tcg
    -cpu max
    -m "$MEMORY_MIB"
    -smp "$CPUS"
    -cdrom "$ISO"
    -boot order=d,menu=off
    -display none
    -serial "file:$serial_log"
    -monitor none
    -no-reboot
    -rtc base=utc
  )

  : > "$serial_log"
  : > "$qemu_log"
  TEMP_VARS=""

  if [[ "$mode" == "uefi" ]]; then
    local firmware_code=""
    local firmware_vars=""
    local candidate

    for candidate in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/qemu/OVMF_CODE.fd; do
      if [[ -s "$candidate" ]]; then
        firmware_code="$candidate"
        break
      fi
    done

    [[ -n "$firmware_code" ]] || fail "UEFI firmware not found; install OVMF"

    if [[ "$firmware_code" == *"_4M.fd" ]]; then
      firmware_vars="/usr/share/OVMF/OVMF_VARS_4M.fd"
    else
      firmware_vars="/usr/share/OVMF/OVMF_VARS.fd"
    fi
    [[ -s "$firmware_vars" ]] || fail "matching UEFI variable store not found: $firmware_vars"

    TEMP_VARS="$(mktemp)"
    cp "$firmware_vars" "$TEMP_VARS"
    args+=(
      -drive "if=pflash,format=raw,readonly=on,file=$firmware_code"
      -drive "if=pflash,format=raw,file=$TEMP_VARS"
    )
  fi

  echo "Boot smoke test: $mode"
  qemu-system-x86_64 "${args[@]}" > "$qemu_log" 2>&1 &
  QEMU_PID=$!

  local elapsed=0
  while (( elapsed < TIMEOUT_SECONDS )); do
    if grep -Eiq 'login:' "$serial_log"; then
      echo "PASS: $mode reached a systemd serial login prompt after about $elapsed seconds."
      kill -TERM "$QEMU_PID" 2>/dev/null || true
      wait "$QEMU_PID" 2>/dev/null || true
      QEMU_PID=""
      if [[ -n "$TEMP_VARS" ]]; then
        rm -f "$TEMP_VARS"
        TEMP_VARS=""
      fi
      return 0
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      wait "$QEMU_PID" 2>/dev/null || true
      QEMU_PID=""
      echo "QEMU exited before a login prompt. Serial output:" >&2
      tail -n 100 "$serial_log" >&2 || true
      echo "QEMU output:" >&2
      tail -n 100 "$qemu_log" >&2 || true
      fail "$mode boot did not reach the serial login prompt"
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "Timed out waiting for $mode serial login prompt. Serial output:" >&2
  tail -n 100 "$serial_log" >&2 || true
  echo "QEMU output:" >&2
  tail -n 100 "$qemu_log" >&2 || true
  fail "$mode boot exceeded $TIMEOUT_SECONDS seconds"
}

case "$FIRMWARE" in
  both)
    run_firmware_test uefi
    run_firmware_test bios
    ;;
  uefi)
    run_firmware_test uefi
    ;;
  bios)
    run_firmware_test bios
    ;;
esac

echo "NOVA ISO QEMU firmware smoke tests passed."
