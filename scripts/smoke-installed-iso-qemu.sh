#!/usr/bin/env bash
# Install NOVA from a real ISO onto a disposable qcow2 disk and boot without media.
# NEVER use this script on real disks. It accepts only generated qcow2 disks.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="$ROOT/os/debian-live/live-image-amd64.hybrid.iso"
FIRMWARE="uefi"
OUTPUT="$ROOT/os/debian-live/validation/installed"
INSTALL_TIMEOUT=5400
BOOT_TIMEOUT=1200
DISK_GIB=28
RAM_MIB=6144
CPUS=4
QEMU="${NOVA_QEMU_BIN:-qemu-system-x86_64}"
OVMF_DIR="${NOVA_OVMF_DIR:-/usr/share/OVMF}"

usage() {
  cat <<'HELP'
Usage: scripts/smoke-installed-iso-qemu.sh [options]
 --iso PATH               NOVA ISO (defaults to build output)
 --firmware uefi|bios|all  QEMU installation mode (default: uefi)
 --output-dir DIR         Reports, logs and disposable qcow2 disks
 --install-timeout N      Installer seconds (default: 5400)
 --boot-timeout N         Installed-system seconds (default: 1200)

SAFETY: CI ONLY. Creates a fresh qcow2 under the output directory and partitions
ONLY THAT DISK inside QEMU. Uses an initrd-injected CI preseed. Does not alter
the released ISO. Do not run on physical hardware or with valuable VM data.
HELP
}

fail() { echo "NOVA Phase 2 installer smoke FAILED: $*" >&2; exit 1; }
while (( $# )); do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --firmware) FIRMWARE="$2"; shift 2 ;;
    --output-dir) OUTPUT="$2"; shift 2 ;;
    --install-timeout) INSTALL_TIMEOUT="$2"; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown flag: $1" ;;
  esac
done
[[ "$FIRMWARE" == "uefi" || "$FIRMWARE" == "bios" || "$FIRMWARE" == "all" ]] || fail "invalid firmware"
for number in "$INSTALL_TIMEOUT" "$BOOT_TIMEOUT"; do
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || fail "timeouts must be positive integers"
done
[[ -s "$ISO" && -s "$ISO.sha256" ]] || fail "ISO or checksum missing"
for tool in "$QEMU" qemu-img xorriso sha256sum cpio gzip openssl timeout grep stat mktemp; do
  command -v "$tool" >/dev/null || fail "missing dependency: $tool"
done
( cd "$(dirname -- "$ISO")" && sha256sum -c "$(basename -- "$ISO.sha256")" ) || fail "ISO checksum mismatch"

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
[[ "$OUTPUT" != "/" ]] || fail "output directory must not be root"
WORK="$(mktemp -d)"
QEMU_PID=""
cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT

# Locate the real Debian Installer kernel/initrd, not the live-session kernel.
# A missing live-installer is an immediate test failure.
INSTALLER=""
for candidate in /install/vmlinuz /install/gtk/vmlinuz; do
  initrd="${candidate%/*}/initrd.gz"
  if xorriso -indev "$ISO" -find "$candidate" -type f -print 2>/dev/null | grep -Fqx "$candidate" &&
     xorriso -indev "$ISO" -find "$initrd" -type f -print 2>/dev/null | grep -Fqx "$initrd"; then
    INSTALLER="$candidate"
    INITRD="$initrd"
    break
  fi
done
[[ -n "$INSTALLER" ]] || fail "ISO has no /install debian-installer kernel + initrd"
xorriso -osirrox on -indev "$ISO" -extract "$INSTALLER" "$WORK/vmlinuz" >/dev/null 2>&1
xorriso -osirrox on -indev "$ISO" -extract "$INITRD" "$WORK/original-initrd.gz" >/dev/null 2>&1
[[ -s "$WORK/vmlinuz" && -s "$WORK/original-initrd.gz" ]] || fail "installer extraction was empty"
echo "Installer boot assets: $INSTALLER and $INITRD"

