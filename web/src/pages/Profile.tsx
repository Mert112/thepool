// §5.8 Profile: season points, overall rank, cards, hit rate, streak, points by competition,
// and the full prediction history — every card played, with each call and whether it hit or missed.
import { useState } from "react";
import { Link } from "react-router-dom";
import { claimPrize, myHistory, myLedger, myStats, type HistoryCall, type HistoryCard, type LedgerRow } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { ago, fmtDay, ord } from "../lib/format";
import { AdModal, Bar, ErrorBox, Spinner } from "../components/ui";

const STATE: Record<HistoryCall["result"], { label: string; cls: string }> = {
  hit: { label: "Hit", cls: "tag hit" },
  miss: { label: "Missed", cls: "tag miss" },
  void: { label: "Void", cls: "tag" },
  pending: { label: "Open", cls: "tag" },
};

const REASON: Record<LedgerRow["reason"], string> = {
  signup: "Starting points", stake: "Staked at kick-off", win: "A call landed",
  refund: "A void call, handed back", ad_reward: "Watched an ad", prize: "Prize",
  jackpot: "A share of a jackpot",
};

export default function Profile() {
  const { profile, refreshProfile } = useAuth();
  const [ads, setAds] = useState(false);
  const [claiming, setClaiming] = useState(false);
  const [claimErr, setClaimErr] = useState<string | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [stats, history, ledger] = await Promise.all([myStats(), myHistory(60), myLedger(12)]);
    return { stats, history, ledger };
  }, []);
  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const s = data!.stats, history = data!.history, ledger = data!.ledger;
  const max = Math.max(1, ...s.competitions.map((c) => c.points));
  const balance = profile?.balance ?? s.balance;
  const pct = Math.min(100, (balance / s.prize_target) * 100);
  const claim = async () => {
    setClaiming(true); setClaimErr(null);
    try { await claimPrize(); reload(); } catch (e: any) { setClaimErr(e.message ?? String(e)); }
    setClaiming(false);
  };
  const refresh = () => { refreshProfile(); reload(); };

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">You</div>
          <h1 className="display" style={{ margin: "6px 0 10px" }}>{profile?.display_name ?? "Player"}</h1>
          <div className="muted">{s.rank ? `${ord(s.rank)} of ${s.players} overall.` : "No settled cards yet — the first full time puts you on the table."} <Link to="/settings" className="lime small">Settings</Link></div>
          <div className="tiles" style={{ marginTop: 16 }}>
            <div className="tile"><div className="v">{balance.toLocaleString()}</div><div className="k">Points held</div></div>
            <div className="tile"><div className="v">{s.rank ? ord(s.rank) : "–"}</div><div className="k">Overall</div></div>
            <div className="tile"><div className="v">{s.cards}</div><div className="k">Cards</div></div>
            <div className="tile"><div className="v">{s.hit_rate}%</div><div className="k">Hit rate</div></div>
          </div>
          <div className="small muted" style={{ marginTop: 12 }}>
            {s.committed > 0
              ? <>{s.committed.toLocaleString()} of that is promised to cards that have not kicked off yet.</>
              : <>Nothing is promised to an open card right now.</>}
            {" "}Across every settled card you are {s.points > 0 ? "up" : s.points < 0 ? "down" : "level"} {Math.abs(s.points).toLocaleString()}.
          </div>
        </div>

        <div className="panel">
          <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 10 }}>
            <div className="eyebrow">Get points</div>
            <span className="tiny muted">{s.ads_left} of 10 left today</span>
          </div>
          <div className="small muted" style={{ marginBottom: 12 }}>
            Watch a 30-second ad for 100 points. Ten a day, counted by the database and reset at midnight UTC.
          </div>
          <button className="btn big" disabled={!s.ads_enabled || s.ads_left <= 0} onClick={() => setAds(true)}>
            {!s.ads_enabled ? "Switched off right now" : s.ads_left > 0 ? "Watch an ad · +100" : "Back tomorrow"}
          </button>
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 10 }}>The PlayStation 5</div>
          <div className="row-of" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
            <span className="num lime" style={{ fontSize: 34 }}>{balance.toLocaleString()}</span>
            <span className="small muted">of {s.prize_target.toLocaleString()}</span>
          </div>
          <div className="prize-bar" aria-label={`${Math.floor(pct)}% of the way to a PlayStation 5`}><i style={{ width: `${Math.max(0.6, pct)}%` }} /></div>
          <div className="small muted" style={{ marginTop: 8 }}>
            {balance >= s.prize_target
              ? "You are there. Claim it and we will be in touch by email."
              : `${(s.prize_target - balance).toLocaleString()} to go. Reach a million points and the console is yours.`}
          </div>
          {s.prize_claim?.status === "pending" ? (
            <div className="banner ok" style={{ marginTop: 12, marginBottom: 0 }} role="status"><b>Claim received.</b> Filed {ago(s.prize_claim.created_at)} ago — we handle these by hand and will email you.</div>
          ) : (
            <button className="btn big" style={{ marginTop: 12 }} disabled={balance < s.prize_target || claiming} onClick={claim}>
              {claiming ? "Claiming…" : "Claim the PlayStation 5"}
            </button>
          )}
          <ErrorBox msg={claimErr} />
          {s.prize_claim && s.prize_claim.status !== "pending" && <div className="tiny muted" style={{ marginTop: 8 }}>Your last claim: {s.prize_claim.status}.</div>}
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 10 }}>Prediction history · {history.length} {history.length === 1 ? "card" : "cards"}</div>
          {history.length === 0 && <div className="muted small">Nothing yet. Fill a card on the board and it shows up here with every call.</div>}
          {history.map((h) => <HistoryRow key={h.entry_id} h={h} />)}
        </div>
      </div>

      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>Where the points went</div>
          {ledger.length === 0 && <div className="muted small">Nothing yet.</div>}
          {ledger.map((l, i) => (
            <div key={i} className="small" style={{ display: "flex", justifyContent: "space-between", gap: 10, padding: "6px 0", borderBottom: "1px solid var(--raise)" }}>
              <span className="muted">{REASON[l.reason]}<span className="tiny faint" style={{ marginLeft: 6 }}>{ago(l.created_at)}</span></span>
              <b style={{ color: l.amount > 0 ? "var(--lime)" : "var(--magenta)" }}>{l.amount > 0 ? `+${l.amount}` : l.amount}</b>
            </div>
          ))}
        </div>
        <div className="panel">
          <div className="eyebrow">Matchday streak</div>
          <div className="num lime" style={{ fontSize: 56, lineHeight: 1 }}>{s.streak}</div>
          <div className="small muted">Consecutive matchdays with at least one call landed. Miss a whole matchday and it resets. Loss aversion, no punishment beyond the reset.</div>
        </div>
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>Points by competition</div>
          {s.competitions.length === 0 && <div className="muted small">Play a card in a competition to appear on its table.</div>}
          {s.competitions.map((c) => (
            <div key={c.code} style={{ padding: "8px 0" }}>
              <div className="small" style={{ display: "flex", justifyContent: "space-between" }}><span>{c.name} <span className="muted">· {ord(c.rank)}</span></span><span className="lime">{c.points}</span></div>
              <Bar pct={c.points / max * 100} />
            </div>
          ))}
        </div>
      </div>
      {ads && <AdModal onClose={() => { setAds(false); refresh(); }} onCredited={refresh} />}
    </div>
  );
}

