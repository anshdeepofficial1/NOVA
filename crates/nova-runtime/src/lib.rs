//! Fail-closed policy contracts for NOVA runtime adapters.
//!
//! This crate builds an authorization and sandbox plan. It does not launch
//! processes, invoke package managers, create VMs, or install applications.
//! A production application must provide a signature-verifying
//! ApprovalVerifier before any future adapter is allowed to act.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use thiserror::Error;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeId {
    NativeLinux,
    Flatpak,
    AndroidWaydroid,
    WindowsWine,
    WindowsVm,
    BrowserPwa,
    MacOs,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeState {
    Ready,
    Detected,
    MissingPrerequisite,
    NotInstalled,
    NotConfigured,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum Permission {
    ReadUserFiles,
    WriteAppData,
    Network,
    UsbDevices,
    Camera,
    Microphone,
    Clipboard,
    ScreenCapture,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ResourceLimits {
    /// Memory limit in MiB.
    pub memory_mib: u32,
    /// CPU quota expressed as a percentage of one logical CPU.
    pub cpu_percent: u16,
    /// Writable application data limit in MiB.
    pub writable_storage_mib: u32,
    pub max_processes: u16,
    /// Hard execution timeout in seconds.
    pub timeout_seconds: u32,
}

impl ResourceLimits {
    pub fn validate(&self) -> Result<(), PolicyError> {
        if !(64..=262_144).contains(&self.memory_mib)
            || !(1..=1_600).contains(&self.cpu_percent)
            || !(16..=1_048_576).contains(&self.writable_storage_mib)
            || !(1..=4_096).contains(&self.max_processes)
            || !(1..=86_400).contains(&self.timeout_seconds)
        {
            return Err(PolicyError::InvalidResourceLimits);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct LaunchRequest {
    /// Stable, reverse-DNS-like NOVA application identifier.
    pub app_id: String,
    /// SHA-256 of the immutable artifact that is being approved.
    pub artifact_sha256: String,
    pub runtime: RuntimeId,
    pub requested_permissions: Vec<Permission>,
    pub limits: ResourceLimits,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ApprovalGrant {
    pub grant_id: String,
    pub app_id: String,
    pub artifact_sha256: String,
    pub approved_permissions: Vec<Permission>,
    pub expires_at_unix: u64,
    /// Signature over all fields except this signature. The desktop must not
    /// create trusted grants itself; a protected approval service does that.
    pub signature: Vec<u8>,
}

/// Verifies an approval signature with a protected key.
///
/// A production implementation must verify a cryptographic signature over a
/// canonical encoding of every grant field. There is deliberately no
/// permissive/default implementation in this crate.
pub trait ApprovalVerifier {
    fn verify(&self, grant: &ApprovalGrant) -> bool;
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct RuntimeDescriptor {
    pub id: RuntimeId,
    pub state: RuntimeState,
    pub supported_permissions: Vec<Permission>,
    pub note: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct SandboxProfile {
    pub no_new_privileges: bool,
    pub host_root_read_only: bool,
    pub host_home_access: bool,
    pub network_access: bool,
    pub usb_access: bool,
    pub camera_access: bool,
    pub microphone_access: bool,
    pub clipboard_access: bool,
    pub screen_capture_access: bool,
    pub filesystem_read_only_by_default: bool,
    pub app_data_isolated: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct RuntimeLaunchPlan {
    pub app_id: String,
    pub artifact_sha256: String,
    pub runtime: RuntimeId,
    pub approved_permissions: Vec<Permission>,
    pub limits: ResourceLimits,
    pub sandbox: SandboxProfile,
    pub approval_grant_id: String,
}

/// Errors are intentionally specific so callers can present safe remediation.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum PolicyError {
    #[error("Application identifier is invalid.")]
    InvalidAppId,
    #[error("Artifact SHA-256 must be exactly 64 hexadecimal characters.")]
    InvalidArtifactDigest,
    #[error("Resource limits are outside NOVA policy bounds.")]
    InvalidResourceLimits,
    #[error("Requested runtime is not ready on this host.")]
    RuntimeNotReady,
    #[error("Approval grant has expired.")]
    ApprovalExpired,
    #[error("Approval grant is for a different app or artifact.")]
    ApprovalSubjectMismatch,
    #[error("Approval grant does not include every requested permission.")]
    PermissionNotApproved,
    #[error("Runtime does not support one or more requested permissions.")]
    PermissionNotSupported,
    #[error("Approval signature is invalid.")]
    InvalidApprovalSignature,
}

/// Validate all launch constraints and create a default-deny sandbox plan.
///
/// The signature verifier is injected so the desktop/API cannot silently
/// treat an arbitrary UI boolean or string as user consent.
pub fn authorize_launch<V: ApprovalVerifier>(
    request: &LaunchRequest,
    runtime: &RuntimeDescriptor,
    grant: &ApprovalGrant,
    verifier: &V,
    now_unix: u64,
) -> Result<RuntimeLaunchPlan, PolicyError> {
    if !valid_app_id(&request.app_id) {
        return Err(PolicyError::InvalidAppId);
    }
    if !valid_sha256(&request.artifact_sha256) {
        return Err(PolicyError::InvalidArtifactDigest);
    }
    request.limits.validate()?;

    if runtime.id != request.runtime || runtime.state != RuntimeState::Ready {
        return Err(PolicyError::RuntimeNotReady);
    }
    if grant.expires_at_unix <= now_unix {
        return Err(PolicyError::ApprovalExpired);
    }
    if grant.app_id != request.app_id
        || !grant.artifact_sha256.eq_ignore_ascii_case(&request.artifact_sha256)
    {
        return Err(PolicyError::ApprovalSubjectMismatch);
    }
    if !verifier.verify(grant) {
        return Err(PolicyError::InvalidApprovalSignature);
    }

    let requested = unique_permissions(&request.requested_permissions)?;
    let approved = unique_permissions(&grant.approved_permissions)?;
    let supported = unique_permissions(&runtime.supported_permissions)?;

    if !requested.is_subset(&approved) {
        return Err(PolicyError::PermissionNotApproved);
    }
    if !requested.is_subset(&supported) {
        return Err(PolicyError::PermissionNotSupported);
    }

    Ok(RuntimeLaunchPlan {
        app_id: request.app_id.clone(),
        artifact_sha256: request.artifact_sha256.to_ascii_lowercase(),
        runtime: request.runtime,
        approved_permissions: requested.iter().copied().collect(),
        limits: request.limits.clone(),
        sandbox: SandboxProfile {
            no_new_privileges: true,
            host_root_read_only: true,
            host_home_access: requested.contains(&Permission::ReadUserFiles),
            network_access: requested.contains(&Permission::Network),
            usb_access: requested.contains(&Permission::UsbDevices),
            camera_access: requested.contains(&Permission::Camera),
            microphone_access: requested.contains(&Permission::Microphone),
            clipboard_access: requested.contains(&Permission::Clipboard),
            screen_capture_access: requested.contains(&Permission::ScreenCapture),
            filesystem_read_only_by_default: true,
            app_data_isolated: true,
        },
        approval_grant_id: grant.grant_id.clone(),
    })
}

fn unique_permissions(
    permissions: &[Permission],
) -> Result<BTreeSet<Permission>, PolicyError> {
    let set: BTreeSet<_> = permissions.iter().copied().collect();
    if set.len() != permissions.len() {
        return Err(PolicyError::PermissionNotApproved);
    }
    Ok(set)
}

fn valid_app_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value.split('.').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        })
        && value.contains('.')
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct AcceptTestSignature;

    impl ApprovalVerifier for AcceptTestSignature {
        fn verify(&self, grant: &ApprovalGrant) -> bool {
            grant.signature == b"test-only-valid-signature"
        }
    }

    fn request() -> LaunchRequest {
        LaunchRequest {
            app_id: "com.example.editor".to_owned(),
            artifact_sha256: "a".repeat(64),
            runtime: RuntimeId::Flatpak,
            requested_permissions: vec![Permission::Network, Permission::WriteAppData],
            limits: ResourceLimits {
                memory_mib: 2_048,
                cpu_percent: 200,
                writable_storage_mib: 4_096,
                max_processes: 128,
                timeout_seconds: 3_600,
            },
        }
    }

    fn runtime() -> RuntimeDescriptor {
        RuntimeDescriptor {
            id: RuntimeId::Flatpak,
            state: RuntimeState::Ready,
            supported_permissions: vec![
                Permission::Network,
                Permission::WriteAppData,
                Permission::ReadUserFiles,
            ],
            note: "Test descriptor only".to_owned(),
        }
    }

    fn grant() -> ApprovalGrant {
        ApprovalGrant {
            grant_id: "approval-001".to_owned(),
            app_id: "com.example.editor".to_owned(),
            artifact_sha256: "a".repeat(64),
            approved_permissions: vec![Permission::Network, Permission::WriteAppData],
            expires_at_unix: 2_000,
            signature: b"test-only-valid-signature".to_vec(),
        }
    }

    #[test]
    fn creates_a_default_deny_plan_after_verified_consent() {
        let plan = authorize_launch(&request(), &runtime(), &grant(), &AcceptTestSignature, 1_000)
            .expect("policy should approve this bounded request");

        assert!(plan.sandbox.no_new_privileges);
        assert!(plan.sandbox.host_root_read_only);
        assert!(!plan.sandbox.host_home_access);
        assert!(plan.sandbox.network_access);
        assert!(plan.sandbox.app_data_isolated);
        assert_eq!(plan.approval_grant_id, "approval-001");
    }

    #[test]
    fn refuses_runtime_that_is_not_ready() {
        let mut descriptor = runtime();
        descriptor.state = RuntimeState::Detected;
        assert_eq!(
            authorize_launch(&request(), &descriptor, &grant(), &AcceptTestSignature, 1_000),
            Err(PolicyError::RuntimeNotReady)
        );
    }

    #[test]
    fn refuses_expired_or_mismatched_approval() {
        let mut expired = grant();
        expired.expires_at_unix = 1_000;
        assert_eq!(
            authorize_launch(&request(), &runtime(), &expired, &AcceptTestSignature, 1_000),
            Err(PolicyError::ApprovalExpired)
        );

        let mut mismatched = grant();
        mismatched.artifact_sha256 = "b".repeat(64);
        assert_eq!(
            authorize_launch(&request(), &runtime(), &mismatched, &AcceptTestSignature, 999),
            Err(PolicyError::ApprovalSubjectMismatch)
        );
    }

    #[test]
    fn refuses_missing_or_unsupported_permission() {
        let mut insufficient = grant();
        insufficient.approved_permissions = vec![Permission::WriteAppData];
        assert_eq!(
            authorize_launch(&request(), &runtime(), &insufficient, &AcceptTestSignature, 1_000),
            Err(PolicyError::PermissionNotApproved)
        );

        let mut descriptor = runtime();
        descriptor.supported_permissions = vec![Permission::WriteAppData];
        assert_eq!(
            authorize_launch(&request(), &descriptor, &grant(), &AcceptTestSignature, 1_000),
            Err(PolicyError::PermissionNotSupported)
        );
    }

    #[test]
    fn rejects_bad_signature_identifier_digest_and_limits() {
        let mut bad_signature = grant();
        bad_signature.signature.clear();
        assert_eq!(
            authorize_launch(&request(), &runtime(), &bad_signature, &AcceptTestSignature, 1_000),
            Err(PolicyError::InvalidApprovalSignature)
        );

        let mut bad_id = request();
        bad_id.app_id = "not-valid".to_owned();
        assert_eq!(
            authorize_launch(&bad_id, &runtime(), &grant(), &AcceptTestSignature, 1_000),
            Err(PolicyError::InvalidAppId)
        );

        let mut bad_digest = request();
        bad_digest.artifact_sha256 = "not-a-digest".to_owned();
        assert_eq!(
            authorize_launch(&bad_digest, &runtime(), &grant(), &AcceptTestSignature, 1_000),
            Err(PolicyError::InvalidArtifactDigest)
        );

        let mut bad_limits = request();
        bad_limits.memory_mib = 0;
        assert_eq!(
            authorize_launch(&bad_limits, &runtime(), &grant(), &AcceptTestSignature, 1_000),
            Err(PolicyError::InvalidResourceLimits)
        );
    }

    #[test]
    fn rejects_duplicate_permission_entries() {
        let mut duplicate = request();
        duplicate.requested_permissions.push(Permission::Network);
        assert_eq!(
            authorize_launch(&duplicate, &runtime(), &grant(), &AcceptTestSignature, 1_000),
            Err(PolicyError::PermissionNotApproved)
        );
    }
}
