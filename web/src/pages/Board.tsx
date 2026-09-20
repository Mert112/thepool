import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { getBoard, getCompetitions, getMarkets, openCard, getMyCrews, type BoardRow } from "../lib/api";
import { useLoad, useNow } from "../lib/auth";
import { countdown, fmtDay, fmtTime, soon } from "../lib/format";
import { Empty, ErrorBox, Modal, Spinner } from "../components/ui";

export default function Board() {
  const nav = useNavigate();
  const now = useNow();
  const [phase, setPhase] = useState<"live" | "upcoming" | "settled">("upcoming");
  const [league, setLeague] = useState("ALL");
  const [creating, setCreating] = useState<BoardRow | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [board, comps] = await Promise.all([getBoard(), getCompetitions()]);
    return { board, comps };
  }, []);
  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const board = data!.board;
  const liveRows = board.filter((r) => r.phase === "live");
  const leagues = ["ALL", ...data!.comps.filter((c) => board.some((r) => r.competition_code === c.code)).map((c) => c.code)];
  const rows = board.filter((r) => r.phase === phase).filter((r) => league === "ALL" || r.competition_code === league);
  if (phase === "settled") rows.reverse();

  const go = (r: BoardRow) => {
    if (r.phase === "upcoming") { if (r.card_count > 0) nav(`/match/${r.match_id}`); else setCreating(r); }
    else if (r.public_card_id) nav(`/card/${r.public_card_id}/live`);
    else nav(`/match/${r.match_id}`);
  };

  return (
    <div>
      {liveRows.length > 0 && (
        <div className="ticker">
          {liveRows.map((r) => <div key={r.match_id} onClick={() => go(r)} style={{ cursor: "pointer" }}><span className="min">{r.minute ? `${r.minute}'` : "Live"}</span><span>{r.home_short ?? r.home_team}</span><span className="sc">{r.home_score ?? 0}–{r.away_score ?? 0}</span><span>{r.away_short ?? r.away_team}</span></div>)}
        </div>
      )}
      <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 14 }}>
        <div className="row-of">
          {(["live", "upcoming", "settled"] as const).map((p) => (
            <button key={p} className={"pill" + (phase === p ? " on" : "")} onClick={() => setPhase(p)}>
              {p === "live" ? `Live now (${liveRows.length})` : p === "upcoming" ? "Upcoming" : "Settled"}
            </button>
          ))}
        </div>
        <div className="row-of">
          {leagues.map((l) => <button key={l} className={"chip" + (league === l ? " on" : "")} onClick={() => setLeague(l)}>{l === "ALL" ? "All" : data!.comps.find((c) => c.code === l)?.name ?? l}</button>)}
        </div>
      </div>

      <div className="board-row board-head">
        <span>{phase === "live" ? "Minute" : phase === "settled" ? "Status" : "Kick-off"}</span>
        <span className="hide-m">Comp</span>
        <span>Fixture</span>
        <span className="hide-m">Card</span>
        <span className="hide-m">Playing</span>
        <span className="hide-m">{phase === "upcoming" ? "Deadline" : ""}</span>
        <span></span>
      </div>
      {rows.length === 0 && <Empty>Nothing here{league !== "ALL" ? " for this competition" : ""}. {phase === "live" ? "No match is in play right now." : phase === "upcoming" ? "Fixtures appear as the provider publishes them." : "Settled cards will show up here after full time."}</Empty>}
      {rows.map((r) => {
        const live = r.phase === "live", settled = r.phase === "settled";
        return (
          <div className="board-row" key={r.match_id}>
            <div>
              <div style={{ fontSize: 15, fontWeight: 700, color: live ? "var(--magenta)" : "var(--text)" }}>{live ? (r.minute ? `${r.minute}'` : "Live") : settled ? "FT" : fmtTime(r.utc_date)}</div>
              <div className="tiny faint">{settled ? fmtDay(r.utc_date) : live ? "" : fmtDay(r.utc_date)}</div>
            </div>
            <div className="hide-m tiny muted" style={{ fontWeight: 700 }}>{r.competition_name}</div>
            <div className="tie">
              <b>{r.home_team}</b>
              <span className={"score" + (r.phase === "upcoming" ? " v" : "")}>{r.phase === "upcoming" ? "v" : `${r.home_score ?? 0} – ${r.away_score ?? 0}`}</span>
              <b>{r.away_team}</b>
            </div>
            <div className="hide-m tiny" style={{ fontWeight: 700, letterSpacing: "0.06em", textTransform: "uppercase", color: r.card_count ? "var(--text-2)" : "var(--mute)" }}>
              {r.public_card_mode ? (r.public_card_mode === "complex" ? "Complex · 8 calls" : "Simple") : r.card_count ? `${r.card_count} crew card${r.card_count > 1 ? "s" : ""}` : "No card yet"}
            </div>
            <div className="hide-m small">
              <span className="bar" style={{ width: Math.max(6, Math.min(48, Math.round(Math.sqrt(r.playing) * 1.3))), background: r.playing ? "var(--lime)" : "var(--line)" }} />
              <div className="tiny muted" style={{ marginTop: 4 }}>{r.playing ? `${r.playing.toLocaleString()} playing` : "be the first"}</div>
            </div>
            <div className="hide-m small num" style={{ color: live || soon(r.utc_date, now) ? "var(--magenta)" : "var(--soft)" }}>{live ? "In play" : settled ? "Settled" : countdown(r.utc_date, now)}</div>
            <div style={{ textAlign: "right" }}>
              <button className={"btn" + (r.phase === "upcoming" && r.card_count ? " primary" : "")} onClick={() => go(r)}>
                {live ? "Watch" : settled ? "Recap" : r.card_count ? "Join" : "Open"}
              </button>
            </div>
          </div>
        );
      })}
      {creating && <CreateCardDialog row={creating} onClose={() => setCreating(null)} onDone={(cardId) => { setCreating(null); reload(); nav(`/card/${cardId}`); }} />}
    </div>
  );
}

