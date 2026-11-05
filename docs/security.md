# NOVA security model

## Current implementation boundary

The first daemon is a local development API that binds to loopback by default. It accepts a path/URL string and returns a compatibility plan. It does not read the path, execute code, install packages, mount images, create VMs or elevate privileges.

Do not expose this API to a LAN or the public internet. The current CORS rules are for the local Vite development server only; CORS is not authentication.

## Threats

- Malicious or malformed package files and filenames.
- Runtime/container/VM escape.
- Confused-deputy attacks against privileged host services.
- Untrusted URLs, redirects, browser content and supply-chain packages.
- Credential, clipboard, screen, microphone, camera or file exfiltration.
- Compromised updates or dependencies.
- Denial of service through oversized requests or runaway workloads.

## Mandatory controls for future runtime work

- Run applications as unprivileged users; never execute installers as root.
- Isolate Wine prefixes, Android containers and guest VMs; deny host filesystem access by default.
- Apply seccomp and AppArmor/SELinux profiles where supported; minimize Linux capabilities.
- Require explicit per-app permissions for files, networking, USB, camera, microphone and clipboard.
- Use signed repositories and artifacts, verify hashes/signatures, pin dependencies and publish an SBOM.
- Use atomic OS updates with rollback and a separately protected recovery path.
- Keep the host API on a Unix domain socket or authenticated loopback channel in production.
- Validate request sizes, paths, URLs and all data returned by runtimes.
- Add audit logs for privilege-sensitive operations without logging secrets or private file contents.
- Maintain a vulnerability response and upstream CVE monitoring process.

## Release gates

Do not ship a runtime as enabled until its sandbox boundary, permission prompts, failure handling, update path and app-specific test suite have passed review. Critical security defects block release regardless of feature completeness.
