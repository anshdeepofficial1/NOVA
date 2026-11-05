# NOVA OS image builder

This is the first bootable-PC image target for NOVA: **Debian 13 (Trixie), amd64, KDE Plasma/Wayland**, built with Debian Live `live-build` and the Debian Installer's live-installer mode.

It is an intentionally conventional Linux base. NOVA does not fork a kernel or replace the bootloader. The first release should prove hardware support, install/upgrade/recovery and runtime boundaries before attempting a custom kernel or compositor.

## What the image contains

- Debian Trixie live system, hybrid ISO suitable for USB boot.
- KDE Plasma desktop and Wayland session.
- NetworkManager, PipeWire, Firefox ESR and Flatpak/Discover.
- Waydroid from Trixie backports, Wine, QEMU/KVM and libvirt tools.
- Btrfs and Snapper utilities (not automatically configured on every installation).
- Debian Installer live mode, which installs the live filesystem to disk.
- NOVA Desktop native Tauri package and the NOVA host API binary.

Runtime packages being present does not mean an app is compatible. Waydroid depends on a Wayland session and kernel Binder support; Wine compatibility is app/version specific; hardware-accelerated VMs require accessible KVM. NOVA reports these conditions and never silently executes a downloaded installer.

## Build locally

Use a clean Debian 13/Ubuntu 24.04+ x86_64 build host or a disposable VM. The build requires root for live-build's chroot operations and substantial disk space.

Install tools:

~~~bash
sudo apt update
sudo apt install -y live-build debootstrap squashfs-tools xorriso \
  grub-pc-bin grub-efi-amd64-bin mtools dosfstools isolinux syslinux-common

# Build the native NOVA shell package and daemon.
npm install
npm run desktop:build
cargo build --release -p nova-daemon

# Stage the binaries/packages into the image tree.
install -D -m 0755 target/release/nova-daemon \
  os/debian-live/config/includes.chroot/usr/local/bin/nova-daemon
mkdir -p os/debian-live/config/packages.chroot
cp apps/shell/src-tauri/target/release/bundle/deb/*.deb \
  os/debian-live/config/packages.chroot/

# Build the bootable ISO.
cd os/debian-live
sudo ./build.sh
~~~

The image is written to `os/debian-live/live-image-amd64.hybrid.iso` (the exact filename is printed by the build script). Verify it with `sha256sum` and boot it in a disposable VM before testing on physical hardware.

## Build from GitHub Actions

Open **Actions → Build NOVA ISO → Run workflow**. The workflow builds and tests the Rust daemon and Tauri frontend/package, creates the live ISO, verifies the ISO structure and uploads the ISO plus SHA-256 checksum as an artifact.

The first ISO workflow is manual by design; normal code pushes should not trigger a multi-gigabyte OS image build.

## Installer and disk safety

The image uses Debian Installer live mode. It copies the live system into a selected disk and runs the normal installer bootloader/user setup stages. It is not a zero-risk operation: test in a VM, inspect every disk selection screen and back up data before installing to real hardware.

The image does not automatically repartition or format disks during live boot. Never add unattended destructive partitioning to the default boot path.

## Known boundaries

- Target architecture: x86_64/amd64 only for this first image.
- Secure Boot depends on the Debian signed boot components available to live-build and the target firmware.
- GPU, Wi-Fi, Bluetooth, fingerprint, suspend and multi-monitor support need physical-device tests.
- Waydroid's availability is not equivalent to Google Play certification, DRM or Play Integrity compatibility.
- Wine does not implement the entire Windows OS. Apps that require kernel drivers or unsupported APIs may need a licensed Windows VM.
- macOS DMG/PKG execution is intentionally not supported on this Linux image.
- Btrfs/Snapper tooling is installed but a tested partition layout and preconfigured snapshots remain a separate installer milestone.
