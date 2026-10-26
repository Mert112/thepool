import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Link, NavLink } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { supabase } from "../lib/supabase";
import { initials, dateline } from "../lib/format";
import { pts as fmtPts } from "../lib/calls";
import { getFlag, setDisplayName, watchAd } from "../lib/api";

export const AD_SECONDS = 30;

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
  // rendered on <body>: an animated (transformed) ancestor would otherwise become the box that
  // position:fixed is measured against, and a dialog opened on a long page would land off-screen
  return createPortal(
    <div className="modal-bg" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
          <h3 className="display" style={{ margin: 0 }}>{title}</h3>
          <button className="btn ghost" onClick={onClose}>Close</button>
        </div>
        {children}
      </div>
    </div>,
    document.body,
  );
}

export function Empty({ children }: { children: ReactNode }) { return <div className="empty">{children}</div>; }
export function Spinner() { return <div className="spinner">Loading…</div>; }
export function ErrorBox({ msg }: { msg: string | null }) { return msg ? <div className="error">{msg}</div> : null; }

export function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return <button type="button" className={"switch" + (on ? " on" : "")} onClick={() => onChange(!on)} aria-pressed={on}><i /></button>;
}

export function Shell({ children }: { children: ReactNode }) {
  const { profile, refreshProfile } = useAuth();
  const [ads, setAds] = useState(false);
  const [adsOn, setAdsOn] = useState(false);
  useEffect(() => { getFlag("rewarded_ads").then(setAdsOn).catch(() => {}); }, []);
  const items: Array<[string, string]> = [["/", "Board"], ["/crews", "Crews"], ["/album", "Album"], ["/table", "Table"], ["/you", "You"]];
  return (
    <div className="wrap">
      <div className="topbar">
        <Link to="/" className="brand">The <span>Pool</span></Link>
        <nav className="nav">
          {items.map(([to, label]) => <NavLink key={to} to={to} end={to === "/"} className={({ isActive }) => (isActive ? "on" : "")}>{label}</NavLink>)}
        </nav>
        <div className="me">
          {profile && <Link to="/you" title="Your points"><span className="pts">{fmtPts(profile.balance)}</span> <span className="tiny">pts</span></Link>}
          {adsOn && <button className="btn ghost tiny-btn" onClick={() => setAds(true)}>Get points</button>}
          {profile && profile.streak > 0 && <span className="tag hit">{profile.streak}-day streak</span>}
          <Link to="/settings" title="Settings"><Avatar name={profile?.display_name} me /></Link>
          <button className="btn ghost tiny-btn" onClick={() => supabase.auth.signOut()}>Sign out</button>
        </div>
      </div>
      {ads && <AdModal onClose={() => { setAds(false); refreshProfile(); }} onCredited={() => refreshProfile()} />}
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

// §4 "Get points": a rewarded-video placeholder. The countdown has to run out before the reward
// can be collected, and the reward itself — 100 points, ten a day — is granted and capped by the
// database, not here. Swap the panel below for a real provider's player; nothing else moves.
export function AdModal({ onClose, onCredited }: { onClose: () => void; onCredited: (balance: number) => void }) {
  const [left, setLeft] = useState(AD_SECONDS);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<{ credited: number; left_today: number } | null>(null);

  useEffect(() => {
    if (done) return;
    const t = setInterval(() => setLeft((n) => (n > 0 ? n - 1 : 0)), 1000);
    return () => clearInterval(t);
  }, [done]);

  const collect = async () => {
    setBusy(true); setErr(null);
    try {
      const r = await watchAd();
      setDone({ credited: r.credited, left_today: r.left_today });
      onCredited(r.balance);
    } catch (e: any) { setErr(e.message ?? String(e)); }
    setBusy(false);
  };

  return (
    <Modal title="Get points" onClose={onClose}>
      {done ? (
        <div>
          <div className="banner ok" role="status"><b>+{fmtPts(done.credited)} points.</b> {done.left_today > 0 ? `${done.left_today} more ${done.left_today === 1 ? "ad" : "ads"} today.` : "That is all ten for today."}</div>
          <div className="row-of">
            <button className="btn big" onClick={onClose}>Done</button>
            {done.left_today > 0 && <button className="btn" onClick={() => { setDone(null); setLeft(AD_SECONDS); }}>Watch another</button>}
          </div>
        </div>
      ) : (
        <div>
          <div className="ad-stub">
            <div className="eyebrow">Advertisement · placeholder</div>
            <div className="num lime ad-count">{left}</div>
            <div className="small muted">{left > 0 ? "Watch to the end to collect half a point." : "Finished. Collect your points."}</div>
            <div className="ad-progress"><i style={{ width: `${((AD_SECONDS - left) / AD_SECONDS) * 100}%` }} /></div>
          </div>
          <p className="tiny muted">A real rewarded-video player goes here. Until then this is a 30-second stand-in: the reward, and the ten-a-day limit, are counted in the database either way. Ads are a trickle by design — the points worth having come out of the pots.</p>
          <ErrorBox msg={err} />
          <button className="btn big" disabled={left > 0 || busy} onClick={collect}>
            {busy ? "Collecting…" : left > 0 ? `Collect 0.5 points in ${left}s` : "Collect 0.5 points"}
          </button>
        </div>
      )}
    </Modal>
  );
}
