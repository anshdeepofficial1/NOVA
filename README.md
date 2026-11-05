# NOVA OS

NOVA is an ambitious hybrid desktop and cloud operating-system project. The first milestone is a safe, testable control plane and desktop-shell prototype that can grow into a bootable Linux distribution.

> **Project status: early foundation / experimental.** This repository does not yet contain a bootable OS image or working Android, Windows, or macOS application runtimes. The compatibility planner identifies the correct execution path; it does not claim that every app can run.

## Product direction

NOVA aims to provide one desktop experience for:

- Native Linux applications and packages.
- Android applications through a compatible Android container (planned: Waydroid).
- Windows applications through Wine/Proton where compatible, with an optional licensed Windows VM for other cases.
- Web applications and PWAs.
- macOS applications only through a properly licensed macOS environment on eligible Apple hardware. A DMG is a disk-image installer, not a universal executable format.
- Local and remote/cloud workspaces, with explicit user consent for remote execution.

No compatibility layer can guarantee every application. NOVA will show capability and confidence honestly, and never silently route untrusted installers to privileged execution.

## Repository layout

```text
.
├── apps/
│   └── shell/             # React + TypeScript desktop-shell prototype
├── crates/
│   ├── nova-core/         # Shared domain types and compatibility planner
│   └── nova-daemon/       # Local host API (Axum)
├── docs/
│   ├── architecture.md
│   ├── compatibility.md
│   ├── security.md
│   └── development.md
├── scripts/
│   └── check-host.sh
├── .github/workflows/ci.yml
├── Cargo.toml
└── package.json
```

## Current capabilities

- Rust compatibility inspection for APK, EXE/MSI, DMG, DEB, AppImage, and web URLs.
- Deterministic runtime planning with explicit experimental/unsupported states.
- Local daemon endpoints for health, system capability reporting, and package inspection.
- A browser-based NOVA shell prototype that connects to the local daemon.
- Rust unit tests and frontend type/build checks in CI.

## Not implemented yet

- Kernel, bootloader, installer, disk partitioning, and bootable ISO.
- Production Wayland compositor / window manager and native desktop integration.
- Waydroid installation, Android image management, Google service compatibility, or APK execution.
- Wine/Proton prefix management, Windows executable launch, or Windows VM provisioning.
- macOS VM execution; this is subject to Apple hardware and software licensing.
- Cloud desktop infrastructure, remote GPU streaming, account sync, and production app store.
- Privileged device management, updates, recovery, and secure-boot integration.

These are separate engineering milestones. The UI or planner must not imply that a runtime works until a real end-to-end integration test passes.

## Requirements

- Rust stable toolchain (edition 2021)
- Node.js 20+ and npm
- Linux is the intended host for future OS/runtime work. The API and shell prototype can be developed on other platforms.

## Development

Start the host API:

```bash
cargo run -p nova-daemon
```

In another terminal, start the shell:

```bash
npm install
npm run dev
```

The shell expects the local API at `http://127.0.0.1:47820`. The daemon enables permissive CORS for localhost development only; production deployment must use an authenticated, origin-restricted IPC/API boundary.

Run checks:

```bash
cargo fmt --all -- --check
cargo test --workspace
npm ci
npm run build
```

## Safety boundary

The current API only inspects package metadata and returns a runtime plan. It does **not** execute uploaded files, invoke a shell, install packages, elevate privileges, or start VMs/containers. Do not add arbitrary file execution to the daemon. Runtime adapters must be isolated, capability-checked, permission-gated, auditable, and tested against malicious input.

## Roadmap

1. **Foundation:** shared domain model, daemon API, shell prototype, CI and threat model.
2. **Linux desktop:** choose a stable base distribution, boot flow, Wayland compositor, drivers, settings, file manager and atomic update/recovery strategy.
3. **Linux apps:** native package handling and sandboxed application packaging.
4. **Android:** Waydroid integration on supported kernels/graphics stacks; validate Binder, GPU, audio and input.
5. **Windows:** Wine/Proton management, compatibility profiles and licensed VM fallback.
6. **Cloud:** secure remote sessions, WebRTC streaming, identity, storage and billing controls.
7. **macOS:** investigate only compliant Apple-hardware workflows and licensing; no Hackintosh workaround.

## Contribution principles

- Build in small, reviewable increments.
- Keep privileged code minimal and separate from the UI.
- Add tests for every compatibility decision and failure path.
- Never report a runtime as supported without reproducible test evidence.
- Use upstream projects rather than copying large third-party codebases into NOVA. Preserve upstream licenses and notices.

See [docs/architecture.md](docs/architecture.md), [docs/compatibility.md](docs/compatibility.md), [docs/security.md](docs/security.md), and [docs/development.md](docs/development.md).
