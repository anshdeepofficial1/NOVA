# NOVA Phase 2 — Installable PC OS (Implementation and acceptance)

**Status: In progress.** Phase 1 source/ISO gates passed, but no installed
NOVA system has been certified. Phase 2 must not be declared finished until
the tests below have actually passed. No user-side testing is required during
development; all destructive installer tests use disposable CI VM disks.

## Phase boundary

Phase 2 is a reliably installable, bootable, functional Debian-based PC OS.
Phase 3 is the custom NOVA user experience. Android/Windows app launchers,
cloud, AI and Web OS are subsequent phases, not Phase 2 sign-off shortcuts.

## Delivery tracks

1. **Installer discovery and safety**
   - Assert live ISO includes the real Debian Installer kernel/initrd.
   - Preserve default interactive installation; never embed an unattended
     destructive preseed in shipped images or default GRUB/Syslinux entries.
   - Run unattended acceptance only with an initrd-injected, CI-only preseed
     targeting a newly created QEMU qcow2 virtual disk. Refuse reused disks.
   - Confirm no other guest disk is present and no host block device is passed.

2. **Install and reboot (UEFI + legacy BIOS)**
   - Install the exact ISO downloaded from a green build workflow.
   - Test UEFI and legacy BIOS partition/bootloader paths separately.
   - Remove the ISO and verify the installed disk boots through firmware.
   - In a test-only first-boot systemd unit, validate root mount, user account,
     desktop and audio packages, networking tools, autostart definitions,
     actual NOVA daemon health and clean shutdown. Capture serial logs.

3. **Graphical session and core hardware (virtual)**
   - Verify SDDM login, KDE Wayland session, NOVA shell launch, file manager,
     network settings, audio devices and session permissions in a real VM.
   - Include screenshots/video capture from reproducible QEMU runs.
   - Test session restart, daemon crash/restart and multi-user isolation.

4. **Storage, rollback and updates**
   - Implement and test an explicit storage policy with safe partition
     selection, full-disk encryption option, filesystem checks, and backed-up
     recovery. Verify snapshots and actual recovery after an interrupted
     update—not merely installation of btrfs-progs/snapper utilities.
   - Add signed update provenance checks and simulate update failures.
   - Test preservation of non-target disk/partition data.

5. **Device support and physical qualification**
   - VM smoke-test basic virtual GPU, input, network, audio, storage and
     reboot; record device identifiers.
   - Physical AMD/Intel, NVIDIA/AMD GPU, Wi-Fi/Bluetooth, audio, NVMe, USB,
     battery/suspend, high-DPI and multi-monitor acceptance require real
     compatible hardware or a dedicated hardware lab. A cloud VM cannot
     truthfully claim these tests passed.

6. **Security/release gates**
   - Locked dependencies, script lint, isolation checks, privileged IPC policy,
     image checksum, separate installer logs and per-firmware result reports.
   - Run installer tests from immutable successful ISO artifacts.
   - A missing result, frozen VM, incomplete installation or failed guest
     health check is an explicit failure, never a pass.

## Implementation progress

- [x] Phase 1 source and ISO boot evidence validated separately.
- [x] Add CI-only virtual disk installation and first-boot acceptance harness
      (implementation created; PASS evidence pending).
- [x] Add isolated GitHub Actions installer workflow using successful ISO artifacts.
- [ ] Installer boots and finishes unattended on UEFI VM.
- [ ] Installed UEFI guest boots without ISO and passes actual daemon/desktop tests.
- [ ] BIOS installer and installed BIOS boot pass.
- [ ] Graphical KDE session is tested end to end in VM.
- [ ] Signed updates, encrypted layout, snapshot rollback and recovery tested.
- [ ] Hardware test matrix and physical-device testing covered with evidence.

**Important:** Implemented test code is not evidence of success. The workflow
must complete and produce successful guest marker logs before checking any
UEFI/BIOS acceptance item.

## Evidence

- [Phase 1 green ISO #37](https://github.com/anshdeepofficial1/NOVA/actions/runs/42355442136)
- [Phase 2 installer workflow](https://github.com/anshdeepofficial1/NOVA/actions/workflows/phase-2-installer.yml)
- Per-test logs: `NOVA-Phase2-installation-diagnostics` artifact from each run.
- Readiness and scope: [release gates](release-gates.md),
  [hardware matrix](hardware-validation.md).

## No implicit completion

Do not claim Phase 2 complete from an ISO boot or successful Debian Installer
alone. Independent boot, real graphical session, network, audio, user services,
updates, rollback, security and physical-device qualification must have their
own verifiable evidence.
