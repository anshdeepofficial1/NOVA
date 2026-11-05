# NOVA architecture

## Product boundary

NOVA is a bootable Linux distribution plus a native desktop workspace and a separately deployed cloud-workspace service. The React UI is not itself an operating system. The Tauri application runs as an unprivileged desktop client; the local Rust daemon exposes a narrow loopback API.

## First PC platform decision

The initial target is **Debian 13 (Trixie), amd64, KDE Plasma/Wayland**.

Why this first:
- Debian publishes live-install media for amd64 and maintains the live-build tooling and Debian Installer.
- The Debian Installer live mode installs the booted live filesystem to disk rather than requiring NOVA to build a kernel or installer from scratch.
- Trixie offers a maintained KDE Plasma 6 stack, native Debian packages and Flatpak integration.
- Waydroid's current desktop-install guidance identifies Debian 13 backports as its package route and requires a Wayland session.
- This gives NOVA a supported distribution base while we focus on integration, user experience, hardware testing and recovery.

The image recipe is in os/debian-live. It is an experimental configuration; only an actual ISO build and VM/hardware testing can prove the image is bootable and usable. The first target is amd64. ARM64 must be a separately tested image target, not a copy of the amd64 assumptions.

## Layer model

1. **Hardware and Linux base** — firmware, Linux kernel, drivers, bootloader, systemd, storage, power and networking.
2. **Graphics/session** — KDE Plasma and KWin Wayland for the first image. A NOVA compositor is a later, separate project with input, multi-output, accessibility, scaling and GPU requirements.
3. **NOVA Host Service** — Rust API for read-only host capability discovery and compatibility planning today. Future services will manage runtimes, permissions, updates and recovery through narrow interfaces.
4. **NOVA Runtime Policy** — a separate Rust crate validates app/artifact-bound approval grants, supported permissions, runtime readiness and resource bounds before producing a default-deny sandbox plan.
4. **Runtime adapters** — native Linux packages, Flatpak, Waydroid, Wine/Proton, QEMU/KVM and browser/PWA.
5. **NOVA Desktop** — Tauri native window hosting React + TypeScript. This is an application/workspace, not a replacement for KWin or the desktop session.
6. **NOVA Cloud** — future identity, workspace broker, isolated per-user VMs/containers, encrypted storage, signaling and remote session streaming.

## Current data flow

~~~mermaid
flowchart TD
  User[User] --> Desktop[NOVA Desktop - Tauri]
  Desktop --> API[Loopback NOVA API]
  API --> Core[Pure Compatibility Planner]
  API --> Detect[Read-only Host Discovery]
  Core --> Plan[Package Runtime Plan]
  Detect --> Facts[Host and Runtime Facts]
  Plan --> Desktop
  Facts --> Desktop
  Plan -. Future only, permission gated .-> Adapter[Runtime Adapter]
  Adapter --> Sandbox[Container / VM / Native Sandbox]
  Cloud[Future NOVA Cloud] -. Remote workspace .-> Desktop
~~~

The planner and detector have no authority to install or launch software. A future adapter must own that lifecycle and return a typed result.

## Runtime strategy

| Format / workload | Intended execution | Current repository state |
|---|---|---|
| DEB / native Linux | Debian package tooling | Host package-manager detection only |
| Flatpak | Flatpak + portals/sandbox permissions | Executable detection only |
| APK | Waydroid Android container | Package in image recipe; no NOVA app provisioning/launch manager |
| EXE / MSI | Wine/Proton in isolated per-app prefixes | Wine detection only; no installer/launch manager |
| Windows-only workloads | Licensed Windows guest via QEMU/KVM | QEMU/KVM detection only; no VM lifecycle or license flow |
| DMG / PKG | Eligible macOS environment | Not supported by Linux image |
| Web/PWA | Browser/PWA workspace | URL classification only |
| Cloud workload | Isolated cloud guest/container + secure remote session | Not implemented |

### Runtime constraints

- Waydroid depends on kernel Binder support, a compatible Android image, Wayland/graphics/input/audio and app-specific behavior. A working container does not imply Play Integrity, Play Store certification, DRM or banking-app support.
- Wine is a Windows API compatibility layer, not a Windows kernel or complete Windows installation. Application compatibility is specific to app version, architecture, graphics and dependencies.
- QEMU/KVM hardware acceleration requires KVM device access and compatible CPU/firmware settings. Software emulation is not an equivalent performance fallback.
- DMG is a disk image and PKG is a macOS installer. They are not Linux-native application formats. Any future macOS workflow must comply with Apple's current license and hardware requirements.
- Browser-only clients cannot use arbitrary local machine privileges. Native host execution needs a local agent or remote execution in a cloud guest.

## Host API

Current endpoints:
- GET /health — liveness.
- GET /api/system — host OS, architecture, kernel, distribution, session and runtime prerequisite states.
- POST /api/compatibility/inspect — inspect a bounded filename/URL hint and return an execution plan.

The daemon binds to 127.0.0.1:47820, permits only the local development and Tauri origins, and caps request bodies at 8 KiB. CORS is not authentication. Because current endpoints are observational, no privileged action is exposed. Any future mutating endpoint requires authentication/IPC hardening, explicit user consent and an independently reviewed permission model.

## Future adapter contract

A runtime adapter should implement:
1. Detect prerequisites and host compatibility.
2. Validate actual file type, signature, hash and architecture.
3. Resolve a pinned runtime version and disposable environment.
4. Show requested filesystem, network, device, clipboard and media permissions.
5. Obtain an explicit user confirmation for installation and execution.
6. Prepare an isolated prefix/container/VM with default-deny host access.
7. Start, health-check, stop and clean up with bounded time/resources.
8. Return a typed, auditable result and diagnostic bundle without secrets.

No UI component should construct arbitrary shell commands or directly access a privileged runtime. The current policy crate does not launch applications; a production signature signer/verifier and independently reviewed runtime adapters are still required.

See [docs/runtime-adapters.md](runtime-adapters.md) for the consent, policy and adapter contract.
