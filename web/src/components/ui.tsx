import { useEffect, useState, type ReactNode } from "react";
import { Link, NavLink } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { supabase } from "../lib/supabase";
import { initials, dateline } from "../lib/format";
import { myStats, setDisplayName } from "../lib/api";

export function Avatar({ name, me, sm }: { name: string | null | undefined; me?: boolean; sm?: boolean }) {
  return <span className={"av" + (me ? " me" : "") + (sm ? " sm" : "")}>{me ? "YO" : initials(name)}</span>;
}

export function Pips({ n }: { n: number }) {
  return <span className="pips">{Array.from({ length: 8 }, (_, i) => <i key={i} className={i < n ? "on" : ""} />)}</span>;
}

export function Bar({ pct, width }: { pct: number; width?: number }) {
  return <span className="bar" style={{ width: `${Math.max(2, Math.min(100, pct))}%`, maxWidth: width ? `${width}px` : undefined }} />;
}

export function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  useEffect(() => { const k = (e: KeyboardEvent) => e.key === "Escape" && onClose(); window.addEventListener("keydown", k); return () => window.removeEventListener("keydown", k); }, [onClose]);
  return (
    <div className="modal-bg" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
          <h3 className="display" style={{ margin: 0 }}>{title}</h3>
          <button className="btn ghost" onClick={onClose}>Close</button>
        </div>
        {children}
      </div>
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) { return <div className="empty">{children}</div>; }
export function Spinner() { return <div className="spinner">Loading…</div>; }
export function ErrorBox({ msg }: { msg: string | null }) { return msg ? <div className="error">{msg}</div> : null; }

export function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return <button type="button" className={"switch" + (on ? " on" : "")} onClick={() => onChange(!on)} aria-pressed={on}><i /></button>;
}

export function Shell({ children }: { children: ReactNode }) {
  const { profile } = useAuth();
  const [pts, setPts] = useState<{ points: number; streak: number } | null>(null);
  useEffect(() => { myStats().then((s) => setPts({ points: s.points, streak: s.streak })).catch(() => {}); }, []);
  const items: Array<[string, string]> = [["/", "Board"], ["/crews", "Crews"], ["/album", "Album"], ["/table", "Table"], ["/you", "You"]];
  return (
    <div className="wrap">
      <div className="topbar">
        <Link to="/" className="brand">The <span>Pool</span></Link>
        <nav className="nav">
          {items.map(([to, label]) => <NavLink key={to} to={to} end={to === "/"} className={({ isActive }) => (isActive ? "on" : "")}>{label}</NavLink>)}
        </nav>
        <div className="me">
          {pts && <span><span className="pts">{pts.points}</span> <span className="tiny">pts</span></span>}
          {pts && pts.streak > 0 && <span className="tag hit">{pts.streak}-day streak</span>}
          <Link to="/settings" title="Settings"><Avatar name={profile?.display_name} me /></Link>
          <button className="btn ghost tiny" onClick={() => supabase.auth.signOut()}>Sign out</button>
        </div>
      </div>
      <div className="eyebrow" style={{ marginBottom: 10 }}>{dateline()}</div>
      <NamePrompt />
      {children}
    </div>
  );
}

// §5.1: first sign-in asks for a display name
function NamePrompt() {
  const { profile, refreshProfile } = useAuth();
  const [name, setName] = useState("");
  const [err, setErr] = useState<string | null>(null);
  if (!profile || profile.display_name) return null;
  const save = async () => { try { await setDisplayName(name); await refreshProfile(); } catch (e: any) { setErr(e.message); } };
  return (
    <Modal title="What do we call you?" onClose={() => {}}>
      <p className="muted">This is the name your crew sees on the table and in the room. You can change it later in settings.</p>
      <label className="field"><span>Display name</span><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Mina H." autoFocus /></label>
      <ErrorBox msg={err} />
      <button className="btn big" disabled={name.trim().length < 2} onClick={save}>Let me in</button>
    </Modal>
  );
}
