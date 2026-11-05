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

    let listener = tokio::net::TcpListener::bind(address).await?;
    tracing::info!(%address, "NOVA host API listening");
    axum::serve(listener, app).await?;
    Ok(())
}
