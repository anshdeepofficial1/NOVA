# Compatibility and runtime policy

## Truthful status vocabulary

- **Planned:** a design or integration is on the roadmap; it is not runnable yet.
- **Experimental:** an integration exists but has limited, version-specific validation.
- **Available:** a maintained runtime is installed and its health checks pass on this host.
- **Verified for app/version:** a repeatable end-to-end test passed for that exact app version, runtime version, host build and architecture.
- **Unavailable:** the required runtime or legal/hardware conditions are not met.

The initial NOVA planner currently returns planned, experimental or unavailable only. It never reports an app as verified.

## Format routing

| Input | Intended runtime | Current status in this repository |
|---|---|---|
| APK | Waydroid Android container | Experimental plan only; no installer/runtime |
| EXE | Wine/Proton; optional licensed Windows VM | Experimental plan only; no installer/runtime |
| MSI | Wine installer path; optional licensed Windows VM | Experimental plan only; no installer/runtime |
| DMG | Eligible macOS environment | Unavailable |
| PKG | Eligible macOS environment | Unavailable |
| DEB | Native Debian package manager | Planned |
| AppImage | Native Linux userspace | Planned |
| RPM | Native RPM package manager | Planned |
| Flatpak reference | Flatpak | Planned |
| HTTP(S) URL | Browser/PWA | Planned |

## Before enabling a runtime

1. Detect architecture and host prerequisites.
2. Verify the selected runtime binary, package/image signatures and versions.
3. Check disk, memory, GPU, kernel and virtualization capabilities.
4. Display the access the app will receive.
5. Create a disposable sandbox/prefix/VM by default.
6. Obtain explicit user approval for install, network and device access.
7. Run startup and health checks; fail closed if they fail.
8. Record a privacy-conscious diagnostic report.
9. Update compatibility status only after reproducible tests.

File extensions are hints, not proof of file content. A future installer must inspect actual file format and signature before acting.
