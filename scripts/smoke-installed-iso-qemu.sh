#!/usr/bin/env bash
# Install NOVA from a real ISO onto a disposable qcow2 disk and boot without media.
# NEVER use this script on real disks. It accepts only generated qcow2 disks.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="$ROOT/os/debian-live/live-image-amd64.hybrid.iso"
FIRMWARE="uefi"
GRAPHICAL=false
FILESYSTEM="ext4"
PRESERVE_SECONDARY=false
BTRFS_LAYOUT=false
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
 --graphical              Verify a real SDDM/Wayland/NOVA Desktop user session
 --filesystem ext4|btrfs  Installed root filesystem (CI only; default ext4)
 --preserve-secondary     Verify second writable non-target disk unchanged
 --btrfs-layout           CI-only persistent subvolumes and snapshot restore
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
    --graphical) GRAPHICAL=true; shift ;;
    --filesystem) FILESYSTEM="$2"; shift 2 ;;
    --preserve-secondary) PRESERVE_SECONDARY=true; shift ;;
    --btrfs-layout) BTRFS_LAYOUT=true; shift ;;
    --output-dir) OUTPUT="$2"; shift 2 ;;
    --install-timeout) INSTALL_TIMEOUT="$2"; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown flag: $1" ;;
  esac
done
[[ "$FIRMWARE" == "uefi" || "$FIRMWARE" == "bios" || "$FIRMWARE" == "all" ]] || fail "invalid firmware"
[[ "$FILESYSTEM" == ext4 || "$FILESYSTEM" == btrfs ]] || fail "invalid filesystem"
[[ "$BTRFS_LAYOUT" != true || "$FILESYSTEM" == btrfs ]] || fail "--btrfs-layout requires --filesystem btrfs"
for number in "$INSTALL_TIMEOUT" "$BOOT_TIMEOUT"; do
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || fail "timeouts must be positive integers"
done
[[ -s "$ISO" && -s "$ISO.sha256" ]] || fail "ISO or checksum missing"
for tool in "$QEMU" qemu-img xorriso sha256sum cpio gzip openssl timeout grep stat mktemp python3; do
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

# Locate actual Debian Installer assets by extraction, not by treating
# xorriso's ISO tree API as the unrelated Unix find(1) command.
INSTALLER=""
for candidate in /install/vmlinuz /install/gtk/vmlinuz; do
  initrd="${candidate%/*}/initrd.gz"
  rm -f "$WORK/vmlinuz" "$WORK/original-initrd.gz"
  if xorriso -osirrox on -indev "$ISO" -extract "$candidate" "$WORK/vmlinuz" >/dev/null 2>&1 &&
     xorriso -osirrox on -indev "$ISO" -extract "$initrd" "$WORK/original-initrd.gz" >/dev/null 2>&1 &&
     [[ -s "$WORK/vmlinuz" && -s "$WORK/original-initrd.gz" ]]; then
    INSTALLER="$candidate"
    INITRD="$initrd"
    break
  fi
done
if [[ -z "$INSTALLER" ]]; then
  echo "Actual /install files found in the ISO:" >&2
  xorriso -indev "$ISO" -ls /install 2>&1 | tail -n 80 >&2 || true
  fail "ISO has no extractable debian-installer kernel + initrd"
fi
echo "Installer boot assets: $INSTALLER and $INITRD"

# Test-only password: ephemeral machine, no external accounts or production secrets.
PASSWORD_HASH="$(openssl passwd -6 -salt nova-phase2-ci-2026 NOVA-QEMU-Disposable)"
mkdir -p "$WORK/overlay"
PARTMAN_DISKS="/dev/vda "
if [[ "$PRESERVE_SECONDARY" == true ]]; then PARTMAN_DISKS="/dev/vda /dev/vdb "; fi
LAYOUT_LATE=""
if [[ "$BTRFS_LAYOUT" == true ]]; then
  LAYOUT_LATE='; cp /nova-phase2-btrfs-layout-ci.sh /target/usr/local/sbin/nova-phase2-btrfs-layout-ci.sh; chmod 0700 /target/usr/local/sbin/nova-phase2-btrfs-layout-ci.sh; in-target /usr/local/sbin/nova-phase2-btrfs-layout-ci.sh'
