//! Read-only host capability discovery.
//!
//! All discovery is observational: it checks PATH, kernel metadata, device
//! nodes and configuration files. It never starts, installs or modifies a
//! runtime, and it never interprets user-provided input as a command.

use serde::Serialize;
use std::{
    env, fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Serialize)]
pub struct RuntimeStatus {
    pub id: &'static str,
    pub state: &'static str,
    pub note: String,
    pub executable: Option<String>,
}

#[derive(Debug, Clone)]
pub struct HostReport {
    pub kernel_release: String,
    pub distribution: String,
    pub session_type: String,
    pub runtimes: Vec<RuntimeStatus>,
}

fn executable_on_path(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    for directory in env::split_paths(&path) {
        let candidate = directory.join(name);
        if candidate.is_file() && is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

fn kernel_release() -> String {
    fs::read_to_string("/proc/sys/kernel/osrelease")
        .map(|value| value.trim().to_owned())
        .unwrap_or_else(|_| "unknown".to_owned())
}

fn distribution_name() -> String {
    let Ok(contents) = fs::read_to_string("/etc/os-release") else {
        return "unknown".to_owned();
    };

    let values = parse_os_release(&contents);
    values
        .get("PRETTY_NAME")
        .cloned()
        .or_else(|| values.get("NAME").cloned())
        .unwrap_or_else(|| "unknown".to_owned())
}

fn parse_os_release(contents: &str) -> std::collections::BTreeMap<String, String> {
    contents
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            let value = value.trim().trim_matches('"').trim_matches('\'');
            if key.is_empty() {
                None
            } else {
                Some((key.to_owned(), value.to_owned()))
            }
        })
        .collect()
}

fn session_type() -> String {
    env::var("XDG_SESSION_TYPE")
        .unwrap_or_else(|_| {
            if env::var_os("WAYLAND_DISPLAY").is_some() {
                "wayland".to_owned()
            } else {
                "unknown".to_owned()
            }
        })
        .to_ascii_lowercase()
}

fn has_wayland_session() -> bool {
    session_type() == "wayland" && env::var_os("WAYLAND_DISPLAY").is_some()
}

fn kernel_has_binder(release: &str) -> bool {
    if Path::new("/dev/binder").exists()
        || Path::new("/dev/binderfs/binder-control").exists()
        || Path::new("/dev/binderfs/binder").exists()
    {
        return true;
    }

    let config_path = format!("/boot/config-{release}");
    fs::read_to_string(config_path)
        .map(|contents| {
            contents.lines().any(|line| {
                line == "CONFIG_ANDROID_BINDER_IPC=y" || line == "CONFIG_ANDROID_BINDER_IPC=m"
            })
        })
        .unwrap_or(false)
}

fn runtime(
    id: &'static str,
    state: &'static str,
    note: impl Into<String>,
    executable: Option<PathBuf>,
) -> RuntimeStatus {
    RuntimeStatus {
        id,
        state,
        note: note.into(),
        executable: executable.map(|path| path.display().to_string()),
    }
}

