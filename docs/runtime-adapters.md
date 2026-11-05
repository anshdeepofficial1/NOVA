# NOVA runtime adapter contract

## Purpose

Every app execution path must pass through a runtime adapter and one policy gate. A UI click, extension match or downloaded file must never become an arbitrary shell command.

The `nova-runtime` crate currently contains policy types and validation only. No production runtime adapter is registered, no process is started, and no user application is launched by this repository.

## Request flow

1. The package intake layer identifies the actual file format, immutable digest, publisher and target architecture. Filename extensions are not proof.
2. The runtime detector reports a host capability state such as ready, detected, missing prerequisite, not installed or unavailable.
3. The app requests a runtime and a narrowly scoped permission set.
4. A trusted consent service produces a signed, short-lived `ApprovalGrant` bound to the app ID, artifact SHA-256 and exact permission list.
5. `authorize_launch` validates the request, resource limits, runtime readiness, grant subject, expiration, cryptographic signature, and requested-versus-approved-versus-supported permissions.
6. The policy engine produces a default-deny `RuntimeLaunchPlan` with a sandbox profile and hard limits.
7. A separately reviewed adapter may eventually translate that typed plan into a container, Wine prefix, VM or browser session. That adapter is not part of the current implementation.

## Security requirements

- The approval signature must be verified with a protected key. Do not use a permissive verifier or trust a boolean sent by the UI.
- Canonicalize and sign every approval field except the signature itself.
- Bind grants to the exact app ID and immutable artifact digest. Replacing the artifact requires new consent.
- Enforce expiration and a trusted clock.
- Permissions are deny-by-default and scoped per app/artifact. A grant for one app cannot authorize another.
- Runtime support is independent of consent: a permission cannot be granted if the selected runtime does not implement it.
- Default sandbox posture is no new privileges, read-only host root, isolated writable app data and no home-directory access unless specifically approved.
- Resource bounds cover memory, CPU, writable storage, process count and execution duration.
- Adapters must handle start, health, stop, cleanup, crash and timeout paths without leaving processes or mounts behind.
- Privileged host operations must use a separate authenticated IPC service with narrow methods. Never accept arbitrary executable paths or shell strings from the webview.

## Production work still required

- A production cryptographic grant signer/verifier and secure key storage.
- Authenticated desktop-to-host IPC, request replay protection and audit records.
- File-format parsers and signature verification for each supported package format.
- App catalog and compatibility evidence database.
- Flatpak/portal adapter, then Waydroid, Wine/Proton and QEMU/KVM adapters.
- Disposable integration-test VMs and hardware-in-the-loop test coverage.
- Policy review and sandbox escape testing before enabling a runtime.

## Test policy

Unit tests cover grants, expiration, mismatches, invalid signatures, duplicate permissions, runtime readiness, unsupported permissions, invalid identifiers/digests and out-of-policy limits. Integration tests must run only inside disposable VMs or containers. A successful unit test does not prove the real sandbox is effective.
