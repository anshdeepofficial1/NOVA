# NOVA Phase 1 Completion Plan

**Status:** Complete — M0 and M1 accepted on November 7, 2026  
**Scope:** M0 — Source foundation and M1 — Bootable development image  
**Target:** Debian 13 (Trixie), amd64, KDE Plasma/Wayland

This plan closes the foundation and bootable-image gates already defined in
`docs/release-gates.md`. It does not pull later milestones into Phase 1:
installation acceptance, physical-device certification, production runtime
adapters, cloud services, a custom compositor and AI assistant remain later work.

## Work sequence

### 1. Establish the baseline
- Record the starting main-branch commit and latest CI/ISO workflow results.
- Preserve existing passing Rust, API, frontend and native-package checks.
- Capture current boot diagnostics before changing boot configuration.
- Keep every fix traceable to a Phase 1 acceptance requirement.

### 2. Fix legacy BIOS automatic boot
- Override Debian Live's default ISOLINUX configuration in
  `os/debian-live/config/bootloaders/isolinux/isolinux.cfg`.
- Keep the graphical menu and all Debian Live menu entries.
- Select the default live entry and use a five-second Syslinux timeout.
- Validate both the source override and the generated `/isolinux/isolinux.cfg`
  extracted from the final ISO.
- Confirm BIOS QEMU reaches the live system's systemd serial login prompt
  without pressing a key.

### 3. Fix native desktop daemon lifecycle
- Replace the recursive daemon-wait function with a bounded health-check loop.
- Call the wait loop during Tauri startup before spawning the bundled sidecar.
- Reuse a healthy per-user system service and start a sidecar only when the
  service does not become healthy within the grace period.
- Keep sidecar ownership and process-group cleanup tied to the desktop app.
- Add deterministic tests for immediate readiness, readiness during the grace
  period, and a service that remains offline.

### 4. Strengthen automated checks
- Run the existing Rust format, unit-test and Clippy checks.
- Run the API health, system-info and compatibility smoke tests.
- Run frontend typecheck and production build.
- Build and inspect the native Debian desktop package and its daemon sidecar.
- Install and launch the packaged desktop under a disposable Xvfb/DBus session; verify the bundled daemon health endpoint starts and stops with the app.
- Validate the Debian Trixie live-build configuration.
- Validate the final ISO checksum, BIOS/UEFI boot catalog, EFI loaders/signatures,
  GRUB configuration, ISOLINUX configuration, kernel, initrd and SquashFS.
- Capture the resolved root npm, Rust workspace and Tauri crate dependency lockfiles;
  commit them and switch CI builds to locked installation/resolution modes.

### 5. Rebuild and firmware-test a fresh image
- Build a fresh ISO from the corrected main-branch commit.
- Run non-installing QEMU tests with no virtual disk attached:
  - Legacy BIOS
  - Standard UEFI
  - Secure Boot UEFI
- Require each firmware path to reach the live system's serial login prompt.
- Archive the ISO, SHA-256, build manifest, complete build log and validation
  evidence with the workflow run.

### 6. Close Phase 1
Phase 1 is accepted only when all of the following are true:
- M0 source and native desktop CI passes.
- The desktop daemon-start regression tests and packaged-app sidecar smoke test pass.
- npm and both Rust Cargo lockfiles are committed and enforced by CI.
- The fresh ISO build and structural validation pass.
- BIOS, standard UEFI and Secure Boot UEFI boot smoke tests all pass.
- Build artifacts and validation evidence are available from the successful run.
- The README/release-gate status reflects the verified state.

## Verified Phase 1 acceptance — November 7, 2026

**Validated source commit:** [`a89452a96fd75784fb913000442468995340e08f`](https://github.com/anshdeepofficial1/NOVA/commit/a89452a96fd75784fb913000442468995340e08f)

**Acceptance evidence:**
- [NOVA CI #149 — success](https://github.com/anshdeepofficial1/NOVA/actions/runs/42355442117): source formatting, unit tests, Clippy, Trixie live-build configuration, locked dependencies, frontend typecheck/build, daemon API including malformed/oversized requests, native `.deb` build, actual packaged-desktop start/normal-close sidecar cleanup, and Tauri regression tests.
- [Build NOVA ISO #37 — success](https://github.com/anshdeepofficial1/NOVA/actions/runs/42355442136): fresh ISO, checksum verification, boot structure, signed EFI loaders, GRUB and five-second ISOLINUX menu validation, all three QEMU firmware boot tests, and archived artifacts.
- **Firmware results from uploaded QEMU diagnostics:** BIOS **PASS** (86 seconds), UEFI **PASS** (92 seconds), Secure Boot UEFI **PASS** (88 seconds). All reached the live system's systemd serial login prompt.
- **ISO artifact:** `NOVA-OS-amd64-experimental`, size **3,412,525,056 bytes**, SHA-256 `fa7795a78492a8f4fa4b77303de11f5e589e1d35cd360b7ae6a0c032876462a3`. The [successful ISO run](https://github.com/anshdeepofficial1/NOVA/actions/runs/42355442136) supplies the image, checksum, build manifest, logs and validation archive.
- **Boot diagnostics artifact:** `NOVA-ISO-boot-diagnostics` (same run), containing per-firmware result files, serial logs, screenshots and boot-structure reports.

**Decision:** Phase 1 (M0 + M1) is COMPLETE. Phase 2 may proceed.

**Scope limit:** This verifies a bootable *development/live* ISO under QEMU. It does **not** certify an installed operating system, physical hardware, production app execution compatibility, graphical UI on real hardware, disk migration/recovery, or a stable public release; these have their own later milestones.

## Explicit non-goals for Phase 1

Do not mark these as complete merely because related packages or detection code
exist: installed-system acceptance and recovery, physical-hardware certification,
production APK/EXE/DMG execution, Waydroid provisioning, Wine prefix management,
cloud workspaces, a custom NOVA compositor, and AI system actions. Those belong
to subsequent milestones and require their own tests and safety gates.
