import { useState, type CSSProperties } from "react";
import { useNavigate } from "react-router-dom";
import { getBoard, getCompetitions, getMarkets, getMyCardMatches, openCard, getMyCrews, type BoardRow, type Market } from "../lib/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { liveClock, offered } from "../lib/calls";
import { countdown, fmtDay, fmtTime, soon } from "../lib/format";
import { Empty, ErrorBox, Modal } from "../components/ui";

export default function Board() {
  const nav = useNavigate();
  const now = useNow();
  const { session } = useAuth();
  const uid = session!.user.id;
  const [phase, setPhase] = useState<"live" | "upcoming" | "settled">("upcoming");
  const [league, setLeague] = useState("ALL");
  const [creating, setCreating] = useState<BoardRow | null>(null);
  const { data: meta } = useLoad(async () => {
    const [comps, markets, mine] = await Promise.all([getCompetitions(), getMarkets(), getMyCardMatches(uid)]);
    return { comps, markets, mine };
  }, []);
  const { data: board, error, loading, reload } = useLoad(() => getBoard(), []);

  if (error) return <ErrorBox msg={error} />;
  // a game past its start is closed for cards even when the feed has no live data for it yet
  const rowsAll = (board ?? []).map((r) => (r.phase === "upcoming" && new Date(r.utc_date).getTime() <= now ? { ...r, phase: "live" as const, clock: r.clock ?? "Started" } : r));
  const liveRows = rowsAll.filter((r) => r.phase === "live");
  const comps = meta?.comps ?? [];
  const leagues = ["ALL", ...comps.filter((c) => rowsAll.some((r) => r.competition_code === c.code)).map((c) => c.code)];
  const rows = rowsAll.filter((r) => r.phase === phase).filter((r) => league === "ALL" || r.competition_code === league);
  if (phase === "settled") rows.reverse();
  const allMarkets = meta?.markets ?? [];
  // a match this player already has a card on reads "Your card is in", not "Join"
  const mine = (id: number) => !!meta?.mine.has(id);

  const go = (r: BoardRow) => {
    if (r.phase === "upcoming") { if (r.card_count > 0 || mine(r.match_id)) nav(`/match/${r.match_id}`); else setCreating(r); }
    else if (r.public_card_id) nav(`/card/${r.public_card_id}/live`);
    else nav(`/match/${r.match_id}`);
  };

  return (
    <div>
      {liveRows.length > 0 && (
        <div className="ticker">
          {liveRows.map((r) => <div key={r.match_id} onClick={() => go(r)} style={{ cursor: "pointer" }}><span className="min">{liveClock(r)}</span><span>{r.home_short ?? r.home_team}</span><span className="sc">{r.home_score ?? 0}–{r.away_score ?? 0}</span><span>{r.away_short ?? r.away_team}</span></div>)}
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
          {leagues.length > 2 && leagues.map((l) => <button key={l} className={"chip" + (league === l ? " on" : "")} onClick={() => setLeague(l)}>{l === "ALL" ? "All" : comps.find((c) => c.code === l)?.name ?? l}</button>)}
        </div>
      </div>

      <div className="board-row board-head">
        <span>{phase === "live" ? "Now" : phase === "settled" ? "Status" : "Starts"}</span>
        <span className="hide-m">Competition</span>
        <span>Game</span>
        <span className="hide-m">Card</span>
        <span className="hide-m">Playing</span>
        <span className="hide-m">{phase === "upcoming" ? "Deadline" : ""}</span>
        <span></span>
      </div>
      {loading && !board && Array.from({ length: 6 }, (_, i) => <div key={i} className="skeleton" style={{ animationDelay: `${i * 90}ms` }} />)}
      {board && rows.length === 0 && <Empty>Nothing here{league !== "ALL" ? " for this competition" : ""}. {phase === "live" ? "No game is in play right now." : phase === "upcoming" ? "Games appear as soon as they are scheduled." : "Settled cards show up here after the final whistle."}</Empty>}
      {rows.map((r, i) => {
        const live = r.phase === "live", settled = r.phase === "settled";
        const mk = allMarkets.filter((k) => offered(k, r));
        return (
          <div className="board-row" key={r.match_id} style={{ "--i": i } as CSSProperties}>
            <div>
              <div style={{ fontSize: 15, fontWeight: 700, color: live ? "var(--magenta)" : "var(--text)" }}>{live ? <><span className="live-dot" />{liveClock(r)}</> : settled ? "FT" : fmtTime(r.utc_date)}</div>
              <div className="tiny faint">{live ? "" : fmtDay(r.utc_date)}</div>
            </div>
            <div className="hide-m tiny muted" style={{ fontWeight: 700 }}>
              {r.competition_name}
              {r.event_name && <div className="faint" style={{ fontWeight: 400, marginTop: 2 }}>{r.event_name}</div>}
            </div>
            <div className="tie">
              <b>{r.home_team}</b>
              <span className={"score" + (r.phase === "upcoming" ? " v" : "")}>{r.phase === "upcoming" ? "v" : `${r.home_score ?? 0} – ${r.away_score ?? 0}`}</span>
              <b>{r.away_team}</b>
            </div>
            <div className="hide-m tiny" style={{ fontWeight: 700, letterSpacing: "0.06em", textTransform: "uppercase", color: r.card_count ? "var(--text-2)" : "var(--mute)" }}>
              {mine(r.match_id) && <div className="lime" style={{ marginBottom: 2 }}>Your card is in</div>}
              {r.public_card_mode ? (r.public_card_mode === "complex" ? `Complex · ${mk.length} calls` : `Simple · ${mk.filter((k) => k.simple).length} calls`) : r.card_count ? `${r.card_count} crew card${r.card_count > 1 ? "s" : ""}` : "No card yet"}
            </div>
            <div className="hide-m small">
              <span className="bar" style={{ width: Math.max(6, Math.min(48, Math.round(Math.sqrt(r.playing) * 1.3))), background: r.playing ? "var(--lime)" : "var(--line)" }} />
              <div className="tiny muted" style={{ marginTop: 4 }}>{r.playing ? `${r.playing.toLocaleString()} playing` : "be the first"}</div>
            </div>
            <div className="hide-m small num" style={{ color: live || soon(r.utc_date, now) ? "var(--magenta)" : "var(--soft)" }}>{live ? "In play" : settled ? "Settled" : countdown(r.utc_date, now)}</div>
            <div style={{ textAlign: "right" }}>
              <button className={"btn" + (r.phase === "upcoming" && r.card_count && !mine(r.match_id) ? " primary" : "")} onClick={() => go(r)}>
                {live ? "Watch" : settled ? "Recap" : mine(r.match_id) ? "Your card is in" : r.card_count ? "Join" : "Open"}
              </button>
            </div>
          </div>
        );
      })}
      {creating && <CreateCardDialog row={creating} onClose={() => setCreating(null)} onDone={(cardId) => { setCreating(null); reload(); nav(`/card/${cardId}`); }} />}
    </div>
  );
}

const listOf = (ks: Market[]) => {
  const t = ks.map((k) => k.title.replace(/^The /, "the ").replace(/^A /, "a ").replace(/^An /, "an "));
  return t.length <= 1 ? t.join("") : `${t.slice(0, -1).join(", ")} and ${t[t.length - 1]}`;
};

// §5.6 "Opening a card": pick the audience, pick the scoring
export function CreateCardDialog({ row, onClose, onDone, defaultCrew }: { row: BoardRow; onClose: () => void; onDone: (cardId: string) => void; defaultCrew?: string | null }) {
  const [mode, setMode] = useState<"simple" | "complex">("complex");
  const [audience, setAudience] = useState<string | null>(defaultCrew ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const { data, error: loadErr } = useLoad(async () => {
    const [crews, markets] = await Promise.all([getMyCrews(), getMarkets()]);
    return { crews, markets: markets.filter((k) => offered(k, row)) };
  }, [row.match_id]);
  const on = (m: "simple" | "complex") => (data?.markets ?? []).filter((k) => m === "complex" || k.simple);
  const priced = !!row.odds?.provider;
  const create = async () => {
    setBusy(true); setErr(null);
    try { onDone(await openCard(row.match_id, mode, audience)); } catch (e: any) { setErr(e.message); setBusy(false); }
  };
  const simpleKs = on("simple"), extraKs = on("complex").filter((k) => !k.simple);
  return (
    <Modal title={`Open a card`} onClose={onClose}>
      <div className="eyebrow">{row.competition_name} · {fmtDay(row.utc_date)} {fmtTime(row.utc_date)}</div>
      <h3 className="display" style={{ margin: "6px 0 16px" }}>{row.home_team} v {row.away_team}</h3>
      <div className="eyebrow" style={{ marginBottom: 8 }}>Scoring</div>
      {(["simple", "complex"] as const).map((m) => (
        <button key={m} className={"choice" + (mode === m ? " on" : "")} onClick={() => setMode(m)}>
          <b>{m === "simple" ? `Simple · ${on("simple").length} calls` : `Complex · ${on("complex").length} calls`}</b>
          <small>{m === "simple" ? `${listOf(simpleKs).replace(/^./, (c) => c.toUpperCase())}.` : `Adds ${listOf(extraKs)}.`}</small>
        </button>
      ))}
      <div className="tiny muted" style={{ marginTop: 10 }}>{priced ? `Points follow the odds (${row.odds.provider}): each call pays 10 × its price, locked in when you save it.` : "No odds posted yet: each call pays its standard price."}</div>
      <div className="eyebrow" style={{ margin: "14px 0 8px" }}>Who plays it</div>
      <button className={"choice" + (audience === null ? " on" : "")} onClick={() => setAudience(null)}><b>Everyone</b><small>A public card — anyone on The Pool can join it.</small></button>
      {(data?.crews ?? []).map((c) => (
        <button key={c.id} className={"choice" + (audience === c.id ? " on" : "")} onClick={() => { setAudience(c.id); setMode(c.mode); }}><b>{c.name}</b><small>Scored only inside this crew.</small></button>
      ))}
      <ErrorBox msg={err ?? loadErr} />
      <div style={{ marginTop: 14 }}><button className="btn big" disabled={busy || !data} onClick={create}>Open the card</button></div>
    </Modal>
  );
}
