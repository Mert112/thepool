// §5.8 Profile: season points, overall rank, cards, hit rate, streak, points by competition,
// and the full prediction history — every card played, with each call and whether it hit or missed.
// Your picture and your settings live here too: the header picture opens this page.
import { useState } from "react";
import { Link } from "react-router-dom";
import { claimPrize, myLedger, myStats } from "../features/economy/api";
import { myHistory, myIcons, refreshIcons, removeAvatar, setIcon, uploadAvatar, type HistoryCall, type HistoryCard, type IconRow } from "../features/profile/api";
import { PhoneDialog } from "../features/economy/PhoneDialog";
import { useAuth, useLoad } from "../lib/auth";
import { labelOf } from "../features/card/calls";
import { useI18n, type Dict } from "../lib/i18n";
import { AdModal } from "../features/ads/AdModal";
import { Avatar, Bar, ErrorBox, Spinner } from "../components/ui";
import { SettingsPanels } from "./Settings";

const STATE: Record<HistoryCall["result"], keyof Dict["live"]["state"]> = {
  hit: "hit", miss: "miss", void: "void", pending: "open",
};
const STATE_CLS: Record<HistoryCall["result"], string> = {
  hit: "tag hit", miss: "tag miss", void: "tag", pending: "tag",
};

export default function Profile() {
  const { session, profile, refreshProfile } = useAuth();
  const { t, fmt } = useI18n();
  const [ads, setAds] = useState(false);
  const [claiming, setClaiming] = useState(false);
  const [claimErr, setClaimErr] = useState<string | null>(null);
  const [phone, setPhone] = useState(false);
  const [iconErr, setIconErr] = useState<string | null>(null);
  const [picBusy, setPicBusy] = useState(false);
  const [picErr, setPicErr] = useState<string | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    await refreshIcons();   // pick up anything earned since the last visit
    const [stats, history, ledger, icons] = await Promise.all([myStats(), myHistory(60), myLedger(12), myIcons()]);
    return { stats, history, ledger, icons };
  }, []);
  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const s = data!.stats, history = data!.history, ledger = data!.ledger, icons = data!.icons;
  const wear = async (code: string) => {
    setIconErr(null);
    try { await setIcon(code); await refreshProfile(); reload(); } catch (e: any) { setIconErr(e.message ?? String(e)); }
  };
  const max = Math.max(1, ...s.competitions.map((c) => c.points));
  const balance = profile?.balance ?? s.balance;
  const pct = Math.min(100, (balance / s.prize_target) * 100);
  const claim = async (phoneDone = false) => {
    // §0026 the first claim needs a verified phone; the dialog comes back here once it is
    if (s.phone_needed && !phoneDone) { setPhone(true); return; }
    setClaiming(true); setClaimErr(null);
    try { await claimPrize(); reload(); } catch (e: any) { setClaimErr(e.message ?? String(e)); }
    setClaiming(false);
  };
  const refresh = () => { refreshProfile(); reload(); };
  const pic = async (job: () => Promise<void>) => {
    setPicBusy(true); setPicErr(null);
    try { await job(); await refreshProfile(); } catch (e: any) { setPicErr(e.message ?? String(e)); }
    setPicBusy(false);
  };
  const old = profile?.avatar_path ?? null;

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">{t.profile.you}</div>
          <div className="row-of" style={{ gap: 14, margin: "6px 0 10px" }}>
            <span className="av-lg"><Avatar name={profile?.display_name} icon={profile?.icon} pic={profile?.avatar_path} me={!profile?.icon} /></span>
            <div>
              <h1 className="display" style={{ margin: 0 }}>{profile?.display_name ?? t.common.player}</h1>
              <div className="row-of" style={{ marginTop: 6 }}>
                <label className={"btn tiny-btn" + (picBusy ? " disabled" : "")}>
                  {picBusy ? t.common.loading : old ? t.profile.picChange : t.profile.picUpload}
                  <input type="file" accept="image/*" hidden disabled={picBusy} onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ""; if (f) pic(() => uploadAvatar(session!.user.id, f, old)); }} />
                </label>
                {old && <button className="btn ghost tiny-btn" disabled={picBusy} onClick={() => pic(() => removeAvatar(old))}>{t.profile.picRemove}</button>}
              </div>
            </div>
          </div>
          <ErrorBox msg={picErr} />
          <div className="muted">{s.rank ? t.profile.rank(fmt.ord(s.rank), s.players) : t.profile.noRank} <a href="#settings" className="lime small">{t.shell.settings}</a></div>
          <div className="tiles" style={{ marginTop: 16 }}>
            <div className="tile"><div className="v">{fmt.pts(balance)}</div><div className="k">{t.profile.pointsHeld}</div></div>
            <div className="tile"><div className="v">{s.rank ? fmt.ord(s.rank) : "–"}</div><div className="k">{t.profile.overall}</div></div>
            <div className="tile"><div className="v">{fmt.num(s.cards)}</div><div className="k">{t.profile.cards}</div></div>
            <div className="tile"><div className="v">{s.hit_rate}%</div><div className="k">{t.profile.hitRate}</div></div>
          </div>
          <div className="small muted" style={{ marginTop: 12 }}>
            {s.committed > 0 ? t.profile.committed(fmt.pts(s.committed)) : t.profile.nothingCommitted}
            {s.points > 0 ? t.profile.settledUp(fmt.pts(s.points)) : s.points < 0 ? t.profile.settledDown(fmt.pts(Math.abs(s.points))) : t.profile.settledLevel}
          </div>
        </div>

        <div className="panel">
          <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 4 }}>
            <div className="eyebrow">{t.profile.yourIcon}</div>
            <span className="tiny muted">{t.profile.unlocked(icons.filter((i) => i.earned_at).length, icons.length)}</span>
          </div>
          <div className="small muted" style={{ marginBottom: 12 }}>{t.profile.iconBlurb}</div>
          <div className="icons-grid">
            {icons.map((i) => <IconCard key={i.code} i={i} onWear={wear} />)}
          </div>
          <ErrorBox msg={iconErr} />
        </div>

        <div className="panel">
          <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 10 }}>
            <div className="eyebrow">{t.profile.getPoints}</div>
            <span className="tiny muted">{t.profile.adsLeft(s.ads_left)}</span>
          </div>
          <div className="small muted" style={{ marginBottom: 12 }}>{t.profile.adBlurb(fmt.pts(s.ad_reward))}</div>
          <button className="btn big" disabled={!s.ads_enabled || s.ads_left <= 0} onClick={() => setAds(true)}>
            {!s.ads_enabled ? t.profile.adsOff : s.ads_left > 0 ? t.profile.watchAd(fmt.pts(s.ad_reward)) : t.profile.backTomorrow}
          </button>
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 10 }}>{t.profile.prize}</div>
          <div className="row-of" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
            <span className="num lime" style={{ fontSize: 34 }}>{fmt.pts(balance)}</span>
            <span className="small muted">{t.profile.prizeOf(fmt.num(s.prize_target))}</span>
          </div>
          <div className="prize-bar" aria-label={t.profile.prizeAria(Math.floor(pct))}><i style={{ width: `${Math.max(0.6, pct)}%` }} /></div>
          <div className="small muted" style={{ marginTop: 8 }}>
            {balance >= s.prize_target ? t.profile.prizeThere : t.profile.prizeToGo(fmt.pts(s.prize_target - balance))}
          </div>
          {s.prize_claim?.status === "pending" ? (
            <div className="banner ok" style={{ marginTop: 12, marginBottom: 0 }} role="status"><b>{t.profile.claimReceived}</b>{t.profile.claimFiled(fmt.ago(s.prize_claim.created_at))}</div>
          ) : (
            <button className="btn big" style={{ marginTop: 12 }} disabled={balance < s.prize_target || claiming} onClick={() => claim()}>
              {claiming ? t.profile.claiming : t.profile.claim}
            </button>
          )}
          <ErrorBox msg={claimErr} />
          {phone && <PhoneDialog onClose={() => setPhone(false)} onVerified={() => { setPhone(false); claim(true); }} />}
          {s.prize_claim && s.prize_claim.status !== "pending" && <div className="tiny muted" style={{ marginTop: 8 }}>{t.profile.lastClaim(t.profile.claimStatus[s.prize_claim.status])}</div>}
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 10 }}>{t.profile.history} · {t.profile.historyCount(history.length)}</div>
          {history.length === 0 && <div className="muted small">{t.profile.historyEmpty}</div>}
          {history.map((h) => <HistoryRow key={h.entry_id} h={h} />)}
        </div>
      </div>

      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{t.profile.whereWent}</div>
          {ledger.length === 0 && <div className="muted small">{t.common.nothingYet}</div>}
          {ledger.map((l, i) => (
            <div key={i} className="small" style={{ display: "flex", justifyContent: "space-between", gap: 10, padding: "6px 0", borderBottom: "1px solid var(--raise)" }}>
              <span className="muted">{t.ledger[l.reason as keyof typeof t.ledger] ?? l.reason}<span className="tiny faint" style={{ marginLeft: 6 }}>{fmt.ago(l.created_at)}</span></span>
              <b style={{ color: l.amount > 0 ? "var(--lime)" : "var(--magenta)" }}>{fmt.signedPts(Number(l.amount))}</b>
            </div>
          ))}
        </div>
        <div className="panel">
          <div className="eyebrow">{t.profile.streak}</div>
          <div className="num lime" style={{ fontSize: 56, lineHeight: 1 }}>{fmt.num(s.streak)}</div>
          <div className="small muted">{t.profile.streakBlurb}</div>
        </div>
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{t.profile.byCompetition}</div>
          {s.competitions.length === 0 && <div className="muted small">{t.profile.byCompetitionEmpty}</div>}
          {s.competitions.map((c) => (
            <div key={c.code} style={{ padding: "8px 0" }}>
              <div className="small" style={{ display: "flex", justifyContent: "space-between" }}><span>{c.name} <span className="muted">· {fmt.ord(c.rank)}</span></span><span className="lime">{fmt.pts(c.points)}</span></div>
              <Bar pct={c.points / max * 100} />
            </div>
          ))}
        </div>
      </div>
      {ads && <AdModal onClose={() => { setAds(false); refresh(); }} onCredited={refresh} reward={s.ad_reward} />}
      <div style={{ gridColumn: "1 / -1" }}><SettingsPanels /></div>
    </div>
  );
}

