# NOVA release gates

This document prevents a roadmap item, a package in an image, or a successful build from being mistaken for a completed feature.

## Product milestones

### M0 — Source foundation
- Workspace compiles with warnings denied.
- Unit tests and API smoke tests pass.
- TypeScript checks and production build pass.
- Native desktop package contains the UI and its intended local service.
- Dependency and build provenance are recorded.

### M1 — Bootable development image
- Manual amd64 ISO build completes and produces SHA-256.
- ISO boot records are present.
- Live session boots in UEFI and legacy BIOS test VMs (or legacy is explicitly unsupported).
- No disk is modified until the user enters the installer and confirms an explicit target.
- ISO build logs and reproducible test evidence are archived.

### M2 — Installable PC system
- Debian Installer live mode completes in a disposable VM.
- Installed system reboots after the ISO is removed.
- User account, bootloader, network, graphics and audio are functional.
- Update, rollback/recovery and encrypted storage behavior are validated.
- Physical-device baseline matrix passes.

### M3 — Native Linux applications
- Signed package and Flatpak repository checks.
- Sandboxed install/update/uninstall flow.
- Portal permissions and rollback.
- App catalog and verified compatibility evidence.

### M4 — Android runtime
- Supported kernel/Binder and Waydroid prerequisite detection.
- Provisioning/initialization, app lifecycle, storage, input, audio and graphics tests.
- Clear Play Integrity, DRM, Google services and app-specific limitations.
- No universal APK support claims.

### M5 — Windows runtime
- Wine/Proton prefix manager with isolated per-app state.
- Versioned compatibility database and reproducible tests.
- Optional licensed Windows VM lifecycle for incompatible workloads.
- Windows activation/licensing and VM storage/network boundaries reviewed.

### M6 — Cloud workspaces
- Authenticated identity and device enrollment.
- Per-user VM/container isolation and quota limits.
- Encrypted storage and secure remote session gateway.
- Network isolation, session termination, audit and incident response.
- Privacy, retention and data deletion controls.

### M7 — AI system assistant
- Narrow capability API; no arbitrary shell endpoint.
- Explicit user confirmation for consequential actions.
- Per-app and per-device permission policy.
- Audit records, cancellation, rollback and abuse tests.
- AI must not be a privileged service identity.

## Automated quality gates

Every pull request should pass:
- Rust formatting.
- Rust unit tests.
- Clippy with warnings denied.
- Rust dependency audit and license/SBOM checks (to be added before a public release).
- Frontend type-check and production build.
- Native Debian package build and package-content verification.
- Local API smoke tests including malformed input, unsupported types and request-size limits.
- Secret scanning and static analysis.
- Relevant integration tests in disposable environments.

## Operational quality

Before any stable release:
- Publish a software bill of materials and source/build provenance.
- Define supported hardware, distribution, architecture and runtime versions.
- Define vulnerability intake, severity, patch windows and disclosure handling.
- Use signed updates and a tested rollback/recovery mechanism.
- Provide logs that help users diagnose failures without collecting private files or credentials.
- Keep a public known-issues list and compatibility matrix.
- Test upgrades from the previous release and clean installs.
- Have a release owner approve security and installer gates.

## Reliability targets

Set measurable targets after gathering baseline telemetry from consenting test systems. Candidate targets:
- No known data-loss installer defects.
- No unhandled crash in the core desktop session during the test suite.
- A recoverable update failure path for the base OS.
- Runtime status never reported as available when prerequisites or health checks fail.
- No privileged command execution from the webview.
- No critical/high security finding left unresolved at stable release.

These are release goals, not claims about the current experimental build.
