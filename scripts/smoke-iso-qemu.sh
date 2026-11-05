#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
ISO_DEFAULT="$ROOT_DIR/os/debian-live/live-image-amd64.hybrid.iso"
ISO="$ISO_DEFAULT"
FIRMWARE="all"
TIMEOUT_SECONDS="900"
MEMORY_MIB="6144"
CPUS="4"
LOG_DIR="$ROOT_DIR/os/debian-live/validation/qemu"
QEMU_BIN="${NOVA_QEMU_BIN:-qemu-system-x86_64}"
OVMF_DIR="${NOVA_OVMF_DIR:-/usr/share/OVMF}"
MONITOR_CONNECT_TIMEOUT="${NOVA_QEMU_MONITOR_CONNECT_TIMEOUT:-4}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/smoke-iso-qemu.sh [options]

Options:
  --iso PATH             NOVA ISO path
  --firmware MODE        all (default), both, uefi, uefi-secure or bios
  --timeout-seconds N    Per-firmware boot timeout (default: 900)
  --memory-mib N         Guest memory in MiB (default: 6144)
  --cpus N               Virtual CPU count (default: 4)
  --log-dir PATH         Directory for serial, monitor and QEMU logs
  -h, --help             Show this help

Tests are non-installing and create no virtual disk. They independently boot
legacy BIOS, standard UEFI and Secure Boot UEFI paths (for "all"), then wait
for the live system's serial login prompt. A QEMU monitor screenshot and
status are saved for each firmware path for post-failure diagnosis.
USAGE
}

die() {
  echo "NOVA QEMU ISO smoke test failed: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) [[ $# -ge 2 ]] || die "--iso requires a path"; ISO="$2"; shift 2 ;;
    --firmware) [[ $# -ge 2 ]] || die "--firmware requires a mode"; FIRMWARE="$2"; shift 2 ;;
    --timeout-seconds) [[ $# -ge 2 ]] || die "--timeout-seconds requires a value"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --memory-mib) [[ $# -ge 2 ]] || die "--memory-mib requires a value"; MEMORY_MIB="$2"; shift 2 ;;
    --cpus) [[ $# -ge 2 ]] || die "--cpus requires a value"; CPUS="$2"; shift 2 ;;
    --log-dir) [[ $# -ge 2 ]] || die "--log-dir requires a path"; LOG_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -s "$ISO" ]] || die "ISO not found or empty: $ISO"
case "$FIRMWARE" in
  all|both|uefi|uefi-secure|bios) ;;
  *) die "firmware must be all, both, uefi, uefi-secure or bios" ;;
esac

for value in "$TIMEOUT_SECONDS" "$MEMORY_MIB" "$CPUS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "timeout, memory and CPU values must be positive integers"
done

for tool in "$QEMU_BIN" python3 grep tail timeout; do
  command -v "$tool" >/dev/null 2>&1 || die "missing QEMU test dependency: $tool"
done

mkdir -p "$LOG_DIR"
QEMU_PID=""
TEMP_VARS=""
MONITOR_DIR=""

stop_qemu() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  QEMU_PID=""
}

cleanup() {
  stop_qemu
  [[ -z "$TEMP_VARS" ]] || rm -f "$TEMP_VARS"
  [[ -z "$MONITOR_DIR" ]] || rm -rf "$MONITOR_DIR"
}
trap cleanup EXIT

capture_diagnostics() {
  local monitor_socket="$1"
  local screenshot="$2"
  local monitor_log="$3"

  python3 - "$monitor_socket" "$screenshot" "$monitor_log" "$MONITOR_CONNECT_TIMEOUT" <<'PY' || true
import socket
import sys
import time

socket_path, screenshot_path, log_path, timeout_seconds = sys.argv[1:]
chunks = []
connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.settimeout(0.4)
try:
    deadline = time.monotonic() + float(timeout_seconds)
    while True:
        try:
            connection.connect(socket_path)
            break
        except (FileNotFoundError, ConnectionRefusedError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)

    try:
        chunks.append(connection.recv(65536))
    except socket.timeout:
        pass

    for command in ("info status", f"screendump {screenshot_path}"):
        connection.sendall((command + "\n").encode())
        time.sleep(0.25)
        try:
            while True:
                block = connection.recv(65536)
                if not block:
                    break
                chunks.append(block)
                if len(block) < 65536:
                    break
        except socket.timeout:
            pass
finally:
    connection.close()

with open(log_path, "wb") as output:
    output.write(b"\n".join(chunks))
PY
}

firmware_pair() {
  local mode="$1"
  local code vars

  if [[ "$mode" == "uefi-secure" ]]; then
    for code in "$OVMF_DIR/OVMF_CODE_4M.ms.fd" "$OVMF_DIR/OVMF_CODE_4M.secboot.fd"; do
      vars="$OVMF_DIR/OVMF_VARS_4M.ms.fd"
      if [[ -s "$code" && -s "$vars" ]]; then
        printf '%s\n%s\n' "$code" "$vars"
        return 0
      fi
    done
    for code in "$OVMF_DIR/OVMF_CODE.ms.fd" "$OVMF_DIR/OVMF_CODE.secboot.fd"; do
      vars="$OVMF_DIR/OVMF_VARS.ms.fd"
      if [[ -s "$code" && -s "$vars" ]]; then
        printf '%s\n%s\n' "$code" "$vars"
        return 0
      fi
    done
  else
    for code in "$OVMF_DIR/OVMF_CODE_4M.fd" "$OVMF_DIR/OVMF_CODE.fd" /usr/share/qemu/OVMF_CODE.fd; do
      case "$code" in
        *_4M.fd) vars="$OVMF_DIR/OVMF_VARS_4M.fd" ;;
        *) vars="${code%CODE*}VARS.fd" ;;
      esac
      if [[ -s "$code" && -s "$vars" ]]; then
        printf '%s\n%s\n' "$code" "$vars"
        return 0
      fi
    done
  fi
  return 1
}

