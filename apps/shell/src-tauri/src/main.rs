#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    sync::Mutex,
    time::{Duration, Instant},
};

use tauri::Manager;
use tauri_plugin_shell::{
    process::{CommandChild, CommandEvent},
    ShellExt,
};

struct ManagedSidecar(Mutex<Option<CommandChild>>);

#[cfg(target_os = "linux")]
fn private_endpoint() -> Result<Option<(SocketAddr, String)>, String> {
    use std::{fs, os::unix::fs::MetadataExt, path::PathBuf};
    let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") else {
        return Ok(None);
    };
    let runtime = PathBuf::from(runtime);
    let uid = fs::metadata("/proc/self").map_err(|e| e.to_string())?.uid();
    let meta = fs::symlink_metadata(&runtime).map_err(|e| e.to_string())?;
    if !runtime.is_absolute() || !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o777 != 0o700 {
        return Err("Unsafe NOVA runtime directory".into());
    }
    let path = runtime.join("nova-endpoint.json");
    let meta = match fs::symlink_metadata(&path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    if !meta.is_file() || meta.uid() != uid || meta.mode() & 0o777 != 0o600 || meta.len() > 4096 {
        return Err("Unsafe NOVA endpoint file".into());
    }
    let data: serde_json::Value = serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let address: SocketAddr = data["address"].as_str().ok_or("Missing address")?
        .parse().map_err(|_| "Invalid address")?;
    let token = data["token"].as_str().ok_or("Missing token")?;
    if address.ip() != std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)
        || address.port() == 0 || token.len() != 64 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("Invalid NOVA private endpoint".into());
    }
    Ok(Some((address, token.to_owned())))
}

fn daemon_endpoint() -> Result<(SocketAddr, Option<String>), String> {
    #[cfg(target_os = "linux")]
    {
        if let Some((address, token)) = private_endpoint()? {
            return Ok((address, Some(token)));
        }
        if std::env::var_os("NOVA_PRIVATE_ENDPOINT").is_some() {
            return Err("Private NOVA daemon is not ready".into());
        }
    }
    Ok((SocketAddr::from(([127, 0, 0, 1], 47820)), None))
}

// Only the three existing API operations are exposed to the webview.
// Endpoint discovery and bearer credentials stay in native code.
#[tauri::command]
async fn daemon_request(path: String, body: Option<String>) -> Result<serde_json::Value, String> {
    let (address, token) = daemon_endpoint()?;
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(5))
        .build().map_err(|e| e.to_string())?;
    let url = format!("http://{address}{path}");
    let request = match (path.as_str(), body) {
        ("/health" | "/api/system", None) => client.get(url),
        ("/api/compatibility/inspect", Some(body)) if body.len() <= 8192 =>
            client.post(url).header("Content-Type", "application/json").body(body),
        _ => return Err("Unsupported NOVA API operation".into()),
    };
    let request = if let Some(token) = token { request.bearer_auth(token) } else { request };
    let response = request.send().await.map_err(|_| "NOVA host service unavailable")?;
    let status = response.status();
    let bytes = response.bytes().await.map_err(|_| "Invalid NOVA response")?;
    let payload: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| "Invalid NOVA response")?;
    if !status.is_success() {
        return Err(payload["error"].as_str().unwrap_or("NOVA request failed").to_owned());
    }
    Ok(payload)
}


/// Check whether NOVA's user-session service is already running.
///
/// The ISO enables the daemon as a user service. The packaged desktop can
/// also be installed on an ordinary Linux desktop, where it starts its own
/// bundled sidecar only when no healthy NOVA daemon is listening.
fn nova_daemon_is_healthy() -> bool {
    let Ok((address, token)) = daemon_endpoint() else { return false; };
    let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(250)) else {
        return false;
    };

    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));

    let authorization = token.map(|token| format!("Authorization: Bearer {token}\r\n")).unwrap_or_default();
    let request = format!("GET /health HTTP/1.1\r\nHost: {address}\r\n{authorization}Connection: close\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
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
        .invoke_handler(tauri::generate_handler![daemon_request])
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
                            // Keep ownership so the Exit event can explicitly
                            // kill and reap the full process group.
                            app.manage(ManagedSidecar(Mutex::new(Some(child))));

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

    app.run(|app_handle, event| {
        if let tauri::RunEvent::Exit = event {
            // App state can outlive this callback. Take ownership and
            // synchronously stop/reap the process group before returning.
            let child =
                app_handle
                    .try_state::<ManagedSidecar>()
                    .and_then(|state| match state.0.lock() {
                        Ok(mut child) => child.take(),
                        Err(error) => {
                            eprintln!("Could not lock NOVA sidecar state during shutdown: {error}");
                            None
                        }
                    });

            if let Some(child) = child {
                if let Err(error) = child.kill() {
                    eprintln!("Could not stop NOVA host service during desktop shutdown: {error}");
                }
            }
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
