import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Link, NavLink } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { supabase } from "../lib/supabase";
import { initials } from "../lib/format";
import { adNonce, getConfig, getFlag, setDisplayName, setLanguage, watchAd } from "../lib/api";
import { consent } from "../lib/consent";
import { showRewarded } from "../lib/rewarded";
import { LANGS, dictFor, translateError, useI18n, type Lang } from "../i18n";

export const AD_SECONDS = 30;
export const AD_REWARD = 0.2;

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

export function Avatar({ name, icon, me, sm }: { name: string | null | undefined; icon?: string | null; me?: boolean; sm?: boolean }) {
  const { t } = useI18n();
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
          <Link to="/settings" title={t.shell.settings}><Avatar name={profile?.display_name} icon={profile?.icon} me={!profile?.icon} /></Link>
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

// §4 / §ads "Get points".
//
// Two paths, one flag. With `gam_rewarded` off this is the thirty-second countdown that has
// stood in since `0019`, kept for testing. With it on, the real thing: a nonce from the server
// first, then Google Ad Manager's rewarded slot, and the credit only once Google says the ad
// was watched to the end. No ad, no consent, no fill — nothing is credited, and the page says
// so rather than pretending.
export function AdModal({ onClose, onCredited, reward = AD_REWARD }: { onClose: () => void; onCredited: (balance: number) => void; reward?: number }) {
  const { t, fmt } = useI18n();
  const [left, setLeft] = useState(AD_SECONDS);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [done, setDone] = useState<{ credited: number; left_today: number } | null>(null);
  const [gam, setGam] = useState<{ on: boolean; path: string } | null>(null);

  useEffect(() => {
    Promise.all([getFlag("gam_rewarded"), getConfig<{ ad_unit_path?: string }>("ads")])
      .then(([on, cfg]) => setGam({ on, path: cfg?.ad_unit_path ?? "" }))
      .catch(() => setGam({ on: false, path: "" }));
  }, []);

  // the stub's countdown; the real slot has its own
  useEffect(() => {
    if (done || gam?.on) return;
    const tm = setInterval(() => setLeft((n) => (n > 0 ? n - 1 : 0)), 1000);
    return () => clearInterval(tm);
  }, [done, gam?.on]);

  const credit = async (nonce?: string) => {
    const r = await watchAd(nonce);
    setDone({ credited: r.credited, left_today: r.left_today });
    onCredited(r.balance);
  };

  // the stub
  const collect = async () => {
    setBusy(true); setErr(null);
    try { await credit(); } catch (e: any) { setErr(e.message ?? String(e)); }
    setBusy(false);
  };

  // the real slot: nonce → ad → credit, and nothing is credited unless Google granted it
  const play = async () => {
    setBusy(true); setErr(null); setNote(null);
    if (consent() !== "accepted") { setNote(t.ads.needConsent); setBusy(false); return; }
    try {
      const { nonce } = await adNonce();
      const result = await showRewarded(gam!.path);
      if (result === "granted") await credit(nonce);
      else if (result === "unavailable") setNote(`${t.ads.noAd} ${t.ads.tryAgain}`);
      else setNote(t.ads.watchToEnd);
    } catch (e: any) { setErr(e.message ?? String(e)); }
    setBusy(false);
  };

  return (
    <Modal title={t.ad.title} onClose={onClose}>
      {done ? (
        <div>
          <div className="banner ok" role="status"><b>{t.ad.credited(done.credited)}</b> {done.left_today > 0 ? t.ad.more(done.left_today) : t.ad.allDone}</div>
          <div className="row-of">
            <button className="btn big" onClick={onClose}>{t.common.done}</button>
            {done.left_today > 0 && <button className="btn" onClick={() => { setDone(null); setLeft(AD_SECONDS); setNote(null); }}>{t.ad.another}</button>}
          </div>
        </div>
      ) : gam?.on ? (
        <div>
          <div className="ad-stub">
            <div className="eyebrow">{t.ad.label}</div>
            <div className="small muted">{t.ads.watchToEnd}</div>
          </div>
          {note && <div className="banner warn" role="status"><div>{note}</div></div>}
          <ErrorBox msg={err} />
          <button className="btn big" disabled={busy} onClick={play}>
            {busy ? t.ads.loading : t.ad.collect(reward)}
          </button>
        </div>
      ) : (
        <div>
          <div className="ad-stub">
            <div className="eyebrow">{t.ad.label}</div>
            <div className="num lime ad-count">{fmt.num(left)}</div>
            <div className="small muted">{left > 0 ? t.ad.watchOn : t.ad.watchDone}</div>
            <div className="ad-progress"><i style={{ width: `${((AD_SECONDS - left) / AD_SECONDS) * 100}%` }} /></div>
          </div>
          <p className="tiny muted">{t.ad.stub}</p>
          <ErrorBox msg={err} />
          <button className="btn big" disabled={left > 0 || busy} onClick={collect}>
            {busy ? t.ad.collecting : left > 0 ? t.ad.collectIn(reward, left) : t.ad.collect(reward)}
          </button>
        </div>
      )}
    </Modal>
  );
}
