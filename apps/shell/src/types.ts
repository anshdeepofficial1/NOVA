export type SupportLevel = "planned" | "experimental" | "unavailable";

export interface RuntimeStatus {
  id: string;
  state: string;
  note: string;
}

export interface SystemInfo {
  product: string;
  version: string;
  host_os: string;
  architecture: string;
  api_version: string;
  runtimes: RuntimeStatus[];
}

export interface CompatibilityPlan {
  input_name: string;
  package_kind: string;
  runtime: string;
  support: SupportLevel;
  summary: string;
  next_step: string;
  requires_explicit_consent: boolean;
}

export interface InspectResponse {
  plan: CompatibilityPlan;
  execution_started: boolean;
}
