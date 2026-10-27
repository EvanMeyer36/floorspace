import { useEffect, useState, type ReactNode } from "react";
import { api, type Snapshot } from "../api";
import { bytes, count, tilde } from "../format";
import { Icon } from "./Icon";

export interface Segment { label: string; value: number; color: string }

/** One stacked bar over the whole disk, with a legend underneath. */
export function StorageBar({ segments, total }: { segments: Segment[]; total: number }) {
  const shown = segments.filter((s) => s.value > 0);
  return (
    <div>
      <div className="bar" role="img" aria-label={shown.map((s) => `${s.label} ${bytes(s.value)}`).join(", ")}>
        {shown.map((s) => (
          <div key={s.label} title={`${s.label}: ${bytes(s.value)}`} style={{ flexGrow: s.value / Math.max(1, total), background: s.color }} />
        ))}
      </div>
      <div className="legend">
        {shown.map((s) => (
          <span key={s.label}>
            <span className="swatch" style={{ background: s.color }} />
            <span className="muted">{s.label}</span>
            <span className="value">{bytes(s.value)}</span>
          </span>
        ))}
      </div>
    </div>
  );
}

/** Live progress of a running scan, polled a few times a second. */
export function useProgress(kind: "tree" | "junk" | "apps", running: boolean): Snapshot | null {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  useEffect(() => {
    if (!running) {
      setSnapshot(null);
      return;
    }
    const timer = setInterval(() => api.progress(kind).then(setSnapshot).catch(() => {}), 250);
    return () => clearInterval(timer);
  }, [kind, running]);
  return snapshot;
}

export function ProgressPanel({ snapshot, onStop, label }: { snapshot: Snapshot | null; onStop?: () => void; label?: string }) {
  return (
    <div className="progress">
      <div className="spinner" />
      <strong>{snapshot?.phase || label || "Starting…"}</strong>
      <span className="num">{count(snapshot?.itemsSeen ?? 0)} items checked</span>
      <span className="path">{tilde(snapshot?.currentPath) || " "}</span>
      {onStop && <button className="btn" onClick={onStop}>Stop</button>}
    </div>
  );
}

export interface ConfirmRequest {
  title: string;
  message: string;
  confirm: string;
  danger?: boolean;
  /** Just a message: one OK button, no Cancel. */
  informational?: boolean;
  onConfirm: () => void;
}

export function ConfirmDialog({ request, onClose }: { request: ConfirmRequest | null; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  if (!request) return null;
  return (
    <div className="backdrop" onClick={onClose}>
      <div className="dialog" role="alertdialog" aria-labelledby="dialog-title" onClick={(e) => e.stopPropagation()}>
        <h3 id="dialog-title">{request.title}</h3>
        <p>{request.message}</p>
        <div className="actions">
          {!request.informational && <button className="btn" onClick={onClose} autoFocus>Cancel</button>}
          <button className="btn primary" autoFocus={request.informational} style={request.danger ? { background: "var(--danger)", borderColor: "var(--danger)" } : undefined}
            onClick={() => { onClose(); request.onConfirm(); }}>
            {request.confirm}
          </button>
        </div>
      </div>
    </div>
  );
}

export function Badge({ children }: { children: ReactNode }) {
  return <span className="badge">{children}</span>;
}

export function WarningBox({ message, action }: { message: string; action?: ReactNode }) {
  return (
    <div className="warning">
      <Icon name="lock" />
      <span style={{ flex: 1 }}>{message}</span>
      {action}
    </div>
  );
}

export function Empty({ title, message, action }: { title: string; message: string; action?: ReactNode }) {
  return (
    <div className="empty">
      <h3>{title}</h3>
      <span>{message}</span>
      {action}
    </div>
  );
}
