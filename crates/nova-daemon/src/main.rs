use axum::{
    extract::{DefaultBodyLimit, Json},
    http::{header, HeaderValue, Method, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use nova_core::{inspect_input, CompatibilityPlan, PlanError};
mod capabilities;
use serde::{Deserialize, Serialize};
use std::{env, net::SocketAddr};
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing_subscriber::EnvFilter;

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
    service: &'static str,
    version: &'static str,
}

#[derive(Serialize)]
struct SystemResponse {
    product: &'static str,
    version: &'static str,
    host_os: &'static str,
    architecture: &'static str,
    api_version: &'static str,
    kernel_release: String,
    distribution: String,
    session_type: String,
    runtimes: Vec<capabilities::RuntimeStatus>,
}

#[derive(Deserialize)]
struct InspectRequest {
    path: String,
}

#[derive(Serialize)]
struct InspectResponse {
    plan: CompatibilityPlan,
    execution_started: bool,
}

#[derive(Serialize)]
struct ErrorResponse {
    error: String,
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        service: "nova-daemon",
        version: env!("CARGO_PKG_VERSION"),
    })
}

async fn system_info() -> Json<SystemResponse> {
    let host_os = if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "unknown"
    };

    let architecture = if cfg!(target_arch = "x86_64") {
        "x86_64"
    } else if cfg!(target_arch = "aarch64") {
        "aarch64"
    } else {
        "other"
    };

    let report = capabilities::inspect_host();
    Json(SystemResponse {
        product: "NOVA OS",
        version: env!("CARGO_PKG_VERSION"),
        host_os,
        architecture,
        api_version: "v1",
        kernel_release: report.kernel_release,
        distribution: report.distribution,
        session_type: report.session_type,
        runtimes: report.runtimes,
    })
}

async fn inspect(Json(request): Json<InspectRequest>) -> impl IntoResponse {
    match inspect_input(&request.path) {
        Ok(plan) => (
            StatusCode::OK,
            Json(InspectResponse {
                plan,
                execution_started: false,
            }),
        )
            .into_response(),
        Err(error) => {
            let status = match error {
                PlanError::InputTooLong => StatusCode::PAYLOAD_TOO_LARGE,
                PlanError::UnsupportedFileType | PlanError::UnsupportedUrlScheme => {
                    StatusCode::UNSUPPORTED_MEDIA_TYPE
                }
                PlanError::EmptyInput => StatusCode::BAD_REQUEST,
            };
            (
                status,
                Json(ErrorResponse {
                    error: error.to_string(),
                }),
            )
                .into_response()
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    // Bind to loopback only. Do not expose a privileged host API to the LAN.
    let address: SocketAddr = env::var("NOVA_BIND")
        .unwrap_or_else(|_| "127.0.0.1:47820".to_owned())
        .parse()?;

    let allowed_origins = [
        HeaderValue::from_static("http://localhost:5173"),
        HeaderValue::from_static("http://127.0.0.1:5173"),
        HeaderValue::from_static("tauri://localhost"),
        HeaderValue::from_static("http://tauri.localhost"),
    ];

    let cors = CorsLayer::new()
        .allow_origin(allowed_origins)
        .allow_methods([Method::GET, Method::POST])
        .allow_headers([header::CONTENT_TYPE]);

    let app = Router::new()
        .route("/health", get(health))
        .route("/api/system", get(system_info))
        .route("/api/compatibility/inspect", post(inspect))
        .layer(DefaultBodyLimit::max(8 * 1024))
        .layer(cors)
        .layer(TraceLayer::new_for_http());

    if !address.ip().is_loopback() {
        return Err("NOVA_BIND must be loopback".into());
    }
    // Opt-in migration path: clients discover a private, authenticated endpoint.
    // Keep legacy mode until the packaged shell and guest probes migrate together.
    #[cfg(target_os = "linux")]
    if env::var_os("NOVA_PRIVATE_ENDPOINT").is_some() {
        return serve_private(app).await;
    }

    let listener = tokio::net::TcpListener::bind(address).await?;
    tracing::info!(%address, "NOVA host API listening");
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(target_os = "linux")]
async fn serve_private(app: Router) -> Result<(), Box<dyn std::error::Error>> {
    use axum::{
        extract::Request,
        middleware::{self, Next},
    };
    use std::{
        fs::{self, OpenOptions},
        io::{Read, Write},
        os::unix::fs::{MetadataExt, OpenOptionsExt},
        path::PathBuf,
    };

    let runtime = PathBuf::from(env::var_os("XDG_RUNTIME_DIR").ok_or("missing XDG_RUNTIME_DIR")?);
    let metadata = fs::symlink_metadata(&runtime)?;
    let uid = fs::metadata("/proc/self")?.uid();
    if !runtime.is_absolute()
        || !metadata.is_dir()
        || metadata.uid() != uid
        || metadata.mode() & 0o777 != 0o700
    {
        return Err("unsafe XDG_RUNTIME_DIR".into());
    }

    let mut random = [0u8; 32];
    fs::File::open("/dev/urandom")?.read_exact(&mut random)?;
    let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?;
    let expected = format!("Bearer {token}");
    let app = app.layer(middleware::from_fn(move |request: Request, next: Next| {
        let expected = expected.clone();
        async move {
            let valid = request
                .headers()
                .get(header::AUTHORIZATION)
                .is_some_and(|value| token_matches(value.as_bytes(), expected.as_bytes()));
            if !valid {
                return StatusCode::UNAUTHORIZED.into_response();
            }
            next.run(request).await
        }
    }));

    // Publish atomically; never follow an existing endpoint symlink or expose
    // the bearer token in logs, process arguments, or a world-readable file.
    let temporary = runtime.join(format!(".nova-endpoint-{token}"));
    let endpoint = runtime.join("nova-endpoint.json");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let publish = (|| -> Result<(), Box<dyn std::error::Error>> {
        serde_json::to_writer(
            &mut file,
            &serde_json::json!({
                "address": address.to_string(),
                "token": token
            }),
        )?;
        file.flush()?;
        fs::rename(&temporary, &endpoint)?;
        Ok(())
    })();
    if publish.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    publish?;
    tracing::info!(%address, "NOVA authenticated user API listening");
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn token_matches(actual: &[u8], expected: &[u8]) -> bool {
    actual.len() == expected.len()
        && actual
            .iter()
            .zip(expected)
            .fold(0u8, |diff, (a, b)| diff | (a ^ b))
            == 0
}

#[cfg(all(test, target_os = "linux"))]
mod transport_tests {
    use super::token_matches;

    #[test]
    fn bearer_comparison_rejects_missing_wrong_and_truncated_tokens() {
        assert!(token_matches(b"Bearer abc", b"Bearer abc"));
        assert!(!token_matches(b"", b"Bearer abc"));
        assert!(!token_matches(b"Bearer abd", b"Bearer abc"));
        assert!(!token_matches(b"Bearer ab", b"Bearer abc"));
    }
}
