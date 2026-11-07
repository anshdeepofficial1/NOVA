#!/usr/bin/env bash
# CI-only first-boot probe. Installed exclusively into disposable QEMU disks.
set -Eeuo pipefail

exec > /dev/ttyS0 2>&1

finish() {
  status="${1:-$?}"
  trap - EXIT
  if (( status != 0 )); then
    echo "NOVA_PHASE2_GUEST_FAIL status=$status"
  fi
  sync
  systemctl --no-block poweroff || true
  exit "$status"
}
trap finish EXIT

echo "NOVA_PHASE2_GUEST_START"
echo "NOVA_PHASE2_KERNEL=$(uname -r)"

assert_binary() {
  command -v "$1" >/dev/null || { echo "Missing binary: $1"; return 1; }
}
assert_package() {
  dpkg-query -W -f='${Status}' "$1" | grep -Fxq "install ok installed" || {
    echo "Missing package: $1"
    return 1
  }
}

# These checks are against the installed OS. There is no ISO attached to this VM.
grep -Fq 'ID=debian' /etc/os-release
# Inspect the installed disk, not the removed live ISO or an ephemeral rootfs.
root_source="$(findmnt -n -o SOURCE /)"
root_fstype="$(findmnt -n -o FSTYPE /)"
case "$root_source" in
  /dev/*|UUID=*) ;;
  *) echo "Unexpected root source: $root_source"; exit 1 ;;
esac
case "$root_fstype" in
  ext4|btrfs|xfs) ;;
  *) echo "Unexpected root filesystem: $root_fstype"; exit 1 ;;
esac
test -s /etc/fstab
test -s /boot/grub/grub.cfg
if [[ -d /sys/firmware/efi ]]; then
  firmware=uefi
  test -d /boot/efi/EFI
else
  firmware=bios
fi
# The expected filesystem is written by the actual installer late hook.
# This must match the mounted installed root, not merely an installed package.
if [[ -s /etc/nova-phase2-expected-fstype ]]; then
  expected_fstype="$(cat /etc/nova-phase2-expected-fstype)"
  [[ "$root_fstype" == "$expected_fstype" ]] || {
    echo "Installed root filesystem mismatch: expected $expected_fstype got $root_fstype"
    exit 1
  }
  if [[ "$expected_fstype" == "btrfs" ]]; then
    assert_binary btrfs
    btrfs subvolume show / || {
      echo "Btrfs root is not an actual subvolume"
      exit 1
    }
    echo "NOVA_PHASE2_BTRFS_SUBVOLUME_OK"
  fi
  echo "NOVA_PHASE2_STORAGE_POLICY_OK"
fi
echo "NOVA_PHASE2_ROOT_SOURCE=$root_source"
echo "NOVA_PHASE2_ROOT_FSTYPE=$root_fstype"
echo "NOVA_PHASE2_FIRMWARE=$firmware"
test -d /home/novatest
test -x /usr/local/bin/nova-daemon
assert_binary nova-shell
assert_binary apt-get
assert_binary nmcli
assert_binary loginctl
assert_binary curl
assert_package sddm
assert_package kde-plasma-desktop
assert_package pipewire
assert_package network-manager
assert_package flatpak
systemctl is-enabled display-manager.service
test -f /usr/lib/systemd/user/nova-daemon.service
test -f /etc/xdg/autostart/nova-desktop.desktop
test -f /etc/nova-phase2-ci-only

echo "NOVA_PHASE2_FILESYSTEM_OK"
echo "NOVA_PHASE2_DESKTOP_PACKAGES_OK"

# Verify the installed host API responds. No development Vite server is used.
log=/run/nova-phase2-daemon.log
/usr/local/bin/nova-daemon > "$log" 2>&1 &
daemon_pid=$!
stop_daemon() {
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}
trap 'status=$?; stop_daemon; finish "$status"' EXIT
ready=0
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 2 http://127.0.0.1:47820/health >/run/nova-phase2-health.json 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if (( ready != 1 )); then
  echo "NOVA daemon failed after installation"
  tail -n 50 "$log" || true
  exit 1
fi
grep -qi 'ok' /run/nova-phase2-health.json
stop_daemon
trap finish EXIT
echo "NOVA_PHASE2_DAEMON_HEALTH_OK"
echo "NOVA_PHASE2_GUEST_PASS"
