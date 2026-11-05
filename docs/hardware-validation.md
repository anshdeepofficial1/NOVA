# NOVA hardware and installation validation matrix

## Why this exists

A successful ISO build is not proof that an operating system works on a PC. A NOVA image is not release-ready until the live session, installer, first boot, updates, recovery and hardware integrations have passed repeatable tests.

The matrix below is a release plan. No physical-device tests are claimed as completed by this repository.

## Required test environments

### Virtual machines

| Environment | Required coverage | Release evidence |
|---|---|---|
| QEMU/KVM, UEFI, x86_64 | Live boot, desktop session, installer, disk layout, installed reboot, update and recovery | CI artifact, QEMU command, console log, screenshots and test report |
| QEMU/KVM, legacy BIOS | Boot menu, live session and installer bootloader path | Test report and serial/console evidence |
| QEMU/KVM, Secure Boot enabled | Signed boot chain and installed reboot | Firmware configuration, boot log and explicit result |
| QEMU/KVM, Secure Boot disabled | Baseline compatibility path | Boot and installer smoke report |
| UEFI VM with empty disk | New installation and first user session | Installer report and installed disk image/test snapshot |
| UEFI VM with existing partitions | Manual target selection and preservation of unselected partitions | Before/after partition table and data integrity test |

Do not let CI automatically select or format a disk. Use disposable virtual disks with known identifiers.

### Physical hardware

| Hardware area | Test cases | Pass criteria |
|---|---|---|
| AMD x86_64 | Boot, integrated graphics, suspend/resume, power profile | No boot regression, stable session, no GPU reset |
| Intel x86_64 | Boot, integrated graphics, video decode, display hotplug | Stable compositor and working display outputs |
| NVIDIA discrete GPU | Open-source driver path and supported proprietary-driver path as separately documented | No unreported fallback, stable session, correct acceleration status |
| AMD discrete GPU | Display, Vulkan/OpenGL, video decode, multi-monitor | Hardware acceleration confirmed; no unexplained rendering artifacts |
| Wi-Fi | Connect, reconnect, suspend/resume, hidden SSID, WPA2/WPA3 where supported | Stable network and correct NetworkManager status |
| Bluetooth | Pair, audio device, reconnect after reboot/suspend | Pairing and reconnect stable |
| Audio | Speakers, headset, microphone, PipeWire routing, HDMI audio | Input/output selection and volume controls work |
| USB | Storage, keyboard, mouse, USB audio, hotplug | Devices mount/connect safely and can be removed cleanly |
| Display | 1080p/1440p/4K, fractional scaling, hotplug, portrait and multi-monitor | Correct geometry, DPI, refresh rate and no stuck windows |
| Laptop power | Battery status, lid close/open, suspend, resume, brightness, thermal profile | Resume without data loss, stable graphics/network/audio |
| Storage | NVMe, SATA SSD, HDD, encrypted disk | Installer detects device, correct boot and filesystem health |
| Input | Laptop keyboard, touchpad, external mouse, touchscreen where present | Gestures and input remain responsive |
| Firmware | UEFI setup, Secure Boot, TPM presence, firmware updates | No unsupported firmware changes or silent security downgrades |

Record exact vendor/device IDs, firmware revision, kernel version, Mesa/NVIDIA driver version and NOVA image hash. “Works on my laptop” is not sufficient evidence.

## Installer acceptance

For each VM test disk:

1. Confirm the live system boots without modifying the target disk.
2. Verify the booted image and NOVA services.
3. Open the installer from its documented entry.
4. Confirm every destructive partition/format action is visible before proceeding.
5. Install into a disposable target disk.
6. Confirm unselected test partitions retain their contents and UUIDs.
7. Reboot from the installed disk, remove the ISO and reach the login session.
8. Create or authenticate a local account using the installer flow.
9. Check bootloader entries and UEFI NVRAM behavior.
10. Run updates and reboot again.
11. Verify the NOVA Desktop, local daemon and systemd user service.
12. Verify logs and expected recovery path after an interrupted or failed update.

A release is blocked by data loss, silent repartitioning, an unbootable install, missing recovery path or privilege escalation.

## Runtime integration acceptance

A runtime must have its own compatibility matrix; package presence is not a successful app test.

### Android / Waydroid
- Verify the host kernel's Binder/BinderFS configuration and actual device nodes.
- Verify Wayland session, GPU, input, audio, clipboard and orientation integration.
- Initialize a clean Android image from a verified source.
- Install a test APK, launch it, persist app data, upgrade, uninstall and restart.
- Test multi-user and permission boundaries.
- Explicitly report Play Services, Play Integrity, DRM and vendor-specific app limitations. Do not mark them working without independent tests.

### Windows / Wine or Proton
- Test a known-good open-source Win32 app, a complex installer and a graphics-intensive app separately.
- Use a disposable prefix per app/version.
- Test file access, network policy, audio, GPU acceleration, update, uninstall and cleanup.
- Maintain a matrix by app ID, version, Wine/Proton version, architecture and host graphics stack.
- Test a licensed Windows VM as a distinct fallback path; do not claim Wine is equivalent to Windows.

### Linux / Flatpak and native packages
- Verify signature/source validation and dependency resolution.
- Verify app portal permissions, sandbox boundaries, update, rollback and uninstall.
- Confirm host distribution and architecture constraints before enabling a package type.

## Evidence format

Every test record should include:

~~~yaml
test_id: NOVA-HW-EXAMPLE-001
image_sha256: "<exact image digest>"
nova_commit: "<git commit>"
host_model: "<manufacturer and model>"
cpu: "<model and architecture>"
gpu: "<model and driver>"
firmware: "<BIOS/UEFI revision>"
kernel: "<kernel release>"
test_date_utc: "<ISO-8601>"
test_steps:
  - "<reproducible action>"
result: pass | fail | blocked
artifacts:
  - "<log/screenshot/test report>"
known_issues:
  - "<specific issue or empty list>"
~~~

Never include passwords, private keys, personal documents, or other user data in test artifacts.

## Release gate

A release candidate cannot be marked ready until:
- UEFI boot and install passes.
- Legacy BIOS behavior is explicitly documented (pass or unsupported).
- Secure Boot status is accurately represented.
- At least one AMD and one Intel physical system complete the baseline tests.
- GPU, Wi-Fi, Bluetooth, audio, USB, suspend/resume and display hotplug are tested.
- Updates and rollback/recovery are tested.
- Runtime-specific compatibility evidence exists for every runtime labeled available.
- Critical and high severity vulnerabilities are resolved or have an approved, documented mitigation.
