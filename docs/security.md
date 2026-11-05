# NOVA security model

## Current implementation boundary

The current Rust daemon:
- Binds to loopback by default (127.0.0.1:47820).
- Accepts a bounded JSON compatibility-inspection request.
- Reads standard OS/kernel metadata and checks known executable paths/device indicators.
- Returns host capability and runtime-prerequisite information.

It does **not** read arbitrary package files, execute a user-supplied path, invoke a shell, install packages, initialize Waydroid, create VMs, mount images, elevate privileges or access the network on behalf of an application.

The live image runs the daemon as a per-user systemd service with basic hardening directives. The Tauri process is also an unprivileged desktop client. The daemon's CORS allow-list limits browser origins but **CORS is not authentication**; loopback services can still be called by other local processes. This is acceptable only while the API is observational. Do not add privileged operations to this API without a separate authenticated IPC and permission design.

## Threats

- Malicious, malformed or deceptive package files and filenames.
- Runtime/container/VM escape or over-broad host filesystem mounting.
- Confused-deputy attacks against privileged package managers or host services.
- Untrusted URLs, redirects, browser content and compromised package repositories.
- Credential, clipboard, screen, microphone, camera, USB or file exfiltration.
- Compromised OS/application updates or supply-chain dependencies.
- Denial of service from oversized requests, runaway guests or malicious archives.

## Mandatory controls for future runtime work

- Run apps and user-facing installers as unprivileged users. Never execute an installer as root.
- Keep privileged service code small, auditable and separate from the UI.
- Isolate Wine prefixes, Android containers and guest VMs; deny host filesystem/device/network access by default.
- Apply seccomp and AppArmor/SELinux profiles where supported; minimize Linux capabilities and device access.
- Require explicit per-app permissions for files, networking, USB, camera, microphone, clipboard and screen capture.
- Verify signed repositories/artifacts, pin dependencies and runtime versions, publish an SBOM and retain build provenance.
- Use authenticated updates, atomic or transactional deployment where available, rollback and a separately protected recovery path.
- Validate actual package formats and hashes; never trust filenames or MIME types alone.
- Cap archive expansion, CPU, memory, disk, process count, network and launch duration.
- Record privilege-sensitive audit events without collecting secrets or private file contents.
- Maintain vulnerability intake, CVE monitoring, patch SLAs and a security release process.

## ISO and installer safety

The live image must not auto-partition, format or overwrite disks on boot. Installation must show target disks and destructive actions clearly, require user confirmation, and be tested in disposable VMs. Secure Boot behavior, bootloader installation, encryption, Btrfs subvolumes and recovery must be validated before a stable release.

## Release gates

Do not mark a runtime available until its sandbox boundary, permission prompts, failure handling, uninstall/update path and app-specific test suite pass review. Do not ship an ISO until it boots in UEFI and BIOS test environments, installs to a VM disk, reboots from the installed disk and passes smoke/hardware tests. Critical security defects block release regardless of feature completeness.