release_firmware_state() {
  stop_qemu
  [[ -z "$TEMP_VARS" ]] || rm -f "$TEMP_VARS"
  TEMP_VARS=""
  [[ -z "$MONITOR_DIR" ]] || rm -rf "$MONITOR_DIR"
  MONITOR_DIR=""
}

run_firmware_test() {
  local mode="$1"
  local serial_log="$LOG_DIR/$mode.serial.log"
  local qemu_log="$LOG_DIR/$mode.qemu.log"
  local monitor_log="$LOG_DIR/$mode.monitor.log"
  local screenshot="$LOG_DIR/$mode.ppm"
  local result_file="$LOG_DIR/$mode.result.txt"
  local machine="q35"
  local firmware_code=""
  local firmware_vars=""
  local elapsed=0
  local pair=""
  local -a args=(
    -accel tcg,thread=multi
    -cpu max
    -m "$MEMORY_MIB"
    -smp "$CPUS"
    -vga std
    -cdrom "$ISO"
    -boot order=d,menu=off
    -display none
    -serial "file:$serial_log"
    -no-reboot
    -rtc base=utc
  )

  : > "$serial_log"
  : > "$qemu_log"
  : > "$monitor_log"
  rm -f "$screenshot" "$result_file"

  if [[ "$mode" != "bios" ]]; then
    if ! pair="$(firmware_pair "$mode")"; then
      printf 'Firmware: %s\nResult: FAIL\nReason: Matching OVMF firmware and variable-store files are unavailable.\n' "$mode" > "$result_file"
      echo "FAIL: required OVMF firmware pair for $mode was not found." >&2
      return 1
    fi
    firmware_code="$(printf '%s\n' "$pair" | sed -n '1p')"
    firmware_vars="$(printf '%s\n' "$pair" | sed -n '2p')"
    TEMP_VARS="$(mktemp)"
    cp "$firmware_vars" "$TEMP_VARS"
    if [[ "$mode" == "uefi-secure" ]]; then
      machine="q35,smm=on"
      args+=( -global driver=cfi.pflash01,property=secure,value=on )
    fi
    args+=(
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=$firmware_code"
      -drive "if=pflash,format=raw,unit=1,file=$TEMP_VARS"
    )
  fi

  MONITOR_DIR="$(mktemp -d)"
  local monitor_socket="$MONITOR_DIR/hmp.sock"
  args+=( -monitor "unix:$monitor_socket,server=on,wait=off" )

  echo "Boot smoke test: $mode"
  timeout --signal=TERM "$((TIMEOUT_SECONDS + 30))" "$QEMU_BIN" -machine "$machine" "${args[@]}" > "$qemu_log" 2>&1 &
  QEMU_PID=$!

  while (( elapsed < TIMEOUT_SECONDS )); do
    if grep -Eiq 'login:' "$serial_log"; then
      capture_diagnostics "$monitor_socket" "$screenshot" "$monitor_log"
      release_firmware_state
      printf 'Firmware: %s\nResult: PASS\nReadiness: systemd serial login prompt\nElapsed seconds: %s\n' "$mode" "$elapsed" > "$result_file"
      echo "PASS: $mode reached the live system's serial login prompt after about $elapsed seconds."
      return 0
    fi

    if grep -Eiq 'Kernel panic - not syncing|No working init found|You are in emergency mode|Give root password for maintenance|Unable to find a medium containing a live file system|Failed to execute /sbin/init' "$serial_log"; then
      echo "FAIL: $mode reported a kernel or live-system boot failure." >&2
      capture_diagnostics "$monitor_socket" "$screenshot" "$monitor_log"
      printf 'Firmware: %s\nResult: FAIL\nReason: Kernel panic, emergency mode or live-root failure detected.\nElapsed seconds: %s\n' "$mode" "$elapsed" > "$result_file"
      tail -n 120 "$serial_log" >&2 || true
      release_firmware_state
      return 1
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      wait "$QEMU_PID" 2>/dev/null || true
      QEMU_PID=""
      capture_diagnostics "$monitor_socket" "$screenshot" "$monitor_log"
      printf 'Firmware: %s\nResult: FAIL\nReason: QEMU exited before the serial login prompt.\nElapsed seconds: %s\n' "$mode" "$elapsed" > "$result_file"
      echo "FAIL: $mode QEMU process exited before a login prompt. Serial output:" >&2
      tail -n 120 "$serial_log" >&2 || true
      echo "QEMU output:" >&2
      tail -n 120 "$qemu_log" >&2 || true
      release_firmware_state
      return 1
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "FAIL: $mode did not reach the serial login prompt within $TIMEOUT_SECONDS seconds." >&2
  capture_diagnostics "$monitor_socket" "$screenshot" "$monitor_log"
  printf 'Firmware: %s\nResult: FAIL\nReason: Serial login prompt timeout.\nElapsed seconds: %s\n' "$mode" "$elapsed" > "$result_file"
  echo "Serial output:" >&2
  tail -n 120 "$serial_log" >&2 || true
  echo "QEMU output:" >&2
  tail -n 120 "$qemu_log" >&2 || true
  release_firmware_state
  return 1
}

case "$FIRMWARE" in
  all) FIRMWARES=(bios uefi uefi-secure) ;;
  both) FIRMWARES=(bios uefi) ;;
  uefi|uefi-secure|bios) FIRMWARES=("$FIRMWARE") ;;
esac

FAILURES=0
for mode in "${FIRMWARES[@]}"; do
  if ! run_firmware_test "$mode"; then
    FAILURES=$((FAILURES + 1))
  fi
done

if (( FAILURES > 0 )); then
  echo "NOVA ISO QEMU firmware smoke tests: $FAILURES/${#FIRMWARES[@]} failed." >&2
  exit 1
fi

echo "NOVA ISO QEMU firmware smoke tests passed (${FIRMWARES[*]})."
