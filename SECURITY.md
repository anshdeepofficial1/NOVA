# Security policy

NOVA is experimental and is not currently suitable for storing sensitive data or replacing a supported production operating system.

## Reporting a vulnerability

Do not publish exploit details, credentials, private keys or sensitive user data in a public issue.

Use GitHub's private vulnerability reporting feature for this repository if it is enabled. If private reporting is unavailable, contact the repository owner through a private GitHub channel and include:
- A concise description and affected commit/release.
- Reproduction steps in a disposable VM or test environment.
- Impact and any suggested mitigation.
- Relevant logs with secrets and personal data removed.

Please allow the maintainer a reasonable opportunity to investigate and prepare a fix before public disclosure.

## Scope

Security reports are especially valuable for:
- The Rust host daemon and local API.
- Tauri desktop/webview permissions and sidecar lifecycle.
- Runtime authorization and sandbox policy.
- Package intake, repositories and signature validation.
- Debian live image, installer and update/recovery behavior.
- Future Waydroid, Wine/Proton, QEMU/KVM and cloud adapters.

## Current limitations

The daemon currently provides observational host discovery and compatibility planning only. It does not install or launch user-supplied files. The runtime policy crate is a contract and policy planner; it does not yet include a production cryptographic approval service or enforce a real OS sandbox. Do not treat its unit tests as proof that application execution is secure.

There is no stable release or security support SLA yet. The project will publish supported versions and response targets before stable release.
