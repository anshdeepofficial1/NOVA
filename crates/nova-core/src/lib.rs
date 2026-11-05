//! Shared, side-effect-free domain logic for NOVA.
//!
//! This crate deliberately does not open files or execute installers. It only
//! classifies a user-provided path/URL and returns a transparent runtime plan.

use serde::{Deserialize, Serialize};
use std::path::Path;
use thiserror::Error;

pub const MAX_INSPECTION_INPUT_BYTES: usize = 4096;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PackageKind {
    AndroidApk,
    WindowsExecutable,
    WindowsInstaller,
    MacDiskImage,
    MacInstaller,
    DebianPackage,
    AppImage,
    FedoraPackage,
    FlatpakReference,
    WebApp,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeKind {
    AndroidContainer,
    WineOrProton,
    MacOsEnvironment,
    NativeLinuxPackage,
    Browser,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SupportLevel {
    Planned,
    Experimental,
    Unavailable,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CompatibilityPlan {
    pub input_name: String,
    pub package_kind: PackageKind,
    pub runtime: RuntimeKind,
    pub support: SupportLevel,
    pub summary: String,
    pub next_step: String,
    pub requires_explicit_consent: bool,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PlanError {
    #[error("A file path or web URL is required.")]
    EmptyInput,
    #[error("Input is too long (maximum {MAX_INSPECTION_INPUT_BYTES} bytes).")]
    InputTooLong,
    #[error("This file type is not recognized by NOVA yet.")]
    UnsupportedFileType,
    #[error("Only http and https web URLs are accepted.")]
    UnsupportedUrlScheme,
}

/// Inspect a package name/path without touching the filesystem.
///
/// The result is an execution plan, not a claim that the runtime exists.
/// Actual installers and runtime adapters must independently validate files,
/// permissions, signatures, architecture and sandbox policy before use.
pub fn inspect_input(input: &str) -> Result<CompatibilityPlan, PlanError> {
    let normalized = input.trim();
    if normalized.is_empty() {
        return Err(PlanError::EmptyInput);
    }
    if normalized.len() > MAX_INSPECTION_INPUT_BYTES {
        return Err(PlanError::InputTooLong);
    }

    if normalized.starts_with("https://") || normalized.starts_with("http://") {
        return Ok(CompatibilityPlan {
            input_name: normalized.to_owned(),
            package_kind: PackageKind::WebApp,
            runtime: RuntimeKind::Browser,
            support: SupportLevel::Planned,
            summary: "A web URL can be opened in NOVA's browser workspace.".into(),
            next_step: "Browser/PWA integration is planned; no remote code is executed by this API.".into(),
            requires_explicit_consent: false,
        });
    }

    if normalized.contains("://") {
        return Err(PlanError::UnsupportedUrlScheme);
    }

    let path = Path::new(normalized);
    let input_name = path.file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(normalized)
        .to_owned();
    let extension = path.extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let plan = match extension.as_str() {
        "apk" => CompatibilityPlan {
            input_name, package_kind: PackageKind::AndroidApk,
            runtime: RuntimeKind::AndroidContainer, support: SupportLevel::Experimental,
            summary: "Android packages are intended to use an isolated Android container.".into(),
            next_step: "Install and validate Waydroid on a supported Linux host before enabling APK installation.".into(),
            requires_explicit_consent: true,
        },
        "exe" => CompatibilityPlan {
            input_name, package_kind: PackageKind::WindowsExecutable,
            runtime: RuntimeKind::WineOrProton, support: SupportLevel::Experimental,
            summary: "Some Windows applications may work through Wine/Proton; compatibility is application-specific.".into(),
            next_step: "Check the exact app/version against NOVA's compatibility database and use an isolated prefix.".into(),
            requires_explicit_consent: true,
        },
        "msi" => CompatibilityPlan {
            input_name, package_kind: PackageKind::WindowsInstaller,
            runtime: RuntimeKind::WineOrProton, support: SupportLevel::Experimental,
            summary: "Windows installer support depends on the installer and its dependencies.".into(),
            next_step: "Validate with a disposable Wine prefix; a licensed Windows VM may be needed.".into(),
            requires_explicit_consent: true,
        },
        "dmg" => CompatibilityPlan {
            input_name, package_kind: PackageKind::MacDiskImage,
            runtime: RuntimeKind::MacOsEnvironment, support: SupportLevel::Unavailable,
            summary: "A DMG is a macOS disk image, not a cross-platform executable.".into(),
            next_step: "No macOS runtime is integrated. Any future macOS workflow must comply with Apple's license and hardware requirements.".into(),
            requires_explicit_consent: true,
        },
        "pkg" => CompatibilityPlan {
            input_name, package_kind: PackageKind::MacInstaller,
            runtime: RuntimeKind::MacOsEnvironment, support: SupportLevel::Unavailable,
            summary: "This installer targets Apple's macOS package system.".into(),
            next_step: "No macOS runtime is integrated; do not attempt to install this on the Linux host.".into(),
            requires_explicit_consent: true,
        },
        "deb" => CompatibilityPlan {
            input_name, package_kind: PackageKind::DebianPackage,
            runtime: RuntimeKind::NativeLinuxPackage, support: SupportLevel::Planned,
            summary: "Debian packages are a native Linux packaging target.".into(),
            next_step: "A signed package-install service with dependency checks and rollback is still required.".into(),
            requires_explicit_consent: true,
        },
        "appimage" => CompatibilityPlan {
            input_name, package_kind: PackageKind::AppImage,
            runtime: RuntimeKind::NativeLinuxPackage, support: SupportLevel::Planned,
            summary: "AppImage is a Linux application distribution format.".into(),
            next_step: "Validate signatures/trust, mount safely, and integrate desktop entries before launch support.".into(),
            requires_explicit_consent: true,
        },
        "rpm" => CompatibilityPlan {
            input_name, package_kind: PackageKind::FedoraPackage,
            runtime: RuntimeKind::NativeLinuxPackage, support: SupportLevel::Planned,
            summary: "RPM is a native Linux package format used by several distributions.".into(),
            next_step: "NOVA needs a distribution-aware package manager integration.".into(),
            requires_explicit_consent: true,
        },
        "flatpakref" => CompatibilityPlan {
            input_name, package_kind: PackageKind::FlatpakReference,
            runtime: RuntimeKind::NativeLinuxPackage, support: SupportLevel::Planned,
            summary: "Flatpak references can point to sandboxed Linux applications.".into(),
            next_step: "Integrate Flatpak remotes with signature verification and permission review.".into(),
            requires_explicit_consent: true,
        },
        _ => return Err(PlanError::UnsupportedFileType),
    };
    Ok(plan)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_supported_extensions_case_insensitively() {
        let cases = [
            ("anime.APK", PackageKind::AndroidApk),
            ("setup.EXE", PackageKind::WindowsExecutable),
            ("installer.msi", PackageKind::WindowsInstaller),
            ("disk.dmg", PackageKind::MacDiskImage),
            ("package.deb", PackageKind::DebianPackage),
            ("tool.AppImage", PackageKind::AppImage),
        ];
        for (input, expected_kind) in cases {
            let plan = inspect_input(input).expect("input should be recognized");
            assert_eq!(plan.package_kind, expected_kind);
        }
    }

    #[test]
    fn marks_mac_disk_images_unavailable() {
        let plan = inspect_input("Example.dmg").expect("DMG should be recognized");
        assert_eq!(plan.support, SupportLevel::Unavailable);
        assert_eq!(plan.runtime, RuntimeKind::MacOsEnvironment);
    }

    #[test]
    fn recognizes_only_http_and_https_urls() {
        assert_eq!(inspect_input("https://example.com").unwrap().package_kind, PackageKind::WebApp);
        assert_eq!(inspect_input("ftp://example.com"), Err(PlanError::UnsupportedUrlScheme));
    }

    #[test]
    fn rejects_empty_unknown_and_oversized_inputs() {
        assert_eq!(inspect_input("  "), Err(PlanError::EmptyInput));
        assert_eq!(inspect_input("random.bin"), Err(PlanError::UnsupportedFileType));
        let oversized = "x".repeat(MAX_INSPECTION_INPUT_BYTES + 1);
        assert_eq!(inspect_input(&oversized), Err(PlanError::InputTooLong));
    }
}