fi
GRAPHICAL_LATE=""
SERVICE_AFTER="local-fs.target systemd-user-sessions.service"
SERVICE_WANTED="multi-user.target"
SERVICE_TIMEOUT=180
if [[ "$GRAPHICAL" == true ]]; then
  # The only passwordless GUI login is inside a throwaway CI guest, never
  # shipped in the NOVA ISO or installed onto any physical disk.
  cat > "$WORK/overlay/nova-phase2-autologin.conf" <<'AUTOLOGIN'
[Autologin]
User=novatest
Session=plasma.desktop
Relogin=false
AUTOLOGIN
  GRAPHICAL_LATE='; mkdir -p /target/etc/sddm.conf.d; cp /nova-phase2-autologin.conf /target/etc/sddm.conf.d/zz-nova-phase2-ci-autologin.conf; touch /target/etc/nova-phase2-ci-graphical'
  SERVICE_AFTER="local-fs.target systemd-user-sessions.service display-manager.service"
  SERVICE_WANTED="graphical.target"
  # Graphical wait (180s) + user API (45s) + screenshot grace (110s).
  SERVICE_TIMEOUT=480
fi
cat > "$WORK/overlay/preseed.cfg" <<PRESEED
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string nova-phase2
d-i netcfg/get_domain string local
# Initrd preseeding occurs before file/network preseed hooks; prove it was
# applied during the real partitioning stage instead of using early_command.
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
d-i partman/early_command string test "\$(list-devices disk | tr '\\n' ' ')" = "$PARTMAN_DISKS" && echo NOVA_PHASE2_PRESEED_LOADED >/dev/ttyS0
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman/default_filesystem string $FILESYSTEM
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-basicfilesystems/no_swap boolean false
d-i apt-setup/use_mirror boolean false
d-i pkgsel/upgrade select none
tasksel tasksel/first multiselect
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean false
d-i grub-installer/bootdev string /dev/vda
d-i preseed/late_command string set -e; cp /nova-phase2-firstboot.sh /target/usr/local/sbin/nova-phase2-firstboot.sh; chmod 0700 /target/usr/local/sbin/nova-phase2-firstboot.sh; cp /nova-phase2-firstboot.service /target/etc/systemd/system/nova-phase2-firstboot.service; touch /target/etc/nova-phase2-ci-only; in-target systemctl enable nova-phase2-firstboot.service; mkdir -p /target/etc/default/grub.d; printf 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"\\n' > /target/etc/default/grub.d/nova-phase2-ci.cfg; in-target update-grub$GRAPHICAL_LATE; test -s /target/boot/grub/grub.cfg; echo $FILESYSTEM > /target/etc/nova-phase2-expected-fstype$LAYOUT_LATE; echo NOVA_PHASE2_INSTALL_COMPLETE >/dev/ttyS0
d-i finish-install/reboot_in_progress note
# Do NOT request a kernel halt: QEMU's -no-reboot exits on the real installer
# reboot, but a halted kernel can leave QEMU running indefinitely.
d-i cdrom-detect/eject boolean false
PRESEED
install -m 0755 "$ROOT/scripts/phase2-firstboot.sh" "$WORK/overlay/nova-phase2-firstboot.sh"
if [[ "$BTRFS_LAYOUT" == true ]]; then
  install -m 0755 "$ROOT/scripts/phase2-btrfs-layout-ci.sh" "$WORK/overlay/nova-phase2-btrfs-layout-ci.sh"
fi
cat > "$WORK/overlay/nova-phase2-firstboot.service" <<SERVICE
[Unit]
Description=NOVA disposable VM first-boot acceptance
After=$SERVICE_AFTER
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nova-phase2-firstboot.sh
TimeoutStartSec=$SERVICE_TIMEOUT
[Install]
WantedBy=$SERVICE_WANTED
SERVICE