// one past card: the fixture and the result, then every call it carried
function HistoryRow({ h }: { h: HistoryCard }) {
  const [open, setOpen] = useState(false);
  const settled = h.card_status === "settled" || h.card_status === "disputed";
  const score = h.home_score == null ? "v" : `${h.home_score} – ${h.away_score}`;
  const landed = h.calls.filter((c) => c.result === "hit").length;
  return (
    <div className="hist">
      <button className="hist-head" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        <span className="hist-tie">
          <b>{h.home}</b> <span className="num lime">{score}</span> <b>{h.away}</b>
          <span className="tiny muted hist-sub">{h.competition} · {fmtDay(h.utc_date)}{h.crew ? ` · ${h.crew}` : ""} · {settled ? `${landed} of ${h.calls.length} landed` : h.card_status === "open" ? "card still open" : "not settled yet"}</span>
        </span>
        <span className="num hist-pts" style={{ color: h.points > 0 ? "var(--lime)" : "#4a4a44" }}>{h.points > 0 ? `+${h.points}` : settled ? "0" : "—"}</span>
        <span className="hist-caret">{open ? "−" : "+"}</span>
      </button>
      {open && (
        <div className="hist-calls">
          {h.calls.length === 0 && <div className="tiny muted">No calls on this card.</div>}
          {h.calls.map((c) => (
            <div className="hist-call" key={c.call_type}>
              <span className="small"><b>{c.title}</b> <span className="muted">— {c.label}</span></span>
              <span className={STATE[c.result].cls}>{STATE[c.result].label}</span>
              <span className="num" style={{ textAlign: "right", color: c.result === "hit" ? "var(--lime)" : "#4a4a44" }}>{c.result === "hit" ? `+${c.points}` : "0"}</span>
            </div>
          ))}
          <Link to={`/card/${h.card_id}/live`} className="lime tiny">Open the card →</Link>
        </div>
      )}
    </div>
  );
}