# Test-only password: ephemeral machine, no external accounts or production secrets.
PASSWORD_HASH="$(openssl passwd -6 -salt nova-phase2-ci-2026 NOVA-QEMU-Disposable)"
mkdir -p "$WORK/overlay"
cat > "$WORK/overlay/preseed.cfg" <<PRESEED
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string nova-phase2
d-i netcfg/get_domain string local
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i clock-setup/ntp boolean false
d-i passwd/root-login boolean false
d-i passwd/user-fullname string NOVA CI Tester
d-i passwd/username string novatest
d-i passwd/user-password-crypted password $PASSWORD_HASH
d-i user-setup/allow-password-weak boolean true
d-i partman/early_command string test "\$(list-devices disk | tr '\\n' ' ')" = "/dev/vda "
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select Finish partitioning and write changes to disk
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-basicfilesystems/no_swap boolean false
d-i apt-setup/use_mirror boolean false
d-i pkgsel/upgrade select none
tasksel tasksel/first multiselect
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean false
d-i grub-installer/bootdev string /dev/vda
d-i preseed/late_command string cp /nova-phase2-firstboot.sh /target/usr/local/sbin/nova-phase2-firstboot.sh; chmod 0700 /target/usr/local/sbin/nova-phase2-firstboot.sh; cp /nova-phase2-firstboot.service /target/etc/systemd/system/nova-phase2-firstboot.service; touch /target/etc/nova-phase2-ci-only; in-target systemctl enable nova-phase2-firstboot.service; mkdir -p /target/etc/default/grub.d; printf 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"\\n' > /target/etc/default/grub.d/nova-phase2-ci.cfg; in-target update-grub
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/halt boolean true
d-i debian-installer/exit/poweroff boolean true
PRESEED
install -m 0755 "$ROOT/scripts/phase2-firstboot.sh" "$WORK/overlay/nova-phase2-firstboot.sh"
cat > "$WORK/overlay/nova-phase2-firstboot.service" <<'SERVICE'
[Unit]
Description=NOVA disposable VM first-boot acceptance
After=local-fs.target systemd-user-sessions.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nova-phase2-firstboot.sh
TimeoutStartSec=180
[Install]
WantedBy=multi-user.target
SERVICE

# Appending an uncompressed cpio archive to an uncompressed initrd is supported
# by the initramfs format. No preseed is placed inside the release ISO itself.
gzip -dc "$WORK/original-initrd.gz" > "$WORK/initrd.raw"
( cd "$WORK/overlay"; find . -print0 | cpio --null -o -H newc --quiet ) > "$WORK/ci-overlay.cpio"
# GNU cpio stops at the first archive trailer, so verify the injected archive
# separately before concatenating it to the original Debian Installer initrd.
overlay_entries="$(cpio -it --quiet < "$WORK/ci-overlay.cpio")"
grep -Fxq './preseed.cfg' <<< "$overlay_entries" || fail "CI preseed missing from overlay"
grep -Fxq './nova-phase2-firstboot.sh' <<< "$overlay_entries" || fail "CI guest probe missing from overlay"
cat "$WORK/ci-overlay.cpio" >> "$WORK/initrd.raw"
gzip -1 -c "$WORK/initrd.raw" > "$WORK/test-initrd.gz"
[[ -s "$WORK/test-initrd.gz" ]] || fail "could not generate CI installer initrd"

ACCEL="tcg,thread=multi"
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL="kvm"; fi
echo "QEMU acceleration: $ACCEL"
echo "All target disks will be newly created qcow2 images inside $OUTPUT"

boot_firmware_args() {
  local mode="$1"
  FW_ARGS=()
  FW_VARS=""
  if [[ "$mode" == "uefi" ]]; then
    local code="" vars=""
    for prefix in "OVMF_CODE_4M" "OVMF_CODE"; do
      if [[ -s "$OVMF_DIR/${prefix}.fd" ]]; then
        code="$OVMF_DIR/${prefix}.fd"
        if [[ "$prefix" == *4M ]]; then vars="$OVMF_DIR/OVMF_VARS_4M.fd"; else vars="$OVMF_DIR/OVMF_VARS.fd"; fi
        [[ -s "$vars" ]] && break
      fi
    done
    [[ -s "$code" && -s "$vars" ]] || fail "UEFI firmware pair not found"
    FW_VARS="$WORK/ovmf-$mode-vars.fd"
    cp "$vars" "$FW_VARS"
    FW_ARGS=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$code"
             -drive "if=pflash,format=raw,unit=1,file=$FW_VARS")
  fi
}

wait_qemu_exit() {
  local limit="$1" label="$2"
  local waited=0
  while (( waited < limit )); do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      wait "$QEMU_PID" || true
      QEMU_PID=""
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "TIMEOUT: $label after $limit seconds" >&2
  kill "$QEMU_PID" 2>/dev/null || true
  wait "$QEMU_PID" 2>/dev/null || true
  QEMU_PID=""
  return 1
}

