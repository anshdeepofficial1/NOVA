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
    if [[ -f /etc/nova-phase2-ci-snapshot-restore ]]; then
      # Subvolumes and test-user data must survive the ISO-free disk reboot.
      for mount_path in /home /.snapshots; do
        mountpoint -q "$mount_path" || { echo "Missing persisted Btrfs mount: $mount_path"; exit 1; }
        [[ "$(findmnt -n -o FSTYPE "$mount_path")" == btrfs ]] || exit 1
        btrfs subvolume show "$mount_path" >/dev/null || exit 1
      done
      [[ "$(findmnt -n -o SOURCE /home)" == *"@home]" ]] || exit 1
      [[ "$(findmnt -n -o SOURCE /.snapshots)" == *"@snapshots]" ]] || exit 1
      grep -Fxq NOVA_PHASE2_HOME_COPY_OK /home/novatest/.nova-phase2-migration
      btrfs subvolume show /.snapshots/baseline >/dev/null
      grep -Fxq data_restore_verified /etc/nova-phase2-ci-snapshot-restore
      echo "NOVA_PHASE2_BTRFS_LAYOUT_OK"
      echo "NOVA_PHASE2_SNAPSHOT_RESTORE_DATA_OK"
    fi
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
  # Cap D-Bus/loginctl calls and the total GUI probe wall time. Run #42
  # hung for 20 minutes after daemon health without reporting a GUI failure.
  assert_binary timeout
  graphical_ready=0
  gui_deadline=$((SECONDS + 180))
  gui_attempt=0
  echo "NOVA_PHASE2_GUI_WAIT_BEGIN"
  while (( SECONDS < gui_deadline )); do
    gui_attempt=$((gui_attempt + 1))
    # During Plasma startup loginctl/DBus can be expensive or congested.
    # Poll cheap, user-owned processes first, then ask logind only when
    # the actual compositor AND NOVA Desktop window process both exist.
    kwin_ready=0
    shell_ready=0
    if pgrep -u "$uid" -x kwin_wayland >/dev/null; then kwin_ready=1; fi
    if pgrep -u "$uid" -x nova-shell >/dev/null; then shell_ready=1; fi
    if (( gui_attempt == 1 || gui_attempt % 5 == 0 )); then
      echo "NOVA_PHASE2_GUI_POLL attempt=$gui_attempt kwin=$kwin_ready shell=$shell_ready"
    fi
    if (( kwin_ready == 1 && shell_ready == 1 )); then
      # One bounded loginctl read for session metadata instead of three
      # independent show-session DBus round-trips per session.
      while read -r session_id _; do
        [[ "$session_id" =~ ^[0-9]+$ ]] || continue
        session_info="$(timeout -k 2s 6s loginctl show-session "$session_id" -p Name -p Type -p Active 2>/dev/null || true)"
        if grep -Fxq 'Name=novatest' <<< "$session_info" &&
           grep -Fxq 'Type=wayland' <<< "$session_info" &&
           grep -Fxq 'Active=yes' <<< "$session_info"; then
          graphical_ready=1
          echo "NOVA_PHASE2_GUI_SESSION_ID=$session_id"
          echo "NOVA_PHASE2_GUI_SESSION_TYPE=wayland"
          break
        fi
      done < <(timeout -k 2s 6s loginctl list-sessions --no-legend 2>/dev/null || true)
    fi
    if (( gui_attempt == 1 || gui_attempt % 5 == 0 )); then
      echo "NOVA_PHASE2_GUI_POLL_COMPLETE attempt=$gui_attempt ready=$graphical_ready"
    fi
    (( graphical_ready == 1 )) && break
    sleep 3
  done
  if (( graphical_ready != 1 )); then
    echo "NOVA graphical Wayland login or shell did not become ready"
    timeout -k 2s 8s ps -eo pid,ppid,stat,user,comm --sort=pid | tail -n 70 || true
    timeout -k 2s 8s systemctl --no-pager status display-manager.service || true
    timeout -k 2s 8s journalctl --no-pager -u sddm.service -n 70 || true
    timeout -k 2s 8s journalctl --no-pager -u systemd-logind.service -n 40 || true
    timeout -k 2s 8s loginctl list-sessions --no-legend || true
    exit 1
  fi
  # The earlier root-run health probe has stopped its temporary daemon.
  # Prove that the installed login session itself owns a working host API,
  # rather than accepting a nova-shell process with an offline UI.
  assert_binary runuser
  user_service_ready=0
  echo "NOVA_PHASE2_USER_DAEMON_WAIT_BEGIN"
  for attempt in $(seq 1 45); do
    if timeout -k 2s 5s runuser -u novatest -- env \
         "XDG_RUNTIME_DIR=/run/user/$uid" \
         "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
         systemctl --user is-active --quiet nova-daemon.service &&
       curl --fail --silent --max-time 2 \
         -H 'Origin: http://tauri.localhost' \
         -D /run/nova-phase2-user-api-headers \
         http://127.0.0.1:47820/health > /run/nova-phase2-user-health.json &&
       grep -Fq '"service":"nova-daemon"' /run/nova-phase2-user-health.json &&
       grep -Fiq 'access-control-allow-origin: http://tauri.localhost' /run/nova-phase2-user-api-headers &&
       curl --fail --silent --max-time 2 http://127.0.0.1:47820/api/system |
         grep -Fq '"product":"NOVA OS"'; then
      user_service_ready=1
      break
    fi
    if (( attempt == 1 || attempt % 15 == 0 )); then
      echo "NOVA_PHASE2_USER_DAEMON_POLL attempt=$attempt"
    fi
    sleep 1
  done
  if (( user_service_ready != 1 )); then
    echo "NOVA user-session daemon or Tauri-origin API unavailable after Wayland login"
    timeout -k 2s 8s runuser -u novatest -- env \
      "XDG_RUNTIME_DIR=/run/user/$uid" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
      systemctl --user --no-pager status nova-daemon.service || true
    timeout -k 2s 8s journalctl --no-pager "_UID=$uid" -n 50 || true
    exit 1
  fi
  echo "NOVA_PHASE2_USER_DAEMON_HEALTH_OK"
  # G2 investigation: capture the real installed guest's KDE Welcome Center
  # launch path before changing production autostart rules. CI-only probe;
  # never close windows or mutate the session to make a screenshot pass.
  echo "NOVA_PHASE2_WELCOME_DIAGNOSTICS_BEGIN"
  timeout -k 2s 8s ps -eo pid,ppid,uid,stat,args --sort=pid |
    grep -Ei '(^ *PID|plasma-welcome|welcome-center|kded|klauncher|nova-shell|kwin_wayland)' || true
  for pid in $(pgrep -u "$uid" -f 'plasma-welcome|welcome-center' || true); do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    echo "NOVA_PHASE2_WELCOME_PID=$pid"
    timeout -k 1s 3s sh -c 'tr "\0" " " < "/proc/$1/cmdline"; echo' sh "$pid" || true
    timeout -k 1s 3s sh -c 'cat "/proc/$1/cgroup"' sh "$pid" || true
    timeout -k 1s 3s ps -o pid,ppid,user,comm,args -p "$pid" || true
  done
  timeout -k 2s 8s runuser -u novatest -- env \
    "XDG_RUNTIME_DIR=/run/user/$uid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
    systemctl --user --no-pager list-units --all '*welcome*' '*plasma*' || true
  for dir in /etc/xdg/autostart /usr/share/xdg/autostart /home/novatest/.config/autostart; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 1 -type f \( -iname '*welcome*' -o -iname '*discover*' \) -print -exec grep -E '^(Name|Exec|Hidden|OnlyShowIn|NotShowIn|X-KDE-autostart-condition)=' {} \; 2>/dev/null || true
  done
  echo "NOVA_PHASE2_WELCOME_DIAGNOSTICS_END"
  echo "NOVA_PHASE2_GRAPHICAL_SESSION_OK"
  # Emit the final acceptance marker before the screenshot grace period.
  # The host checks the screenshot before accepting this marker and waits
  # for clean shutdown, so this cannot bypass graphical evidence.
  echo "NOVA_PHASE2_GUEST_PASS"
  # Keep the disposable guest alive for the QEMU framebuffer capture.
  # Allow the host to reject the initial Plasma splash and capture the desktop.
  sleep 110
else
  echo "NOVA_PHASE2_GUEST_PASS"
fi
