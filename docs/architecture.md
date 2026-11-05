# NOVA architecture

## Design rule

NOVA is a Linux-based operating-system distribution plus a separately deployable remote-workspace service. The browser shell is only a client interface; it is not itself an operating system and cannot directly execute arbitrary host applications.

## Layers

1. **Hardware and Linux base** — bootloader, Linux kernel, firmware, drivers, systemd, storage and networking.
2. **Graphics/session** — a maintained Wayland compositor/window manager; input, surfaces, display outputs and accessibility.
3. **NOVA host services** — narrowly scoped services for app discovery, package metadata, settings, runtime lifecycle, updates and permissions.
4. **Runtime adapters** — native Linux, Flatpak, Waydroid, Wine/Proton, QEMU/KVM, and browser/PWA. Each adapter exposes capability and health data.
5. **Shell** — desktop UI, launcher, notifications, settings, file manager and task switching.
6. **Cloud services** — identity, workspace broker, encrypted storage, remote session signaling and telemetry only with opt-in.

## Initial control-plane flow

~~~mermaid
flowchart TD
  User[User] --> Shell[NOVA Shell]
  Shell --> API[Loopback NOVA API]
  API --> Core[Compatibility Planner]
  Core --> Plan[Runtime Plan + Capability State]
  Plan --> Shell
  Plan -. future, permission-gated .-> Adapter[Runtime Adapter]
  Adapter --> Sandbox[Container / VM / Native Sandbox]
~~~

The current implementation stops at the runtime plan. It intentionally does not invoke adapters.

## Technology choices

- **Linux base:** choose a supported distribution and pin a tested release; do not fork the kernel for the first milestone.
- **Graphics:** Wayland compositor selected after hardware, multi-GPU, fractional-scaling, accessibility and remote-session tests.
- **Host services:** Rust for small system services and typed IPC boundaries.
- **Shell:** React + TypeScript for the initial prototype. A production shell must integrate with the chosen compositor and native accessibility/input APIs.
- **Containers:** Waydroid for Android only after host-kernel and GPU compatibility checks.
- **Windows compatibility:** Wine/Proton for compatible applications; licensed Windows VMs for software that requires Windows itself.
- **Virtualization:** QEMU/KVM and libvirt on hosts that support hardware virtualization.
- **Cloud desktop:** isolated per-user VMs or containers with a secure gateway and a low-latency streaming protocol.

## Important platform constraints

- APK execution depends on Android image, architecture, kernel features, graphics, Binder, audio and app-specific Google/DRM requirements.
- EXE compatibility is not universal. Wine reimplements Windows APIs; it is not a full Windows installation.
- DMG is a macOS disk image. It is not a format Linux can natively execute. Any macOS VM plan must be validated against Apple's current license and hardware rules.
- Browser clients need a host-side agent or cloud session. Browser sandbox permissions do not grant them general local machine access.

## Service contracts

Keep stable, versioned schemas between shell and daemon. All launch/install requests in future versions should include:
- application identifier and immutable source/version;
- requested runtime and tested capability profile;
- explicit permissions (files, network, devices, clipboard, camera, microphone);
- user confirmation token for sensitive actions;
- sandbox profile and resource limits;
- audit event ID and structured result/error.

Never let the UI submit arbitrary shell commands to a privileged service.