// §5.6 "Opening a card": pick the audience, pick the scoring
export function CreateCardDialog({ row, onClose, onDone, defaultCrew }: { row: BoardRow; onClose: () => void; onDone: (cardId: string) => void; defaultCrew?: string | null }) {
  const [mode, setMode] = useState<"simple" | "complex">("complex");
  const [audience, setAudience] = useState<string | null>(defaultCrew ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const { data } = useLoad(async () => ({ crews: await getMyCrews(), markets: await getMarkets() }), []);
  const max = (m: "simple" | "complex") => (data?.markets ?? []).filter((k) => m === "complex" || k.simple).reduce((s, k) => s + k.points, 0);
  const count = (m: "simple" | "complex") => (data?.markets ?? []).filter((k) => m === "complex" || k.simple).length;
  const create = async () => {
    setBusy(true); setErr(null);
    try { onDone(await openCard(row.match_id, mode, audience)); } catch (e: any) { setErr(e.message); setBusy(false); }
  };
  return (
    <Modal title={`Open a card`} onClose={onClose}>
      <div className="eyebrow">{row.competition_name} · {fmtDay(row.utc_date)} {fmtTime(row.utc_date)}</div>
      <h3 className="display" style={{ margin: "6px 0 16px" }}>{row.home_team} v {row.away_team}</h3>
      <div className="eyebrow" style={{ marginBottom: 8 }}>Scoring</div>
      {(["simple", "complex"] as const).map((m) => (
        <button key={m} className={"choice" + (mode === m ? " on" : "")} onClick={() => setMode(m)}>
          <b>{m === "simple" ? `Simple · ${count("simple")} calls` : `Complex · ${count("complex")} calls`}</b>
          <small>{m === "simple" ? `The winner and the draw. Maximum ${max("simple")} points.` : `Adds the scoreline, a scorer, an assist, a yellow and a red. Maximum ${max("complex")}.`}</small>
        </button>
      ))}
      <div className="eyebrow" style={{ margin: "14px 0 8px" }}>Who plays it</div>
      <button className={"choice" + (audience === null ? " on" : "")} onClick={() => setAudience(null)}><b>Everyone</b><small>A public card — anyone on The Pool can join it.</small></button>
      {(data?.crews ?? []).map((c) => (
        <button key={c.id} className={"choice" + (audience === c.id ? " on" : "")} onClick={() => { setAudience(c.id); setMode(c.mode); }}><b>{c.name}</b><small>Scored only inside this crew.</small></button>
      ))}
      <ErrorBox msg={err} />
      <div style={{ marginTop: 14 }}><button className="btn big" disabled={busy} onClick={create}>Open the card</button></div>
    </Modal>
  );
}