// one icon: what it is, how rare, and either how to get it or a tap to wear it
function IconCard({ i, onWear }: { i: IconRow; onWear: (code: string) => void }) {
  const { t } = useI18n();
  const locked = !i.earned_at;
  const name = t.icons[i.code]?.name ?? i.name;
  const how = t.icons[i.code]?.how ?? i.how;
  const rarity = t.rarity[i.rarity] ?? i.rarity;
  const cls = `icon-card r-${i.rarity}` + (locked ? " locked" : "") + (i.wearing ? " on" : "");
  return (
    <button className={cls} disabled={locked} onClick={() => onWear(i.code)}
            title={locked ? t.profile.lockedHint(how) : i.wearing ? t.profile.wearingHint(name) : t.profile.wearHint(name)}>
      <span className="face">{i.glyph}</span>
      <span className="nm">{name}</span>
      <span className={`rar r-${i.rarity}`}>{i.wearing ? t.profile.worn : rarity}</span>
      {locked && <span className="tiny muted" style={{ lineHeight: 1.2 }}>{how}</span>}
    </button>
  );
}

// one past card: the fixture and the result, then every call it carried
function HistoryRow({ h }: { h: HistoryCard }) {
  const { t, fmt } = useI18n();
  const [open, setOpen] = useState(false);
  const settled = h.card_status === "settled" || h.card_status === "disputed";
  const score = h.home_score == null ? t.common.v : `${h.home_score} – ${h.away_score}`;
  const landed = h.calls.filter((c) => c.result === "hit").length;
  return (
    <div className="hist">
      <button className="hist-head" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        <span className="hist-tie">
          <b>{h.home}</b> <span className="num lime">{score}</span> <b>{h.away}</b>
          <span className="tiny muted hist-sub">{h.competition} · {fmt.day(h.utc_date)}{h.crew ? ` · ${h.crew}` : ""} · {settled ? t.history.landed(landed, h.calls.length) : h.card_status === "open" ? t.history.stillOpen : t.history.notSettled}</span>
        </span>
        <span className="num hist-pts" style={{ color: h.points > 0 ? "var(--lime)" : "#4a4a44" }}>{settled ? fmt.signedPts(Number(h.points)) : t.common.dash}</span>
        <span className="hist-caret">{open ? "−" : "+"}</span>
      </button>
      {open && (
        <div className="hist-calls">
          {h.calls.length === 0 && <div className="tiny muted">{t.history.noCalls}</div>}
          {h.calls.map((c) => (
            <div className="hist-call" key={c.call_type}>
              <span className="small"><b>{t.markets[c.call_type]?.title ?? c.title}</b> <span className="muted">— {labelOf(c.parts, t)}</span></span>
              <span className={STATE_CLS[c.result]}>{t.live.state[STATE[c.result]]}</span>
              <span className="num" style={{ textAlign: "right", color: c.result === "hit" ? "var(--lime)" : "#4a4a44" }}>{c.result === "hit" ? `+${fmt.pts(Number(c.points))}` : "0"}</span>
            </div>
          ))}
          <Link to={`/card/${h.card_id}/live`} className="lime tiny">{t.history.openCard}</Link>
        </div>
      )}
    </div>
  );
}
