// §5.8 Profile: season points, overall rank, cards, hit rate, streak, points by competition,
// and the full prediction history — every card played, with each call and whether it hit or missed.
import { useState } from "react";
import { Link } from "react-router-dom";
import { myHistory, myStats, type HistoryCall, type HistoryCard } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { fmtDay, ord } from "../lib/format";
import { Bar, ErrorBox, Spinner } from "../components/ui";

const STATE: Record<HistoryCall["result"], { label: string; cls: string }> = {
  hit: { label: "Hit", cls: "tag hit" },
  miss: { label: "Missed", cls: "tag miss" },
  void: { label: "Void", cls: "tag" },
  pending: { label: "Open", cls: "tag" },
};

export default function Profile() {
  const { profile } = useAuth();
  const { data, error, loading } = useLoad(async () => {
    const [stats, history] = await Promise.all([myStats(), myHistory(60)]);
    return { stats, history };
  }, []);
  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const s = data!.stats, history = data!.history;
  const max = Math.max(1, ...s.competitions.map((c) => c.points));
  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">You</div>
          <h1 className="display" style={{ margin: "6px 0 10px" }}>{profile?.display_name ?? "Player"}</h1>
          <div className="muted">{s.rank ? `${ord(s.rank)} of ${s.players} overall.` : "No settled cards yet — the first full time puts you on the table."} <Link to="/settings" className="lime small">Settings</Link></div>
          <div className="tiles" style={{ marginTop: 16 }}>
            <div className="tile"><div className="v">{s.points}</div><div className="k">Points</div></div>
            <div className="tile"><div className="v">{s.rank ? ord(s.rank) : "–"}</div><div className="k">Overall</div></div>
            <div className="tile"><div className="v">{s.cards}</div><div className="k">Cards</div></div>
            <div className="tile"><div className="v">{s.hit_rate}%</div><div className="k">Hit rate</div></div>
          </div>
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 10 }}>Prediction history · {history.length} {history.length === 1 ? "card" : "cards"}</div>
          {history.length === 0 && <div className="muted small">Nothing yet. Fill a card on the board and it shows up here with every call.</div>}
          {history.map((h) => <HistoryRow key={h.entry_id} h={h} />)}
        </div>
      </div>

      <div className="stack">
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
