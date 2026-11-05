import type { InspectResponse, SystemInfo } from "./types";

const API_BASE = import.meta.env.VITE_NOVA_API_URL ?? "http://127.0.0.1:47820";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(API_BASE + path, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...init?.headers
    }
  });

  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const message =
      typeof payload === "object" &&
      payload !== null &&
      "error" in payload &&
      typeof payload.error === "string"
        ? payload.error
        : "Request failed (" + response.status + ")";
    throw new Error(message);
  }

  return payload as T;
}

export function getSystemInfo(): Promise<SystemInfo> {
  return request<SystemInfo>("/api/system");
}

export function inspectPackage(path: string): Promise<InspectResponse> {
  return request<InspectResponse>("/api/compatibility/inspect", {
    method: "POST",
    body: JSON.stringify({ path })
  });
}

export async function checkHealth(): Promise<boolean> {
  try {
    const response = await fetch(API_BASE + "/health");
    return response.ok;
  } catch {
    return false;
  }
}
