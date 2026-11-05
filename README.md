# NOVA OS

NOVA is a hybrid operating-system project: a bootable Linux desktop for physical PCs, a native desktop workspace, application compatibility runtimes, and a separately deployed cloud-workspace service.

> **Status: experimental foundation.** The repository now contains a Debian live-image recipe, a native Tauri desktop app, a Rust host API and runtime-prerequisite discovery. The ISO build workflow has been added but an ISO has not yet passed a full build-and-VM acceptance cycle. APK/EXE/DMG execution, cloud workspaces and a production NOVA compositor are not complete.

## Product architecture

The first PC target is **Debian 13 (Trixie), amd64, KDE Plasma/Wayland**. This uses a maintained Linux kernel, driver stack, package ecosystem and Debian Installer live mode rather than starting with a custom kernel or bootloader.

NOVA is split into these layers:

1. **NOVA OS image** — reproducible Debian live-build configuration, KDE desktop, firmware and a live installer.
2. **NOVA Desktop** — native Tauri application whose interface is React + TypeScript.
3. **NOVA Host Service** — Rust/Axum API, bound to loopback, that reports host details and inspects compatibility hints.
4. **Runtime integrations** — native Debian/Flatpak, Waydroid, Wine/Proton, QEMU/KVM and browser/PWA. Presence is detected; execution and app-specific compatibility are separate milestones.
5. **NOVA Cloud** — future isolated compute, identity, encrypted storage and remote-session gateway.

A website cannot directly execute arbitrary APK, EXE or DMG files on the user's device. NOVA Desktop and its local host service are the bridge to actual host capabilities; NOVA Cloud is the route for remote workloads.

## Repository structure

~~~text
.
├── apps/shell/                  # React UI + Tauri native desktop app
├── crates/
│   ├── nova-core/              # Pure compatibility planning and package classification
│   └── nova-daemon/             # Rust loopback API and host capability detection
├── os/debian-live/              # Debian Trixie amd64 live ISO configuration
├── docs/                        # Architecture, compatibility, security and development
├── scripts/                     # Host development checks
└── .github/workflows/
    ├── ci.yml                   # Rust, frontend and native desktop package CI
    └── build-iso.yml             # Manual bootable ISO build
~~~

## Implemented in this repository

- Rust package-hint inspection for APK, EXE, MSI, DMG, PKG, DEB, AppImage, RPM, Flatpak references and HTTP(S) URLs.
- A compatibility planner that returns a runtime choice and an honest status; it never launches a file.
- Host discovery for OS/kernel, distribution, session type, package manager, Flatpak, Waydroid, Wayland/Binder prerequisites, Wine, QEMU/KVM and browser executables.
- Runtime policy crate that requires a verified, app-and-artifact-bound approval grant, supported permissions, runtime readiness and bounded resource limits before it can produce a default-deny sandbox plan.
- Loopback-only Axum API with an 8 KiB request-body limit.
- Native Tauri desktop application with a bundled Rust daemon sidecar; the webview cannot spawn arbitrary commands.
- Tauri-generated desktop icon assets from the committed NOVA SVG source.
- Debian Trixie live-build recipe with KDE, live installer, Waydroid backports, Wine, QEMU/KVM, Flatpak and NOVA components.
- Per-user systemd service for the local NOVA daemon in the image.
- Automated Rust, frontend and native desktop CI; manual ISO build workflow.

## Not implemented yet

- A release-quality ISO validated on physical PCs and a VM test matrix.
- A custom NOVA Wayland compositor, window manager, login manager or full desktop session. The first image uses KDE Plasma.
- Production install/launch adapters for APK, EXE/MSI, DEB, AppImage or Flatpak.
- Production cryptographic approval signer/verifier and secure key storage. The policy crate currently provides the fail-closed contract and a test verifier only.
- Waydroid image provisioning, Android app lifecycle, Google Play certification or DRM/Play Integrity guarantees.
- Wine/Proton prefix management and app-specific compatibility database; Windows VM lifecycle and Windows licensing workflow.
- A production installer with tested Btrfs subvolume layout, Snapper snapshots and recovery UX.
- Cloud broker, multi-tenant isolation, remote GPU streaming, sync and account service.
- macOS runtime. DMG/PKG are macOS formats and are not executable on the Linux image.
- AI system assistant with permission-scoped actions.

## Run NOVA locally

Requirements: Rust 1.90+, Node.js 20+, npm and Git. The native desktop build stages a host daemon sidecar and generates the NOVA icon set from `apps/shell/src-tauri/brand/nova.svg`. For Tauri on Debian/Ubuntu, install the native dependencies from the [official Tauri prerequisites](https://v2.tauri.app/start/prerequisites/).

Terminal 1 — start the host service:

~~~bash
cargo run -p nova-daemon
~~~

Terminal 2 — start the browser development shell:

~~~bash
npm install
npm run dev
~~~

To run the native desktop window instead:

~~~bash
npm run desktop:dev
~~~

Build the native Linux package:

~~~bash
npm run desktop:build
~~~

The native Tauri app checks for the NOVA user service first and otherwise starts its bundled daemon sidecar. The sidecar is terminated with the desktop app. The browser-only Vite preview still requires `cargo run -p nova-daemon` in another terminal. The daemon is deliberately read-only today: capability lookup and package planning only. It does not install software, call a shell, start a VM or execute a selected file.

## Build the bootable image

See [os/debian-live/README.md](os/debian-live/README.md). A manual GitHub build is available under **Actions → Build NOVA ISO → Run workflow**. It uploads the ISO and SHA-256 checksum when a build succeeds.

Do not install an experimental image on a machine containing important data. Test the live session and installer in a disposable VM first.

## Validate changes

~~~bash
cargo fmt --all -- --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
npm run typecheck
npm run build
npm run desktop:build
~~~

## Engineering and safety principles

- Never claim universal APK/EXE/DMG compatibility.
- Never execute arbitrary installer contents as root.
- Keep all privileged host functionality out of the UI process.
- Create sandboxed runtime adapters with explicit permissions and resource limits.
- Treat file extensions as hints, not proof of file format or trust.
- Mark runtimes available only after real end-to-end tests for app/version/host/architecture.
- Use signed upstream packages, dependency pinning, SBOMs, automated tests, recovery and vulnerability response.
- Build on upstream Linux/runtime projects and preserve their licenses and notices.

See [architecture](docs/architecture.md), [compatibility policy](docs/compatibility.md), [runtime-adapter policy](docs/runtime-adapters.md), [security model](docs/security.md), [development guide](docs/development.md) and the [ISO builder](os/debian-live/README.md).
