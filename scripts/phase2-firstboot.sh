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

# If this installed image carries the production initializer, prove that its
# systemd unit actually executed. Legacy ISO artifacts used for earlier installer
# regression tests lack the unit and cannot satisfy this newer release gate.
if [[ -f /usr/lib/systemd/system/nova-firstboot.service ]]; then
  systemctl is-enabled nova-firstboot.service >/dev/null
  ready=0
  for attempt in $(seq 1 60); do
    if [[ -s /var/lib/nova/firstboot.ready ]]; then
      ready=1
      break
    fi
    sleep 1
  done
  if (( ready != 1 )); then
    echo "Production NOVA first-boot service did not write its installed-system marker"
    journalctl --no-pager -u nova-firstboot.service -n 50 || true
    exit 1
  fi
  grep -Fxq 'status=prerequisites_checked' /var/lib/nova/firstboot.ready
  echo "NOVA_PHASE2_PRODUCTION_FIRSTBOOT_OK"
fi

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

# CI-ONLY graphical mode: the test account is autologged in solely on a
# disposable guest disk. Do not infer a GUI from installed Debian packages.
if [[ -f /etc/nova-phase2-ci-graphical ]]; then
  systemctl is-active --quiet display-manager.service || {
    echo "SDDM display manager is not active"
    exit 1
  }
  test -s /usr/share/wayland-sessions/plasma.desktop
  assert_binary pgrep
  assert_binary loginctl
  uid="$(id -u novatest)"
  graphical_ready=0
  for attempt in $(seq 1 150); do
    while read -r session_id _; do
      [[ "$session_id" =~ ^[0-9]+$ ]] || continue
      session_name="$(loginctl show-session "$session_id" -p Name --value 2>/dev/null || true)"
      session_type="$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || true)"
      session_active="$(loginctl show-session "$session_id" -p Active --value 2>/dev/null || true)"
      if [[ "$session_name" == novatest && "$session_type" == wayland &&
            "$session_active" == yes ]] &&
         pgrep -u "$uid" -x kwin_wayland >/dev/null &&
         pgrep -u "$uid" -x nova-shell >/dev/null; then
        graphical_ready=1
        echo "NOVA_PHASE2_GUI_SESSION_ID=$session_id"
        echo "NOVA_PHASE2_GUI_SESSION_TYPE=$session_type"
        break
      fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    (( graphical_ready == 1 )) && break
    sleep 1
  done
  if (( graphical_ready != 1 )); then
    echo "NOVA graphical Wayland login or shell did not become ready"
    systemctl --no-pager status display-manager.service || true
    journalctl --no-pager -u sddm.service -n 70 || true
    loginctl list-sessions --no-legend || true
    exit 1
  fi
  echo "NOVA_PHASE2_GRAPHICAL_SESSION_OK"
  # Keep the disposable guest active so the host can capture the real VGA
  # framebuffer before the guest completes its automated shutdown.
  sleep 15
fi

echo "NOVA_PHASE2_GUEST_PASS"