# Appending an uncompressed cpio archive to an uncompressed initrd is supported
# by the initramfs format. No preseed is placed inside the release ISO itself.
gzip -dc "$WORK/original-initrd.gz" > "$WORK/initrd.raw"
( cd "$WORK/overlay"; find . -print0 | cpio --null -o -H newc --quiet ) > "$WORK/ci-overlay.cpio"
# GNU cpio stops at the first archive trailer, so verify the injected archive
# separately before concatenating it to the original Debian Installer initrd.
overlay_entries="$(cpio -it --quiet < "$WORK/ci-overlay.cpio")"
echo "CI installer overlay file list:"
printf '%s\n' "$overlay_entries"
grep -Fq 'preseed.cfg' <<< "$overlay_entries" || fail "CI preseed missing from overlay"
grep -Fq 'nova-phase2-firstboot.sh' <<< "$overlay_entries" || fail "CI guest probe missing from overlay"
if [[ "$BTRFS_LAYOUT" == true ]]; then
  grep -Fq 'nova-phase2-btrfs-layout-ci.sh' <<< "$overlay_entries" || fail "CI Btrfs layout script not staged"
fi
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
  local waited=0 code=0
  WAIT_REASON=""
  while (( waited < limit )); do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      wait "$QEMU_PID" || code=$?
      QEMU_PID=""
      if (( code != 0 )); then
        WAIT_REASON="qemu_exit_$code"
        echo "FAIL: $label QEMU exited with status $code" >&2
        return 1
      fi
      return 0
    fi
    if [[ -n "${WATCH_INSTALL_LOG:-}" && -f "$WATCH_INSTALL_LOG" ]] &&
       grep -Fq 'reboot: System halted' "$WATCH_INSTALL_LOG"; then
      WAIT_REASON="unexpected_halt"
      echo "FAIL: $label halted instead of rebooting; installer completion is not established" >&2
      kill "$QEMU_PID" 2>/dev/null || true
      wait "$QEMU_PID" 2>/dev/null || true
      QEMU_PID=""
      return 1
    fi
    # A textual d-i main-menu prompt proves the unattended install is blocked.
    # Fail quickly, preserving the serial log, instead of burning 90 CI minutes.
    if [[ -n "${WATCH_INSTALL_LOG:-}" && -f "$WATCH_INSTALL_LOG" ]] &&
       grep -Fq "Prompt: '?' for help" "$WATCH_INSTALL_LOG"; then
      WAIT_REASON="interactive_prompt"
      echo "FAIL: $label requires interactive input despite CI-only preseed" >&2
      tail -n 60 "$WATCH_INSTALL_LOG" >&2 || true
      kill "$QEMU_PID" 2>/dev/null || true
      wait "$QEMU_PID" 2>/dev/null || true
      QEMU_PID=""
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  WAIT_REASON="timeout"
  echo "TIMEOUT: $label after $limit seconds" >&2
  kill "$QEMU_PID" 2>/dev/null || true
  wait "$QEMU_PID" 2>/dev/null || true
  QEMU_PID=""
  return 1
}

