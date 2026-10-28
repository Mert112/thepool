import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Link, NavLink } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { supabase } from "../lib/supabase";
import { initials } from "../lib/format";
import { getFlag } from "../features/ads/api";
import { setDisplayName, setLanguage } from "../features/profile/api";
import { LANGS, dictFor, translateError, useI18n, type Lang } from "../lib/i18n";
import { AdModal } from "../features/ads/AdModal";


// The ten icons, mirroring pool.icons so an avatar renders without waiting for a fetch. The
// database is still the authority on who has earned what — this is only how they look.
export const ICON_GLYPH: Record<string, string> = {
  rookie: "⚽", regular: "📋", crew: "🧣", watcher: "📺", caller: "🎯",
  sniper: "🎱", banker: "💰", jackpot: "🎰", whale: "🐋", console: "🎮",
};
export const ICON_RARITY: Record<string, string> = {
  rookie: "common", regular: "common", crew: "common", watcher: "uncommon", caller: "uncommon",
  sniper: "rare", banker: "rare", jackpot: "epic", whale: "epic", console: "legendary",
};

// an uploaded picture (0031) wins over the icon, which wins over initials
export const avatarUrl = (path: string) => supabase.storage.from("avatars").getPublicUrl(path).data.publicUrl;
export function Avatar({ name, icon, pic, me, sm }: { name: string | null | undefined; icon?: string | null; pic?: string | null; me?: boolean; sm?: boolean }) {
  const { t } = useI18n();
  if (pic) return <img className={"av pic" + (sm ? " sm" : "")} src={avatarUrl(pic)} alt="" title={name ?? undefined} />;
  const glyph = icon ? ICON_GLYPH[icon] : undefined;
  const cls = "av" + (me ? " me" : "") + (sm ? " sm" : "") + (glyph ? ` ico r-${ICON_RARITY[icon!] ?? "common"}` : "");
  return <span className={cls} title={glyph ? undefined : (name ?? undefined)}>{glyph ?? (me ? t.common.you.slice(0, 2).toUpperCase() : initials(name))}</span>;
}

export function Pips({ n }: { n: number }) {
  return <span className="pips">{Array.from({ length: 8 }, (_, i) => <i key={i} className={i < n ? "on" : ""} />)}</span>;
}

export function Bar({ pct, width }: { pct: number; width?: number }) {
  return <span className="bar" style={{ width: `${Math.max(2, Math.min(100, pct))}%`, maxWidth: width ? `${width}px` : undefined }} />;
}

export function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const { t } = useI18n();
  useEffect(() => { const k = (e: KeyboardEvent) => e.key === "Escape" && onClose(); window.addEventListener("keydown", k); return () => window.removeEventListener("keydown", k); }, [onClose]);
  // rendered on <body>: an animated (transformed) ancestor would otherwise become the box that
  // position:fixed is measured against, and a dialog opened on a long page would land off-screen
  return createPortal(
    <div className="modal-bg" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
          <h3 className="display" style={{ margin: 0 }}>{title}</h3>
          <button className="btn ghost" onClick={onClose}>{t.common.close}</button>
        </div>
        {children}
      </div>
    </div>,
    document.body,
  );
}

export function Empty({ children }: { children: ReactNode }) { return <div className="empty">{children}</div>; }
export function Spinner() { const { t } = useI18n(); return <div className="spinner">{t.common.loading}</div>; }

// §i18n the database refuses in English; the player reads it in their own language
export function ErrorBox({ msg }: { msg: string | null }) {
  const { t } = useI18n();
  const said = translateError(msg, t);
  return said ? <div className="error">{said}</div> : null;
}

export function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return <button type="button" className={"switch" + (on ? " on" : "")} onClick={() => onChange(!on)} aria-pressed={on}><i /></button>;
}

// §i18n the switcher. The choice is kept on the profile when there is one to keep it on, so the
// mails follow the app; signed out, this browser remembers it.
export function LangPicker({ full }: { full?: boolean }) {
  const { lang, setLang, t } = useI18n();
  const { session, refreshProfile } = useAuth();
  const choose = async (l: Lang) => {
    setLang(l);
    if (!session) return;
    try { await setLanguage(l); await refreshProfile(); } catch { /* the app is already in it; the next visit retries */ }
  };
  if (full) {
    return (
      <div className="row-of">
        {LANGS.map((l) => (
          <button key={l} className={"chip" + (lang === l ? " on" : "")} onClick={() => choose(l)} lang={l}>{dictFor(l).name}</button>
        ))}
      </div>
    );
  }
  return (
    <select className="lang-select" aria-label={t.common.language} value={lang} onChange={(e) => choose(e.target.value as Lang)}>
      {LANGS.map((l) => <option key={l} value={l}>{dictFor(l).short}</option>)}
    </select>
  );
}

export function Shell({ children }: { children: ReactNode }) {
  const { profile, refreshProfile } = useAuth();
  const { t, fmt } = useI18n();
  const [ads, setAds] = useState(false);
  const [adsOn, setAdsOn] = useState(false);
  useEffect(() => { getFlag("rewarded_ads").then(setAdsOn).catch(() => {}); }, []);
  const items: Array<[string, string]> = [["/", t.nav.board], ["/crews", t.nav.crews], ["/album", t.nav.album], ["/table", t.nav.table], ["/you", t.nav.you]];
  return (
    <div className="wrap">
      <div className="topbar">
        <Link to="/" className="brand">The <span>Pool</span></Link>
        <nav className="nav">
          {items.map(([to, label]) => <NavLink key={to} to={to} end={to === "/"} className={({ isActive }) => (isActive ? "on" : "")}>{label}</NavLink>)}
        </nav>
        <div className="me">
          {profile && <Link to="/you" title={t.shell.yourPoints}><span className="pts">{fmt.pts(profile.balance)}</span> <span className="tiny">{t.common.pts}</span></Link>}
          {adsOn && <button className="btn ghost tiny-btn" onClick={() => setAds(true)}>{t.shell.getPoints}</button>}
          {profile && profile.streak > 0 && <span className="tag hit">{t.shell.streak(profile.streak)}</span>}
          <LangPicker />
          <Link to="/you" title={t.nav.you}><Avatar name={profile?.display_name} icon={profile?.icon} pic={profile?.avatar_path} me={!profile?.icon} /></Link>
          <button className="btn ghost tiny-btn" onClick={() => supabase.auth.signOut()}>{t.shell.signOut}</button>
        </div>
      </div>
      {ads && <AdModal onClose={() => { setAds(false); refreshProfile(); }} onCredited={() => refreshProfile()} />}
      <div className="eyebrow" style={{ marginBottom: 10 }}>{fmt.dateline()}</div>
      <NamePrompt />
      {children}
    </div>
  );
}

// §5.1: first sign-in asks for a display name
function NamePrompt() {
  const { profile, refreshProfile } = useAuth();
  const { t } = useI18n();
  const [name, setName] = useState("");
  const [err, setErr] = useState<string | null>(null);
  if (!profile || profile.display_name) return null;
  const save = async () => { try { await setDisplayName(name); await refreshProfile(); } catch (e: any) { setErr(e.message); } };
  return (
    <Modal title={t.namePrompt.title} onClose={() => {}}>
      <p className="muted">{t.namePrompt.blurb}</p>
      <label className="field"><span>{t.namePrompt.label}</span><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder={t.namePrompt.placeholder} autoFocus /></label>
      <ErrorBox msg={err} />
      <button className="btn big" disabled={name.trim().length < 2} onClick={save}>{t.namePrompt.go}</button>
    </Modal>
  );
}
