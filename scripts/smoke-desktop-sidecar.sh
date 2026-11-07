#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE="${1:-}"
if [[ -z "$PACKAGE" || ! -s "$PACKAGE" ]]; then
  echo "Usage: $0 /path/to/nova-desktop.deb" >&2
  exit 2
fi

for tool in sudo apt-get curl dbus-run-session xvfb-run timeout; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing desktop smoke-test dependency: $tool" >&2
    exit 1
  }
done

sudo apt-get install -y --no-install-recommends "$PACKAGE"

# Run the actual installed Tauri package in a disposable graphical session.
# A missing/early-exiting application, unavailable sidecar, wrong API response,
# or orphaned daemon after application exit makes this test fail.
timeout --signal=TERM --kill-after=5s 45s \
  dbus-run-session -- xvfb-run -a bash -euo pipefail -c '
    LOG_PATH="${RUNNER_TEMP:-/tmp}/nova-desktop-smoke.log"
    HEALTH_PATH="${RUNNER_TEMP:-/tmp}/nova-desktop-health.json"

    if curl -fsS http://127.0.0.1:47820/health >/dev/null 2>&1; then
      echo "Port 47820 is already occupied; desktop smoke test must run in isolation." >&2
      exit 1
    fi

    : > "$LOG_PATH"
    /usr/bin/nova-shell >"$LOG_PATH" 2>&1 &
    app_pid=$!

    cleanup() {
      if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT

    for attempt in $(seq 1 40); do
      if curl -fsS http://127.0.0.1:47820/health -o "$HEALTH_PATH"; then
        grep -q "\"service\":\"nova-daemon\"" "$HEALTH_PATH" || {
          cat "$HEALTH_PATH" >&2
          echo "Unexpected health response from NOVA sidecar." >&2
          exit 1
        }

        kill -TERM "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
        app_pid=""

        for shutdown_attempt in $(seq 1 15); do
          if ! curl -fsS http://127.0.0.1:47820/health >/dev/null 2>&1; then
            echo "Packaged desktop launched and cleaned up its NOVA daemon sidecar."
            exit 0
          fi
          sleep 0.2
        done

        echo "NOVA daemon remained running after the desktop application exited." >&2
        cat "$LOG_PATH" >&2
        exit 1
      fi

      if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "NOVA Desktop exited before its bundled daemon became healthy." >&2
        cat "$LOG_PATH" >&2
        exit 1
      fi
      sleep 0.5
    done

    echo "NOVA Desktop did not start a healthy bundled daemon within 20 seconds." >&2
    cat "$LOG_PATH" >&2
    exit 1
  '
