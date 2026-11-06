# NOVA OS image builder

This is the first bootable-PC image target for NOVA: **Debian 13 (Trixie), amd64, KDE Plasma/Wayland**, built with Debian Live live-build and the Debian Installer's live-installer mode.

It is an intentionally conventional Linux base. NOVA does not fork a kernel or replace the bootloader. The first release should prove hardware support, install/upgrade/recovery and runtime boundaries before attempting a custom kernel or compositor.

## Image build contract

The image builder is responsible for producing and structurally validating a bootable, checksum-protected ISO. It does not certify hardware compatibility or installer safety.

The configuration explicitly selects:

- Debian Trixie amd64 and the `iso-hybrid` image format.
- Syslinux/ISOLINUX for legacy BIOS and GRUB EFI for UEFI.
- A visible BIOS menu that automatically selects the default live entry after five seconds while retaining manual menu choices.
- Debian's signed shim/GRUB packages through strict Secure Boot mode. The image build fails instead of silently downgrading if the signed packages are unavailable.
- SHA-256 checksums in the live medium, a separate downloadable SHA-256 file, UTC timestamps and a build manifest with source commit/build metadata.
- A serial console boot argument so headless BIOS and UEFI VM smoke tests can wait for a real systemd login prompt.

The image contains a Debian live environment and the Debian Installer live-installer mode. The build pipeline checks the El Torito boot catalog, live kernel, initrd and SquashFS root filesystem, then boots the ISO in disposable QEMU guests under both BIOS and UEFI.

## What the image contains

- Debian Trixie live system, hybrid ISO suitable for USB boot.
- KDE Plasma desktop and Wayland session.
- NetworkManager, PipeWire, Firefox ESR and Flatpak/Discover.
- Waydroid selected explicitly from Trixie Backports, Wine, QEMU/KVM and libvirt tools.
- Btrfs and Snapper utilities (not automatically configured on every installation).
- Debian Installer live mode, which installs the live filesystem to disk.
- NOVA Desktop native Tauri .deb package and the NOVA host API binary.
- A hardened per-user systemd unit that starts the read-only NOVA host service at graphical login.
- A KDE/XDG autostart entry that opens NOVA Desktop after login.
- Debian Trixie Backports configured for both image construction and the installed system.

Runtime packages being present does not mean an app is compatible. Waydroid depends on a Wayland session and kernel Binder support; Wine compatibility is app/version specific; hardware-accelerated VMs require accessible KVM. NOVA reports these conditions and never silently executes a downloaded installer.

## Build prerequisites

Use a clean Debian 13 or Ubuntu 24.04+ x86_64 build host or a disposable VM. The build requires root for live-build's chroot operations and substantial free disk space.

Install the image and Tauri build dependencies:

```bash
sudo apt update
sudo apt install -y \
  libwebkit2gtk-4.1-dev build-essential curl wget file \
  libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev \
  live-build debootstrap squashfs-tools xorriso \
  grub-pc-bin grub-efi-amd64-bin mtools dosfstools isolinux syslinux-common \
  qemu-system-x86 qemu-utils ovmf
```

Build the native NOVA shell package and daemon from the repository root. The desktop build generates its Tauri icon set and stages the daemon sidecar automatically:

```bash
npm install
npm run desktop:build
cargo build --release -p nova-daemon
```

Stage the binaries/packages into the image tree:

```bash
install -D -m 0755 target/release/nova-daemon \
  os/debian-live/config/includes.chroot/usr/local/bin/nova-daemon
mkdir -p os/debian-live/config/packages.chroot
cp apps/shell/src-tauri/target/release/bundle/deb/*.deb \
  os/debian-live/config/packages.chroot/
```

Validate the live-build configuration, then build:

```bash
bash scripts/validate-live-build-config.sh
sudo bash os/debian-live/build.sh
```

The default build purges generated live-build state before resolving the version-controlled configuration. To retain downloaded package cache between local iterations, use:

```bash
sudo bash os/debian-live/build.sh --reuse-cache
```

The output files are:

- `os/debian-live/live-image-amd64.hybrid.iso`
- `os/debian-live/live-image-amd64.hybrid.iso.sha256`
- `os/debian-live/live-image-amd64.hybrid.iso.buildinfo`
- `os/debian-live/build.log`
- `os/debian-live/validation/` (structural validation reports)

The build script verifies the checksum, ISO 9660 format, BIOS+UEFI El Torito entries, live kernel, initrd and SquashFS root filesystem before reporting success.

## Automated firmware boot smoke tests

Run the serial-console boot test under both firmware paths:

```bash
bash scripts/smoke-iso-qemu.sh --firmware both
```

The test uses disposable QEMU guests, TCG emulation and no virtual disk. It waits for systemd to expose a serial login prompt. This verifies the ISO reaches userspace; it is not a graphical desktop test, installer acceptance test or physical-hardware certification.

For interactive visual testing of the live desktop and installer, use:

```bash
bash scripts/test-iso-qemu.sh --firmware uefi
bash scripts/test-iso-qemu.sh --firmware bios
```

That launcher creates a separate qcow2 virtual disk. The installer can modify only that guest disk if you explicitly select it inside the VM.

## Build from GitHub Actions

The **Build NOVA ISO** workflow runs manually from **Actions → Build NOVA ISO → Run workflow**, and automatically on pushes to `main` that change the ISO recipe, its validation scripts or the workflow itself.

A successful run uploads the ISO, checksum, build manifest, full live-build log and boot/structure validation reports as the `NOVA-OS-amd64-experimental` artifact. The normal lightweight CI continues to run Rust, frontend and native desktop checks without building the multi-gigabyte OS image.

## Installer and disk safety

The image uses Debian Installer live mode. It copies the live system into a selected disk and runs the normal installer bootloader/user setup stages. It is not a zero-risk operation: test in a VM, inspect every disk selection screen and back up data before installing to real hardware.

The image does not automatically repartition or format disks during live boot. Never add unattended destructive partitioning to the default boot path.

## Known boundaries

- Target architecture: x86_64/amd64 only for this first image.
- Secure Boot is enabled in the image recipe and the build requires Debian's signed boot components; firmware-specific Secure Boot behavior still needs a dedicated acceptance test.
- UEFI and legacy BIOS are automatically boot-smoke-tested in QEMU; graphical desktop, installer, GPU, Wi-Fi, Bluetooth, fingerprint, suspend and multi-monitor support still need further tests.
- Waydroid's availability is not equivalent to Google Play certification, DRM or Play Integrity compatibility.
- Wine does not implement the entire Windows OS. Apps that require kernel drivers or unsupported APIs may need a licensed Windows VM.
- macOS DMG/PKG execution is intentionally not supported on this Linux image.
- Btrfs/Snapper tooling is installed but a tested partition layout and preconfigured snapshots remain a separate installer milestone.
