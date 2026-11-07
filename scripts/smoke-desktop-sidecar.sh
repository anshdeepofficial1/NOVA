#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE="${1:-}"
if [[ -z "$PACKAGE" || ! -s "$PACKAGE" ]]; then
  echo "Usage: $0 /path/to/nova-desktop.deb" >&2
  exit 2
fi

for tool in sudo apt-get curl dbus-run-session xvfb-run openbox wmctrl timeout; do
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

# Run the real installed app under Xvfb + Openbox. wmctrl sends an EWMH close
# request so GTK/Tauri can handle WM_DELETE_WINDOW and run its Exit cleanup.
timeout --signal=TERM --kill-after=5s 60s \
  dbus-run-session -- xvfb-run -a bash -euo pipefail -c '
    LOG_PATH="${RUNNER_TEMP:-/tmp}/nova-desktop-smoke.log"
    WM_LOG_PATH="${RUNNER_TEMP:-/tmp}/nova-openbox-smoke.log"
    HEALTH_PATH="${RUNNER_TEMP:-/tmp}/nova-desktop-health.json"

    if curl -fsS http://127.0.0.1:47820/health >/dev/null 2>&1; then
      echo "Port 47820 is already occupied; desktop smoke test must run in isolation." >&2
      exit 1
    fi

    openbox --sm-disable >"$WM_LOG_PATH" 2>&1 &
    wm_pid=$!
    app_pid=""

    cleanup() {
      if [[ -n "${app_pid:-}" ]]; then
        kill -KILL "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
      fi
      if [[ -n "${wm_pid:-}" ]]; then
        kill -TERM "$wm_pid" 2>/dev/null || true
        wait "$wm_pid" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT

    wm_ready=false
    for attempt in $(seq 1 30); do
      if wmctrl -m >/dev/null 2>&1; then
        wm_ready=true
        break
      fi
      if ! kill -0 "$wm_pid" 2>/dev/null; then
        echo "Openbox exited before the test desktop was ready." >&2
        cat "$WM_LOG_PATH" >&2
        exit 1
      fi
      sleep 0.2
    done
    if [[ "$wm_ready" != true ]]; then
      echo "Openbox did not become ready in the Xvfb session." >&2
      cat "$WM_LOG_PATH" >&2
      exit 1
    fi

    : > "$LOG_PATH"
    /usr/bin/nova-shell >"$LOG_PATH" 2>&1 &
    app_pid=$!

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

    if ! wmctrl -l | grep -Fq "NOVA Desktop"; then
      echo "NOVA Desktop daemon started but its application window was not registered with Openbox." >&2
      cat "$LOG_PATH" >&2
      cat "$WM_LOG_PATH" >&2
      exit 1
    fi

    wmctrl -c "NOVA Desktop"

    stopped=false
    for shutdown_attempt in $(seq 1 30); do
      if ! curl -fsS http://127.0.0.1:47820/health >/dev/null 2>&1; then
        stopped=true
        break
      fi
      sleep 0.2
    done

    if [[ "$stopped" != true ]]; then
      echo "NOVA daemon remained healthy after the normal desktop close request." >&2
      cat "$LOG_PATH" >&2
      cat "$WM_LOG_PATH" >&2
      exit 1
    fi

    # The app process itself must finish after the sidecar is stopped.
    wait "$app_pid"
    app_pid=""
    echo "Packaged desktop opened, reported a healthy daemon, and exited with its sidecar stopped."
  '
