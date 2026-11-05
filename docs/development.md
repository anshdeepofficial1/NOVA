# Development guide

## Prerequisites

Install Rust stable (rustup), Node.js 20+, npm and Git. Linux is the intended host for future OS integrations.

## Run locally

Terminal 1 — host API:

~~~bash
cargo run -p nova-daemon
~~~

Terminal 2 — shell:

~~~bash
npm install
npm run dev
~~~

Open the local URL printed by Vite (default: http://127.0.0.1:5173).

## Validate changes

~~~bash
cargo fmt --all -- --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
npm run typecheck
npm run build
~~~

## Runtime development policy

Runtime adapters must be separate modules with a narrow interface: detect prerequisites, validate source, prepare an isolated environment, request permissions, launch, report health, stop and clean up. The compatibility planner must never call a runtime directly.

Add unit tests for pure decisions, integration tests in disposable VMs/containers, fuzz tests for parsers and API inputs, and hardware-in-the-loop coverage for graphics, GPU, audio and device passthrough. Never use a developer laptop as a test target for destructive installer or partitioning experiments.