run_one() {
  local mode="$1"
  local disk="$OUTPUT/nova-$mode-ci.qcow2"
  local install_log="$OUTPUT/$mode-installer-serial.log"
  local boot_log="$OUTPUT/$mode-installed-serial.log"
  local result="$OUTPUT/$mode-result.txt"
  rm -f "$result"
  # Reject existing files rather than reuse (or overwrite) a disk.
  [[ ! -e "$disk" ]] || fail "refusing to overwrite existing disk: $disk"
  qemu-img create -f qcow2 "$disk" "${DISK_GIB}G" >/dev/null
  [[ "$(qemu-img info --output=json "$disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')" == qcow2 ]] || fail "invalid generated disk format"
  boot_firmware_args "$mode"
  echo "Starting $mode Debian live-installer on a fresh disposable disk"
  "$QEMU" -machine q35 -accel "$ACCEL" -cpu max -m "$RAM_MIB" -smp "$CPUS" -vga std -display none \
    -serial "file:$install_log" -no-reboot \
    -drive "if=virtio,format=qcow2,file=$disk" \
    -cdrom "$ISO" -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    "${FW_ARGS[@]}" -kernel "$WORK/vmlinuz" -initrd "$WORK/test-initrd.gz" \
    -append "auto=true priority=critical console=ttyS0,115200n8 DEBIAN_FRONTEND=text netcfg/choose_interface=auto" \
    > "$OUTPUT/$mode-installer-qemu.log" 2>&1 &
  QEMU_PID=$!
  if ! wait_qemu_exit "$INSTALL_TIMEOUT" "$mode installer"; then
    printf 'mode=%s\nresult=FAIL\nstage=installer_timeout\n' "$mode" > "$result"
    return 1
  fi
  # Shutdown by d-i is necessary but not sufficient; installed disk must boot.
  echo "Installer exited, now booting $mode virtual disk with ISO REMOVED"
  "$QEMU" -machine q35 -accel "$ACCEL" -cpu max -m "$RAM_MIB" -smp "$CPUS" -vga std -display none \
    -serial "file:$boot_log" -no-reboot -boot order=c \
    -drive "if=virtio,format=qcow2,file=$disk" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 "${FW_ARGS[@]}" \
    > "$OUTPUT/$mode-installed-qemu.log" 2>&1 &
  QEMU_PID=$!
  local waited=0
  while (( waited < BOOT_TIMEOUT )); do
    if [[ -f "$boot_log" ]] && grep -Fq 'NOVA_PHASE2_GUEST_PASS' "$boot_log"; then
      echo "PASS: $mode installed NOVA booted without ISO and verified desktop packages + daemon"
      printf 'mode=%s\nresult=PASS\npostinstall=verified\n' "$mode" > "$result"
      wait_qemu_exit 90 "$mode guest shutdown" || true
      return 0
    fi
    if [[ -f "$boot_log" ]] && grep -Fq 'NOVA_PHASE2_GUEST_FAIL' "$boot_log"; then
      echo "Guest acceptance failure:" >&2
      tail -n 60 "$boot_log" >&2
      printf 'mode=%s\nresult=FAIL\nstage=first_boot_checks\n' "$mode" > "$result"
      return 1
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      wait "$QEMU_PID" 2>/dev/null || true
      QEMU_PID=""
      echo "Installed $mode guest stopped before acceptance" >&2
      [[ ! -f "$boot_log" ]] || tail -n 80 "$boot_log" >&2
      printf 'mode=%s\nresult=FAIL\nstage=early_shutdown\n' "$mode" > "$result"
      return 1
    fi
    sleep 5
    waited=$((waited+5))
  done
  echo "Installed $mode boot timed out" >&2
  [[ ! -f "$boot_log" ]] || tail -n 80 "$boot_log" >&2
  printf 'mode=%s\nresult=FAIL\nstage=boot_timeout\n' "$mode" > "$result"
  return 1
}

modes=("$FIRMWARE")
if [[ "$FIRMWARE" == "all" ]]; then modes=(uefi bios); fi
failed=0
for mode in "${modes[@]}"; do
  if ! run_one "$mode"; then failed=$((failed+1)); fi
done
if (( failed > 0 )); then fail "$failed/${#modes[@]} installer and first-boot paths failed"; fi
echo "NOVA Phase 2 disposable installer smoke PASS (${modes[*]})"
