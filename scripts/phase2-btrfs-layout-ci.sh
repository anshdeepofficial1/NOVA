#!/usr/bin/env bash
# CI-ONLY: create the test Btrfs home/snapshot layout in a disposable QEMU guest.
# This script MUST NOT run on a host or an installed physical system.
set -Eeuo pipefail

fail() { printf 'NOVA_PHASE2_BTRFS_LAYOUT_FAIL: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || fail "requires root in the test guest"
[[ -f /etc/nova-phase2-ci-only ]] || fail "refusing to operate outside a CI-only guest"
[[ -f /etc/nova-phase2-expected-fstype ]] || fail "missing test filesystem policy"
[[ "$(cat /etc/nova-phase2-expected-fstype)" == btrfs ]] || fail "filesystem policy is not Btrfs"
[[ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" == QEMU ]] || fail "not an identified QEMU guest"
[[ -b /dev/vda2 ]] || fail "missing disposable guest root disk"
[[ "$(blkid -s TYPE -o value /dev/vda2)" == btrfs ]] || fail "unexpected guest root disk filesystem"
[[ "$(findmnt -n -o FSTYPE /)" == btrfs ]] || fail "installed root is not Btrfs"

for binary in btrfs findmnt mount umount awk cp grep mktemp; do
  command -v "$binary" >/dev/null || fail "missing command: $binary"
done

root_spec="$(awk '$2 == "/" && $3 == "btrfs" { print $1; exit }' /etc/fstab)"
[[ -n "$root_spec" ]] || fail "missing Btrfs root fstab entry"
! awk '$2 == "/home" || $2 == "/.snapshots" { found = 1 } END { exit !found }' /etc/fstab ||
  fail "home or snapshots already has a filesystem entry"
[[ -d /home/novatest && ! -L /home ]] || fail "test user's home is not a normal directory"

top="$(mktemp -d /run/nova-btrfs-layout.XXXXXXXX)" || fail "could not create temporary mountpoint"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then umount "$top" || true; fi
  rmdir "$top" || true
}
trap cleanup EXIT
mount -t btrfs -o subvolid=5 /dev/vda2 "$top" || fail "cannot mount Btrfs top-level"
mounted=true
btrfs subvolume show "$top/@rootfs" >/dev/null || fail "missing installed @rootfs"
[[ ! -e "$top/@home" && ! -L "$top/@home" ]] || fail "@home already exists; refusing overwrite"
[[ ! -e "$top/@snapshots" && ! -L "$top/@snapshots" ]] || fail "@snapshots already exists; refusing overwrite"

btrfs subvolume create "$top/@home"
btrfs subvolume create "$top/@snapshots"
cp -a /home/. "$top/@home/"
[[ -d "$top/@home/novatest" ]] || fail "test user home migration failed"
printf 'NOVA_PHASE2_HOME_COPY_OK\n' > "$top/@home/novatest/.nova-phase2-migration"

mkdir -p /.snapshots
printf '%s /home btrfs defaults,subvol=@home 0 0\n' "$root_spec" >> /etc/fstab
printf '%s /.snapshots btrfs defaults,subvol=@snapshots 0 0\n' "$root_spec" >> /etc/fstab
btrfs subvolume snapshot -r "$top/@rootfs" "$top/@snapshots/baseline"

# Prove data-level snapshot restore without replacing a mounted root. This is
# NOT proof of interrupted-update or bootloader-level root rollback.
scratch="$top/@snapshots/rollback-scratch"
checkpoint="$top/@snapshots/rollback-checkpoint"
btrfs subvolume create "$scratch"
printf 'known-good\n' > "$scratch/state"
btrfs subvolume snapshot -r "$scratch" "$checkpoint"
printf 'corrupted\n' > "$scratch/state"
btrfs subvolume delete "$scratch"
btrfs subvolume snapshot "$checkpoint" "$scratch"
grep -Fxq 'known-good' "$scratch/state" || fail "snapshot restoration did not recover the data"
btrfs subvolume delete "$scratch"
btrfs subvolume delete "$checkpoint"
printf 'data_restore_verified\n' > /etc/nova-phase2-ci-snapshot-restore
printf 'NOVA_PHASE2_BTRFS_LAYOUT_PREPARED\n'
