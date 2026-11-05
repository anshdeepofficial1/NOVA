#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE_SCRIPT="$ROOT_DIR/scripts/smoke-iso-qemu.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "NOVA QEMU smoke harness test failed: $*" >&2
  exit 1
}

mkdir -p "$TEMP_DIR/ovmf"
for name in OVMF_CODE_4M.fd OVMF_VARS_4M.fd OVMF_CODE_4M.ms.fd OVMF_VARS_4M.ms.fd; do
  printf x > "$TEMP_DIR/ovmf/$name"
done
printf x > "$TEMP_DIR/test.iso"

cat > "$TEMP_DIR/qemu-fail" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'fail\n' >> "$MOCK_QEMU_CALLS"
exit 23
MOCK
chmod +x "$TEMP_DIR/qemu-fail"

set +e
MOCK_QEMU_CALLS="$TEMP_DIR/fail.calls" \
NOVA_QEMU_BIN="$TEMP_DIR/qemu-fail" \
NOVA_OVMF_DIR="$TEMP_DIR/ovmf" \
NOVA_QEMU_MONITOR_CONNECT_TIMEOUT=0.1 \
bash "$SMOKE_SCRIPT" \
  --iso "$TEMP_DIR/test.iso" \
  --firmware all \
  --timeout-seconds 2 \
  --log-dir "$TEMP_DIR/fail-logs" > "$TEMP_DIR/fail.stdout" 2> "$TEMP_DIR/fail.stderr"
fail_status=$?
set -e

[[ "$fail_status" -ne 0 ]] || fail "an all-firmware run passed despite all QEMU instances exiting immediately"
[[ "$(wc -l < "$TEMP_DIR/fail.calls")" -eq 3 ]] || fail "a failure prevented one or more firmware attempts"
for mode in uefi uefi-secure bios; do
  [[ -s "$TEMP_DIR/fail-logs/$mode.result.txt" ]] || fail "$mode did not write a result file"
  grep -Fq 'Result: FAIL' "$TEMP_DIR/fail-logs/$mode.result.txt" || fail "$mode failure was not recorded"
done

cat > "$TEMP_DIR/qemu-pass" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pass\n' >> "$MOCK_QEMU_CALLS"
serial_log=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-serial" ]]; then
    serial_log="${2#file:}"
    shift 2
  else
    shift
  fi
done
[[ -n "$serial_log" ]] || exit 24
(
  sleep 0.2
  printf 'nova login:\n' >> "$serial_log"
) &
writer_pid=$!
trap 'kill "$writer_pid" 2>/dev/null || true; exit 0' TERM INT
while :; do sleep 0.1; done
MOCK
chmod +x "$TEMP_DIR/qemu-pass"

MOCK_QEMU_CALLS="$TEMP_DIR/pass.calls" \
NOVA_QEMU_BIN="$TEMP_DIR/qemu-pass" \
NOVA_OVMF_DIR="$TEMP_DIR/ovmf" \
NOVA_QEMU_MONITOR_CONNECT_TIMEOUT=0.1 \
bash "$SMOKE_SCRIPT" \
  --iso "$TEMP_DIR/test.iso" \
  --firmware all \
  --timeout-seconds 3 \
  --log-dir "$TEMP_DIR/pass-logs" > "$TEMP_DIR/pass.stdout" 2> "$TEMP_DIR/pass.stderr" \
  || fail "successful mocked live boots were not recognized"

[[ "$(wc -l < "$TEMP_DIR/pass.calls")" -eq 3 ]] || fail "success path did not execute all firmware tests"
for mode in uefi uefi-secure bios; do
  [[ -s "$TEMP_DIR/pass-logs/$mode.result.txt" ]] || fail "$mode did not write a success result file"
  grep -Fq 'Result: PASS' "$TEMP_DIR/pass-logs/$mode.result.txt" || fail "$mode success was not recorded"
done

printf 'PASS: the QEMU smoke harness independently executes all three firmware paths, aggregates failures, and recognizes a live login prompt.\n'
