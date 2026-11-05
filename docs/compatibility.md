# Compatibility and runtime policy

## Status vocabulary

- **Detected:** NOVA found an executable or prerequisite. This does not mean an app can run.
- **Initialized:** a runtime's basic host configuration appears to exist. It still requires health checks and workload testing.
- **Prerequisite missing:** a runtime exists but a required session, kernel feature or device was not detected.
- **Not installed:** the executable was not found on the current process PATH.
- **Not configured:** a planned remote service or workspace has no endpoint/configuration.
- **Unavailable:** the runtime is not supported by the current host or platform.
- **Verified for app/version:** only after a repeatable end-to-end test for the exact app version, runtime version, NOVA build, host distribution, architecture and hardware profile.

The daemon's host report uses these observational states. The compatibility planner returns planned, experimental or unavailable for format routing. Neither system marks arbitrary downloaded apps as verified.

## Package routing matrix

| Input | Intended runtime | NOVA planner state | What must pass before execution |
|---|---|---|---|
| APK | Waydroid Android container | Experimental | Android image, Binder, Wayland, graphics, input/audio and app-specific validation |
| EXE | Wine/Proton | Experimental | Architecture, dependencies, app/version compatibility and disposable prefix |
| MSI | Wine/Proton installer flow | Experimental | Same checks as EXE; installer is untrusted input |
| DMG | Eligible macOS environment | Unavailable on NOVA Linux | Apple hardware/license compliance and a separately built integration |
| PKG | Eligible macOS environment | Unavailable on NOVA Linux | Apple hardware/license compliance and a separately built integration |
| DEB | Native Debian package manager | Planned | Signature/source validation, dependency resolution and rollback |
| AppImage | Native Linux userspace | Planned | Format validation, trust/signature check, sandbox and desktop integration |
| RPM | Native RPM package manager | Planned | Host distribution compatibility and package signature checks |
| Flatpak reference | Flatpak | Planned | Signed remote, app permissions and portal policy |
| HTTP(S) URL | Browser/PWA | Planned | Origin validation, browser isolation and PWA metadata |

## Current host-discovery behavior

The local daemon checks known executables on PATH and read-only host indicators:
- Distribution and kernel release from standard Linux metadata.
- Session type and WAYLAND_DISPLAY.
- Waydroid executable, Binder device/config indicators and Wayland session.
- Wine executable.
- QEMU executable and /dev/kvm.
- Flatpak and a browser executable.
- Native package-manager executable.

It does not execute these binaries, initialize Waydroid, start a VM, install packages, inspect the bytes of a user file or modify the host. The result is a prerequisite report, not an application compatibility verdict.

## Required gates before a runtime is enabled

1. Validate the real file format; extensions are untrusted hints.
2. Verify signed source, publisher identity, hash and package architecture.
3. Check runtime, kernel, GPU, disk, memory and virtualization requirements.
4. Create a disposable sandbox/prefix/guest with default-deny host filesystem access.
5. Show requested permissions and obtain explicit user consent.
6. Apply CPU, memory, storage, process and network limits.
7. Run app-specific automated startup, UI, update and uninstall tests.
8. Collect privacy-conscious diagnostics and preserve rollback/recovery.
9. Update the matrix only for the tested app/version/host combination.

Never describe a file format as universally supported. A successful launch on one machine does not certify all versions, distributions, GPUs or devices.
