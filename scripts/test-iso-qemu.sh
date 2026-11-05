#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO_DEFAULT="$ROOT_DIR/os/debian-live/live-image-amd64.hybrid.iso"
DISK_DEFAULT="$ROOT_DIR/.nova-qemu-test.qcow2"

ISO="$ISO_DEFAULT"
DISK="$DISK_DEFAULT"
FIRMWARE="uefi"
MEMORY_MIB="6144"
CPUS="4"
DISK_GIB="40"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/test-iso-qemu.sh [options]

Options:
  --iso PATH          NOVA ISO path (default: os/debian-live/live-image-amd64.hybrid.iso)
  --disk PATH         Disposable VM disk path (default: .nova-qemu-test.qcow2)
  --firmware MODE     uefi (default) or bios
  --memory-mib N      Guest RAM in MiB (default: 6144)
  --cpus N            Virtual CPU count (default: 4)
  --disk-gib N        New qcow2 disk size in GiB (default: 40)
  -h, --help          Show this help

The VM disk is separate from your real disks. The script never partitions or
formats a host disk. Inside the VM, the Debian installer can modify only the
virtual disk you explicitly provide.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="${2:?Missing ISO path}"; shift 2 ;;
    --disk) DISK="${2:?Missing VM disk path}"; shift 2 ;;
    --firmware) FIRMWARE="${2:?Missing firmware mode}"; shift 2 ;;
    --memory-mib) MEMORY_MIB="${2:?Missing memory size}"; shift 2 ;;
    --cpus) CPUS="${2:?Missing CPU count}"; shift 2 ;;
    --disk-gib) DISK_GIB="${2:?Missing disk size}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$FIRMWARE" in
  uefi|bios) ;;
  *) echo "Firmware must be 'uefi' or 'bios'." >&2; exit 2 ;;
esac

for value in "$MEMORY_MIB" "$CPUS" "$DISK_GIB"; do
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Memory, CPU and disk size values must be positive integers." >&2
    exit 2
  fi
done

for tool in qemu-system-x86_64 qemu-img file sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing QEMU test dependency: $tool" >&2
    echo "On Debian/Ubuntu: sudo apt install qemu-system-x86 qemu-utils ovmf" >&2
    exit 1
  fi
done

if [[ ! -s "$ISO" ]]; then
  echo "NOVA ISO not found: $ISO" >&2
  echo "Build it from GitHub Actions → Build NOVA ISO → Run workflow." >&2
  exit 1
fi

echo "ISO:"
file "$ISO"
sha256sum "$ISO"

if [[ -e "$DISK" ]]; then
  echo
  echo "A VM disk already exists: $DISK"
  echo "It will be reused. The guest installer may modify this virtual disk."
  read -r -p "Continue with this existing VM disk? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted; existing VM disk was not touched."; exit 1 ;;
  esac
else
  mkdir -p "$(dirname "$DISK")"
  qemu-img create -f qcow2 "$DISK" "${DISK_GIB}G"
fi

ACCEL="tcg"
CPU_MODEL="max"
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL="kvm"
  CPU_MODEL="host"
  echo "Acceleration: KVM"
else
  echo "Acceleration: TCG software emulation (slower)"
fi

QEMU_ARGS=(
  -machine q35
  -accel "$ACCEL"
  -cpu "$CPU_MODEL"
  -m "$MEMORY_MIB"
  -smp "$CPUS"
  -cdrom "$ISO"
  -boot order=d,menu=on
  -drive "file=$DISK,if=virtio,format=qcow2"
  -netdev user,id=nova_net
  -device virtio-net-pci,netdev=nova_net
  -device virtio-vga
  -display gtk
  -serial mon:stdio
  -rtc base=utc
)

TEMP_VARS=""
cleanup() {
  if [[ -n "$TEMP_VARS" && -f "$TEMP_VARS" ]]; then
    rm -f "$TEMP_VARS"
  fi
}
trap cleanup EXIT

if [[ "$FIRMWARE" == "uefi" ]]; then
  OVMF_CODE=""
  OVMF_VARS=""

  for candidate in /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    if [[ -s "$candidate" ]]; then
      OVMF_CODE="$candidate"
      break
    fi
  done

  if [[ "$OVMF_CODE" == *"_4M.fd" ]]; then
    OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"
  else
    OVMF_VARS="/usr/share/OVMF/OVMF_VARS.fd"
  fi

  if [[ -z "$OVMF_CODE" || ! -s "$OVMF_VARS" ]]; then
    echo "UEFI firmware files were not found. Install the OVMF package or use --firmware bios." >&2
    exit 1
  fi

  TEMP_VARS="$(mktemp)"
  cp "$OVMF_VARS" "$TEMP_VARS"
  QEMU_ARGS+=(
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$TEMP_VARS"
  )
  echo "Firmware: UEFI"
else
  echo "Firmware: legacy BIOS"
fi

echo
echo "Starting NOVA live ISO in QEMU."
echo "Use the VM window to test the live session and installer."
echo "Select the VM disk '$DISK' if you test installation."
echo "Quit QEMU from its window/menu; do not interrupt a guest disk write."
echo
qemu-system-x86_64 "${QEMU_ARGS[@]}"
