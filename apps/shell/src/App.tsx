import { useCallback, useEffect, useState, type FormEvent } from "react";
import { checkHealth, getSystemInfo, inspectPackage } from "./api";
import type { CompatibilityPlan, SystemInfo } from "./types";

const quickItems = [
  { icon: "▦", name: "Apps", detail: "Application workspace" },
  { icon: "⌕", name: "Search", detail: "Find apps and files" },
  { icon: "▤", name: "Files", detail: "File manager · planned" },
  { icon: "⚙", name: "Settings", detail: "System settings · planned" }
];

function supportLabel(level: CompatibilityPlan["support"]) {
  switch (level) {
    case "experimental": return "Experimental";
    case "unavailable": return "Unavailable";
    default: return "Planned";
  }
}

export default function App() {
  const [connected, setConnected] = useState(false);
  const [system, setSystem] = useState<SystemInfo | null>(null);
  const [input, setInput] = useState("example.apk");
  const [plan, setPlan] = useState<CompatibilityPlan | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const refresh = useCallback(async () => {
    const online = await checkHealth();
    setConnected(online);
    if (online) {
      try {
        setSystem(await getSystemInfo());
      } catch {
        setSystem(null);
      }
    } else {
      setSystem(null);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 10000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  async function onInspect(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setPlan(null);
    try {
      const result = await inspectPackage(input);
      setPlan(result.plan);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not inspect this item.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="desktop">
      <div className="wallpaper-glow wallpaper-glow-a" />
      <div className="wallpaper-glow wallpaper-glow-b" />
      <header className="topbar">
        <div className="brand"><span className="brand-mark">N</span><span>NOVA</span></div>
        <div className="topbar-center">Workspace <span className="topbar-divider">/</span> Overview</div>
        <div className="topbar-right">
          <span className={"connection-dot " + (connected ? "online" : "")} />
          <span>{connected ? "Host connected" : "Preview mode"}</span>
          <span className="topbar-time">NOVA 0.1</span>
        </div>
      </header>

      <section className="welcome">
        <p className="eyebrow">YOUR SPACE. ONE SYSTEM.</p>
        <h1>Good morning<span className="accent">.</span></h1>
        <p className="welcome-copy">A unified workspace for apps, tools and ideas. The foundation is taking shape.</p>
      </section>

      <section className="workspace-grid">
        <div className="main-column">
          <article className="hero-card panel">
            <div className="hero-copy">
              <span className="status-pill"><span /> FOUNDATION BUILD</span>
              <h2>One workspace.<br /><em>Many ecosystems.</em></h2>
              <p>NOVA is building a bridge between native desktop apps, Android, Windows compatibility and the web—with clear boundaries for what works today.</p>
              <div className="hero-actions">
                <button className="primary-button" onClick={() => document.getElementById("compat-input")?.focus()}>Inspect an app <span>↗</span></button>
                <span className="subtle-note">Early development · Not an installable OS yet</span>
              </div>
            </div>
            <div className="orbit-art" aria-hidden="true">
              <div className="orbit orbit-one" /><div className="orbit orbit-two" /><div className="orbit orbit-three" />
              <div className="orbit-core">N</div>
              <span className="orbit-node node-linux">L</span><span className="orbit-node node-android">A</span><span className="orbit-node node-web">W</span>
            </div>
          </article>

          <section className="section-block">
            <div className="section-heading"><div><p className="eyebrow">GET STARTED</p><h3>Your workspace</h3></div><span className="section-hint">Some modules are placeholders</span></div>
            <div className="quick-grid">
              {quickItems.map((item) => (
                <button className="quick-card panel" key={item.name} onClick={() => setError(item.name + " is part of the planned desktop shell.")}>
                  <span className="quick-icon">{item.icon}</span><span className="quick-name">{item.name}</span><span className="quick-detail">{item.detail}</span><span className="quick-arrow">↗</span>
                </button>
              ))}
            </div>
          </section>

          <section className="section-block inspector-section" id="compatibility">
            <div className="section-heading"><div><p className="eyebrow">UNIVERSAL COMPATIBILITY</p><h3>App route inspector</h3></div><span className="section-hint">Planning only · no files are executed</span></div>
            <div className="panel inspector-card">
              <p className="inspector-copy">Enter a filename or web URL to see which runtime NOVA would use and the current implementation status.</p>
              <form className="inspect-form" onSubmit={onInspect}>
                <span className="input-symbol">⌘</span>
                <input id="compat-input" value={input} onChange={(event) => setInput(event.target.value)} placeholder="app.apk, setup.exe, tool.deb or https://…" aria-label="File path or web URL" />
                <button type="submit" disabled={busy || !input.trim()}>{busy ? "Checking…" : "Inspect route"}</button>
              </form>
              {error && <div className="error-message" role="alert">{error}</div>}
              {plan && (
                <div className="plan-result" aria-live="polite">
                  <div className="plan-top"><div><span className="plan-label">DETECTED FORMAT</span><strong>{plan.input_name}</strong></div><span className={"support-badge " + plan.support}>{supportLabel(plan.support)}</span></div>
                  <p>{plan.summary}</p>
                  <div className="plan-meta"><span>Runtime <b>{plan.runtime.replaceAll("_", " ")}</b></span><span>Type <b>{plan.package_kind.replaceAll("_", " ")}</b></span></div>
                  <div className="next-step"><b>Next step</b><span>{plan.next_step}</span></div>
                  {plan.requires_explicit_consent && <div className="consent-note">Permission required before any future install or launch action.</div>}
                </div>
              )}
            </div>
          </section>
        </div>

        <aside className="side-column">
          <article className="panel side-card system-card">
            <div className="side-title"><span className="side-icon">◈</span><h3>System status</h3><span className={"live-indicator " + (connected ? "active" : "")} /></div>
            <div className="system-status"><span className={"large-status-dot " + (connected ? "active" : "")} /><div><b>{connected ? "Local service online" : "Local service offline"}</b><small>{connected ? "NOVA API responding" : "Start nova-daemon to connect"}</small></div></div>
            <div className="data-row"><span>Host</span><b>{system ? system.host_os : "Not detected"}</b></div>
            <div className="data-row"><span>Architecture</span><b>{system ? system.architecture : "—"}</b></div>
            <div className="data-row"><span>Distribution</span><b>{system ? system.distribution : "—"}</b></div>
            <div className="data-row"><span>Kernel</span><b>{system ? system.kernel_release : "—"}</b></div>
            <div className="data-row"><span>Session</span><b>{system ? system.session_type : "—"}</b></div>
            <button className="text-button" onClick={() => void refresh()}>Refresh status ↻</button>
          </article>

          <article className="panel side-card runtime-card">
            <div className="side-title"><span className="side-icon">⌘</span><h3>Runtime matrix</h3></div>
            {system?.runtimes.map((runtime) => (
              <div className="runtime-row" key={runtime.id}>
                <div><b>{runtime.id.replaceAll("-", " ")}</b><small>{runtime.note}</small></div>
                <span className={"runtime-state " + (["detected", "initialized", "kvm_available"].includes(runtime.state) ? "ready" : runtime.state.includes("unavailable") ? "muted" : "")}>{runtime.state.replaceAll("_", " ")}</span>
              </div>
            )) ?? <p className="empty-state">Connect the local service to inspect runtime readiness.</p>}
          </article>

          <article className="panel note-card">
            <span className="note-symbol">✦</span>
            <p className="eyebrow">NOVA PRINCIPLE</p>
            <h3>Honest compatibility.</h3>
            <p>We only mark an app as supported after repeatable tests on real hardware. A file extension alone never guarantees that an app will run.</p>
          </article>
        </aside>
      </section>

      <footer className="footer"><span>© 2026 NOVA Project</span><span>Built on open standards · Designed for trust</span><span>Experimental preview</span></footer>
    </main>
  );
}
