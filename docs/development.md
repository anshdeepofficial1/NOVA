# Development guide

## Prerequisites

- Rust 1.90+ toolchain and Cargo (the native Tauri shell uses the current Tauri shell plugin).
- Node.js 20+ and npm.
- Git.
- For native Tauri builds on Debian/Ubuntu: libwebkit2gtk-4.1-dev, build-essential, curl, wget, file, libxdo-dev, libssl-dev, libayatana-appindicator3-dev and librsvg2-dev.
- For ISO builds: live-build, debootstrap, squashfs-tools, xorriso, GRUB BIOS/EFI tools, mtools, dosfstools, isolinux and syslinux-common.

See the official [Tauri Linux prerequisites](https://v2.tauri.app/start/prerequisites/) before building the native window.

## Run locally

Terminal 1 — start the host API:

~~~bash
cargo run -p nova-daemon
~~~

Terminal 2 — run the browser shell:

~~~bash
npm ci
npm run dev
~~~

For the native Tauri desktop window, leave the daemon running and use:

~~~bash
npm run desktop:dev
~~~

Build the .deb package:

~~~bash
npm run desktop:build
~~~

## Validate source and package

~~~bash
cargo fmt --all -- --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
npm run typecheck
npm run build
npm run desktop:build
~~~

CI runs Rust format/test/Clippy and builds the frontend and native Linux Debian package, including icon generation and the daemon sidecar. It also launches the packaged desktop in an isolated Xvfb/DBus session and verifies the daemon sidecar lifecycle.

## Build the bootable image

Follow [os/debian-live/README.md](../os/debian-live/README.md). The ISO pipeline is manual because it is large and slower than normal application CI.

For local builds, compile the daemon and Tauri .deb, stage them into the live-build tree, then run sudo bash os/debian-live/build.sh. Never test disk installation on a machine with important data; use a disposable VM first.

## Runtime development policy

Runtime adapters must be separate components with a narrow interface: detect prerequisites, validate actual source, prepare an isolated environment, request permissions, launch, report health, stop and clean up. The compatibility planner must never call a runtime directly.

Add unit tests for pure decisions, integration tests in disposable VMs/containers, fuzz tests for parsers and API inputs, and hardware-in-the-loop coverage for GPU, audio, input, Wi-Fi, Bluetooth, suspend/resume and device passthrough.
