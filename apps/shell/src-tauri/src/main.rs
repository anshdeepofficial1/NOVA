#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    time::{Duration, Instant},
};

use tauri::Manager;
use tauri_plugin_shell::{process::CommandEvent, ShellExt};

/// Check whether NOVA's user-session service is already running.
///
/// The ISO enables the daemon as a user service. The packaged desktop can
/// also be installed on an ordinary Linux desktop, where it starts its own
/// bundled sidecar only when no healthy NOVA daemon is listening.
fn nova_daemon_is_healthy() -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], 47820));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(250)) else {
        return false;
    };

    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));

    let request = b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    if stream.write_all(request).is_err() {
        return false;
    }

    let mut response = Vec::with_capacity(1024);
    // A timeout or close is acceptable once the response bytes are available.
    let _ = stream.read_to_end(&mut response);

    let response = String::from_utf8_lossy(&response);
    response.starts_with("HTTP/1.1 200") && response.contains("\"service\":\"nova-daemon\"")
}

/// Wait briefly for the per-user service to start before launching a
/// bundled sidecar. This avoids two daemons contending for the same port when
/// KDE starts the service and desktop application at the same time.
fn wait_for_existing_daemon_with<F>(
    mut is_healthy: F,
    timeout: Duration,
    retry_interval: Duration,
) -> bool
where
    F: FnMut() -> bool,
{
    let deadline = Instant::now() + timeout;

    loop {
        if is_healthy() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        if !retry_interval.is_zero() {
            std::thread::sleep(retry_interval);
        }
    }
}

fn wait_for_existing_daemon() -> bool {
    wait_for_existing_daemon_with(
        nova_daemon_is_healthy,
        Duration::from_secs(3),
        Duration::from_millis(150),
    )
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            if wait_for_existing_daemon() {
                eprintln!("NOVA host service is already running; reusing it.");
                return Ok(());
            }

            let sidecar = app
                .shell()
                // Tauri expects the external binary's basename, not
                // "binaries/nova-daemon".
                .sidecar("nova-daemon");

            match sidecar {
                Ok(command) => {
                    let command = command.kill_on_drop(true).set_process_group(true);

                    match command.spawn() {
                        Ok((mut events, child)) => {
                            // CommandChild is retained by the app. Because
                            // kill_on_drop is enabled, app shutdown terminates
                            // the process group instead of orphaning the daemon.
                            app.manage(child);

                            tauri::async_runtime::spawn(async move {
                                while let Some(event) = events.recv().await {
                                    match event {
                                        CommandEvent::Error(message) => {
                                            eprintln!("NOVA host service error: {message}");
                                        }
                                        CommandEvent::Terminated(_) => break,
                                        _ => {}
                                    }
                                }
                            });
                        }
                        Err(error) => {
                            // Keep the desktop UI available. The runtime panel
                            // will show the daemon as offline and can explain
                            // the missing sidecar.
                            eprintln!("Could not start bundled NOVA host service: {error}");
                        }
                    }
                }
                Err(error) => {
                    eprintln!("NOVA host service sidecar is unavailable: {error}");
                }
            }

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build NOVA Desktop");

    app.run(|_app_handle, event| {
        if let tauri::RunEvent::Exit = event {
            // The managed CommandChild is dropped with app state; kill_on_drop
            // and process-group cleanup prevent an orphaned local service.
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn daemon_wait_returns_immediately_when_service_is_healthy() {
        let mut checks = 0;
        let ready = wait_for_existing_daemon_with(
            || {
                checks += 1;
                true
            },
            Duration::from_secs(1),
            Duration::ZERO,
        );

        assert!(ready);
        assert_eq!(checks, 1);
    }

    #[test]
    fn daemon_wait_retries_until_service_becomes_healthy() {
        let mut checks = 0;
        let ready = wait_for_existing_daemon_with(
            || {
                checks += 1;
                checks >= 3
            },
            Duration::from_secs(1),
            Duration::ZERO,
        );

        assert!(ready);
        assert_eq!(checks, 3);
    }

    #[test]
    fn daemon_wait_returns_false_when_service_stays_offline() {
        let mut checks = 0;
        let ready = wait_for_existing_daemon_with(
            || {
                checks += 1;
                false
            },
            Duration::ZERO,
            Duration::ZERO,
        );

        assert!(!ready);
        assert_eq!(checks, 1);
    }
}