/// Detect installed tools and basic host prerequisites without executing them.
pub fn inspect_host() -> HostReport {
    let release = kernel_release();
    let distro = distribution_name();
    let session = session_type();

    let apt = executable_on_path("apt-get");
    let dnf = executable_on_path("dnf");
    let rpm_ostree = executable_on_path("rpm-ostree");
    let flatpak = executable_on_path("flatpak");
    let waydroid = executable_on_path("waydroid");
    let wine = executable_on_path("wine");
    let qemu = executable_on_path("qemu-system-x86_64");
    let virsh = executable_on_path("virsh");
    let browser = executable_on_path("firefox-esr")
        .or_else(|| executable_on_path("firefox"))
        .or_else(|| executable_on_path("chromium"));

    let package_manager = apt.or(dnf).or(rpm_ostree);
    let native_state = if package_manager.is_some() {
        "detected"
    } else {
        "missing"
    };

    let waydroid_state = match (
        &waydroid,
        has_wayland_session(),
        kernel_has_binder(&release),
    ) {
        (None, _, _) => "not_installed",
        (Some(_), false, _) => "wayland_session_required",
        (Some(_), true, false) => "binder_kernel_support_missing",
        (Some(_), true, true) => {
            if Path::new("/var/lib/waydroid/waydroid.cfg").exists() {
                "initialized"
            } else {
                "installed_needs_initialization"
            }
        }
    };

    let kvm_available = Path::new("/dev/kvm").exists();
    let vm_state = match (&qemu, kvm_available) {
        (None, _) => "qemu_not_installed",
        (Some(_), true) => "kvm_available",
        (Some(_), false) => "qemu_without_kvm",
    };

    let runtimes = vec![
        runtime(
            "linux-native",
            native_state,
            if package_manager.is_some() {
                "A supported package-manager command was found. NOVA does not install packages yet."
            } else {
                "No supported Linux package-manager command was found on PATH."
            },
            package_manager,
        ),
        runtime(
            "flatpak",
            if flatpak.is_some() { "detected" } else { "not_installed" },
            "Flatpak application management is not yet connected to the NOVA shell.",
            flatpak,
        ),
        runtime(
            "android-waydroid",
            waydroid_state,
            match waydroid_state {
                "not_installed" => "Waydroid was not found on PATH.",
                "wayland_session_required" => "Waydroid is installed, but this process does not detect an active Wayland session.",
                "binder_kernel_support_missing" => "Waydroid is installed, but Binder kernel support was not detected. Check the running kernel configuration and binderfs devices.",
                "initialized" => "Waydroid appears initialized and basic prerequisites were detected; app launch has not been tested by NOVA.",
                _ => "Waydroid is installed; its Android image still needs initialization.",
            },
            waydroid,
        ),
        runtime(
            "windows-wine",
            if wine.is_some() { "detected" } else { "not_installed" },
            "Wine was detected by executable lookup only. Per-application compatibility and safe-prefix management are not implemented.",
            wine,
        ),
        runtime(
            "windows-vm",
            vm_state,
            match vm_state {
                "kvm_available" => "QEMU and /dev/kvm were detected. VM creation, licensing checks and lifecycle management are not implemented.",
                "qemu_without_kvm" => "QEMU was detected but /dev/kvm is missing; hardware acceleration is unavailable to this process.",
                _ => "QEMU system emulation was not found on PATH.",
            },
            qemu.or(virsh),
        ),
        runtime(
            "web-browser",
            if browser.is_some() { "detected" } else { "not_installed" },
            "A browser executable was detected. Browser profile integration and PWA management are not implemented.",
            browser,
        ),
        runtime(
            "macos",
            "unavailable_linux_host",
            "A DMG is a macOS disk image. NOVA does not provide a macOS runtime; any future macOS workflow must comply with Apple's license and hardware requirements.",
            None,
        ),
        runtime(
            "nova-cloud",
            "not_configured",
            "Cloud workspaces require a separately deployed broker, identity service, isolated compute and remote-session gateway.",
            None,
        ),
    ];

    HostReport {
        kernel_release: release,
        distribution: distro,
        session_type: session,
        runtimes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_os_release_values() {
        let parsed = parse_os_release(
            "NAME=Debian\nPRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nID=debian\n",
        );
        assert_eq!(parsed.get("NAME").map(String::as_str), Some("Debian"));
        assert_eq!(
            parsed.get("PRETTY_NAME").map(String::as_str),
            Some("Debian GNU/Linux 13 (trixie)")
        );
        assert_eq!(parsed.get("ID").map(String::as_str), Some("debian"));
    }

    #[test]
    fn ignores_malformed_os_release_lines() {
        let parsed = parse_os_release("not-a-pair\n=empty-key\nNAME=Linux\n");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed.get("NAME").map(String::as_str), Some("Linux"));
    }

    #[test]
    fn runtime_status_never_claims_full_app_compatibility() {
        let status = runtime(
            "windows-wine",
            "detected",
            "Wine executable found; app compatibility is unknown.",
            None,
        );
        assert_eq!(status.state, "detected");
        assert!(status.note.contains("compatibility is unknown"));
        assert!(status.executable.is_none());
    }
}