# Capture the real virtual GPU framebuffer only after the user session has
# passed the in-guest Wayland and NOVA Desktop process checks.
capture_guest_screen() {
  local socket_path="$1" screenshot="$2"
  python3 - "$socket_path" "$screenshot" <<'PY'
import pathlib
import socket
import sys
import time

sock_path, screenshot = sys.argv[1:]
def desktop_pixels(path):
    # QEMU emits binary P6 PPM. A valid file alone is insufficient: the
    # Plasma splash captured in run 42472222973 was 99.4% black.
    # Require a visibly rendered frame, not a transient boot splash.
    with open(path, "rb") as stream:
        if stream.readline().strip() != b"P6":
            return False
        line = stream.readline()
        while line.startswith(b"#"):
            line = stream.readline()
        width, height = map(int, line.split())
        if stream.readline().strip() != b"255":
            return False
        if width < 640 or height < 480:
            return False
        pixels = stream.read(width * height * 3)
        if len(pixels) != width * height * 3:
            return False
    sampled = range(0, len(pixels), 3 * 16)
    visible = sum(1 for i in sampled if max(pixels[i:i+3]) > 40)
    return visible / len(sampled) >= 0.03

for attempt in range(90):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(3)
            sock.connect(sock_path)
            sock.sendall(("screendump " + screenshot + "\r\n").encode())
            time.sleep(0.8)
        if pathlib.Path(screenshot).is_file() and pathlib.Path(screenshot).stat().st_size > 1024:
            if desktop_pixels(screenshot):
                sys.exit(0)
    except (OSError, TimeoutError, ValueError):
        pass
    time.sleep(0.2)
sys.exit("QEMU framebuffer never advanced beyond the dark splash/blank screen")
PY
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
  # The secondary disk is a fresh RAW FILE, never a host device. It is writable
  # so an accidental installer write would be detected by its SHA-256 digest.
  local secondary="$OUTPUT/nova-$mode-$FILESYSTEM-nontarget.raw"
  local -a secondary_args=()
  if [[ "$PRESERVE_SECONDARY" == true ]]; then
    [[ ! -e "$secondary" && ! -L "$secondary" ]] || fail "refusing to overwrite existing secondary disk: $secondary"
    # Nonzero randomized filler detects zeroing even away from the identity marker.
    dd if=/dev/urandom of="$secondary" bs=1M count=64 status=none
    printf 'NOVA_PHASE2_PRESERVE_THIS_NON_TARGET_DISK\n' | dd of="$secondary" bs=1 seek=4096 conv=notrunc status=none
    sha256sum "$secondary" > "$WORK/$mode-$FILESYSTEM-nontarget.sha256"
    secondary_args=(-drive "if=virtio,format=raw,file=$secondary")
  fi
  boot_firmware_args "$mode"
  echo "Starting $mode Debian live-installer on a fresh disposable disk"
  "$QEMU" -machine q35 -accel "$ACCEL" -cpu max -m "$RAM_MIB" -smp "$CPUS" -vga std -display none \
    -serial "file:$install_log" -no-reboot \
    -drive "if=virtio,format=qcow2,file=$disk" "${secondary_args[@]}" \
    -cdrom "$ISO" -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    "${FW_ARGS[@]}" -kernel "$WORK/vmlinuz" -initrd "$WORK/test-initrd.gz" \
    -append "auto=true auto-install/enable=true preseed/file=/preseed.cfg priority=critical console=ttyS0,115200n8 DEBIAN_FRONTEND=noninteractive netcfg/choose_interface=auto" \
    > "$OUTPUT/$mode-installer-qemu.log" 2>&1 &
  QEMU_PID=$!
  WATCH_INSTALL_LOG="$install_log"
  if ! wait_qemu_exit "$INSTALL_TIMEOUT" "$mode installer"; then
    printf 'mode=%s\nresult=FAIL\nstage=installer_%s\n' "$mode" "$WAIT_REASON" > "$result"
    WATCH_INSTALL_LOG=""
    return 1
  fi
  WATCH_INSTALL_LOG=""
  if ! grep -Fq 'NOVA_PHASE2_PRESEED_LOADED' "$install_log"; then
    echo "FAIL: installer rebooted without partitioning-stage preseed proof" >&2
    printf 'mode=%s\nresult=FAIL\nstage=installer_preseed_unverified\n' "$mode" > "$result"
    return 1
  fi
  if ! grep -Fq 'NOVA_PHASE2_INSTALL_COMPLETE' "$install_log"; then
    echo "FAIL: installer rebooted before the target configuration finished" >&2
    printf 'mode=%s\nresult=FAIL\nstage=installer_completion_unverified\n' "$mode" > "$result"
    return 1
  fi
  # Shutdown by d-i is necessary but not sufficient; installed disk must boot.
  echo "Installer exited, now booting $mode virtual disk with ISO REMOVED"
  local monitor_socket="" screenshot="$OUTPUT/$mode-graphical-session.ppm"
  local screenshot_done=false
  local graphics_args=(-vga std -display none)
  if [[ "$GRAPHICAL" == true ]]; then
    monitor_socket="$OUTPUT/$mode-graphical-monitor.sock"
    graphics_args=(-vga virtio -display none -vnc 127.0.0.1:6
                   -monitor "unix:$monitor_socket,server=on,wait=off")
  fi
  "$QEMU" -machine q35 -accel "$ACCEL" -cpu max -m "$RAM_MIB" -smp "$CPUS" "${graphics_args[@]}" \
    -serial "file:$boot_log" -no-reboot -boot order=c \
    -drive "if=virtio,format=qcow2,file=$disk" "${secondary_args[@]}" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 "${FW_ARGS[@]}" \
    > "$OUTPUT/$mode-installed-qemu.log" 2>&1 &
  QEMU_PID=$!
  local waited=0
  while (( waited < BOOT_TIMEOUT )); do
    if [[ "$GRAPHICAL" == true && "$screenshot_done" == false &&
          -f "$boot_log" ]] &&
       grep -Fq 'NOVA_PHASE2_GRAPHICAL_SESSION_OK' "$boot_log"; then
      if ! capture_guest_screen "$monitor_socket" "$screenshot"; then
        echo "FAIL: real graphical session screenshot not captured" >&2
        printf 'mode=%s\nresult=FAIL\nstage=graphical_screenshot\n' "$mode" > "$result"
        return 1
      fi
      screenshot_done=true
    fi
    if [[ -f "$boot_log" ]] && grep -Fq 'NOVA_PHASE2_GUEST_PASS' "$boot_log"; then
      # A pass marker without the installed production initializer is insufficient.
      # QEMU serial output has CRLF; allow only exact LF/CRLF marker lines.
      if ! grep -Fxq 'NOVA_PHASE2_PRODUCTION_FIRSTBOOT_OK' "$boot_log" &&
         ! grep -Fxq "NOVA_PHASE2_PRODUCTION_FIRSTBOOT_OK$(printf '\015')" "$boot_log"; then
        echo "FAIL: installed production firstboot marker missing" >&2
        printf 'mode=%s\nresult=FAIL\nstage=production_firstboot_unverified\n' "$mode" > "$result"
        return 1
      fi
      if [[ "$BTRFS_LAYOUT" == true ]]; then
        for evidence in NOVA_PHASE2_BTRFS_LAYOUT_OK NOVA_PHASE2_SNAPSHOT_RESTORE_DATA_OK; do
          if ! grep -Fq "$evidence" "$boot_log"; then
            echo "FAIL: installed Btrfs layout/data restore evidence missing: $evidence" >&2
            printf 'mode=%s\nresult=FAIL\nstage=btrfs_layout_unverified\n' "$mode" > "$result"
            return 1
          fi
        done
      fi
      if [[ "$GRAPHICAL" == true && "$screenshot_done" != true ]]; then
        echo "FAIL: no verified graphical session screenshot" >&2
        printf 'mode=%s\nresult=FAIL\nstage=graphical_evidence\n' "$mode" > "$result"
        return 1
      fi
      if ! grep -Fq "NOVA_PHASE2_FIRMWARE=$mode" "$boot_log" ||
         ! grep -Fq 'NOVA_PHASE2_ROOT_SOURCE=' "$boot_log" ||
         ! grep -Fq 'NOVA_PHASE2_ROOT_FSTYPE=' "$boot_log"; then
        echo "FAIL: installed guest firmware or root-filesystem evidence is missing/mismatched" >&2
        printf 'mode=%s\nresult=FAIL\nstage=installed_boot_evidence\n' "$mode" > "$result"
        return 1
      fi
      # The graphical guest deliberately remains up to 110s for settled desktop
       # evidence. A 90s shutdown wait would falsely fail an early screenshot.
       shutdown_budget=90
       if [[ "$GRAPHICAL" == true ]]; then shutdown_budget=180; fi
       if ! wait_qemu_exit "$shutdown_budget" "$mode guest shutdown"; then
        printf 'mode=%s\nresult=FAIL\nstage=guest_shutdown_%s\n' "$mode" "$WAIT_REASON" > "$result"
        return 1
      fi
      if [[ "$PRESERVE_SECONDARY" == true ]]; then
        if ! sha256sum -c "$WORK/$mode-$FILESYSTEM-nontarget.sha256"; then
          echo "FAIL: non-target disk contents changed" >&2
          printf 'mode=%s\nresult=FAIL\nstage=non_target_disk_changed\n' "$mode" > "$result"
          return 1
        fi
        echo "NOVA_PHASE2_NON_TARGET_DISK_PRESERVED"
      fi
      echo "PASS: $mode installed NOVA booted without ISO, passed guest checks and shut down cleanly"
      printf 'mode=%s\nfilesystem=%s\nresult=PASS\npostinstall=verified\nshutdown=verified\ngraphical=%s\npreserved_secondary=%s\n' "$mode" "$FILESYSTEM" "$GRAPHICAL" "$PRESERVE_SECONDARY" > "$result"
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
