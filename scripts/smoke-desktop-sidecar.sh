#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE="${1:-}"
if [[ -z "$PACKAGE" || ! -s "$PACKAGE" ]]; then
  echo "Usage: $0 /path/to/nova-desktop.deb" >&2
  exit 2
fi

for tool in sudo apt-get curl dbus-run-session xvfb-run xdotool timeout; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing desktop smoke-test dependency: $tool" >&2
    exit 1
  }
done

case "$PACKAGE" in
  /*|./*) PACKAGE_PATH="$PACKAGE" ;;
  *) PACKAGE_PATH="./$PACKAGE" ;;
esac

# The Tauri package filename contains a space. Use a temporary path without
# spaces so APT interprets it as one local package argument.
SMOKE_PACKAGE="$(mktemp /tmp/nova-desktop-smoke-XXXXXX.deb)"
cp "$PACKAGE_PATH" "$SMOKE_PACKAGE"
sudo apt-get install -y --no-install-recommends "$SMOKE_PACKAGE"
rm -f "$SMOKE_PACKAGE"

# Launch the installed application in an isolated graphical session. Closing
# the window normally exercises Tauri's RunEvent::Exit shutdown hook.
timeout --signal=TERM --kill-after=5s 60s \
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
        kill -KILL "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT

    healthy=false
    for attempt in $(seq 1 40); do
      if curl -fsS http://127.0.0.1:47820/health -o "$HEALTH_PATH" 2>/dev/null; then
        healthy=true
        break
      fi

      if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "NOVA Desktop exited before its bundled daemon became healthy." >&2
        cat "$LOG_PATH" >&2
        exit 1
      fi
      sleep 0.5
    done

    if [[ "$healthy" != true ]]; then
      echo "NOVA Desktop did not start a healthy bundled daemon within 20 seconds." >&2
      cat "$LOG_PATH" >&2
      exit 1
    fi

    grep -q "\"service\":\"nova-daemon\"" "$HEALTH_PATH" || {
      cat "$HEALTH_PATH" >&2
      echo "Unexpected health response from NOVA sidecar." >&2
      exit 1
    }

    window_id="$(xdotool search --onlyvisible --name "NOVA Desktop" 2>/dev/null | head -n 1 || true)"
    if [[ -z "$window_id" ]]; then
      echo "NOVA Desktop daemon started but its visible application window was not found." >&2
      cat "$LOG_PATH" >&2
      exit 1
    fi

    xdotool windowclose "$window_id"

    stopped=false
    for shutdown_attempt in $(seq 1 30); do
      if ! curl -fsS http://127.0.0.1:47820/health >/dev/null 2>&1; then
        stopped=true
        break
      fi
      sleep 0.2
    done

    if [[ "$stopped" != true ]]; then
      echo "NOVA daemon remained healthy after the desktop window closed." >&2
      cat "$LOG_PATH" >&2
      exit 1
    fi

    # The process itself must finish after its sidecar is stopped.
    wait "$app_pid"
    app_pid=""
    echo "Packaged desktop opened, reported a healthy daemon, and closed with its sidecar stopped."
  '
