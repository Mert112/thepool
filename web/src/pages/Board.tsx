import { useState, type CSSProperties } from "react";
import { useNavigate } from "react-router-dom";
import { getBoard, getCompetitions, getMarkets, getMyCardMatches, myCompetitions, openCard, getMyCrews, type BoardRow, type Market } from "../lib/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { liveClock, marketTitle, offered } from "../lib/calls";
import { soon } from "../lib/format";
import { useI18n, type Dict } from "../i18n";
import { Empty, ErrorBox, Modal } from "../components/ui";
import { LeaguesDialog } from "../components/Leagues";

export default function Board() {
  const nav = useNavigate();
  const now = useNow();
  const { session } = useAuth();
  const { t, fmt } = useI18n();
  const uid = session!.user.id;
  const [phase, setPhase] = useState<"live" | "upcoming" | "settled">("upcoming");
  const [league, setLeague] = useState("ALL");
  const [creating, setCreating] = useState<BoardRow | null>(null);
  const [leagues, setLeagues] = useState(false);
  const [follows, setFollows] = useState(0);
  // §provider the board is the competitions this account follows — twelve plus the national
  // teams out of the box, and whatever else was added under "More leagues" (0024)
  const { data: meta } = useLoad(async () => {
    const [comps, markets, mine, mineComps] = await Promise.all([getCompetitions(), getMarkets(), getMyCardMatches(uid), myCompetitions()]);
    return { comps, markets, mine, following: new Set(mineComps.following.map((c) => c.code)) };
  }, [follows]);
  const { data: board, error, loading, reload } = useLoad(() => getBoard(), []);

  if (error) return <ErrorBox msg={error} />;
  // a game past its start is closed for cards even when the feed has no live data for it yet
  const followed = meta?.following;
  const rowsAll = (board ?? [])
    .filter((r) => !followed || followed.has(r.competition_code))
    .map((r) => (r.phase === "upcoming" && new Date(r.utc_date).getTime() <= now ? { ...r, phase: "live" as const, clock: r.clock ?? t.board.started } : r));
  const liveRows = rowsAll.filter((r) => r.phase === "live");
  const comps = meta?.comps ?? [];
  const leaguesOnBoard = ["ALL", ...comps.filter((c) => rowsAll.some((r) => r.competition_code === c.code)).map((c) => c.code)];
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
          {liveRows.map((r) => <div key={r.match_id} onClick={() => go(r)} style={{ cursor: "pointer" }}><span className="min">{liveClock(r, t)}</span><span>{r.home_short ?? r.home_team}</span><span className="sc">{r.home_score ?? 0}–{r.away_score ?? 0}</span><span>{r.away_short ?? r.away_team}</span></div>)}
        </div>
      )}
      <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 14 }}>
        <div className="row-of">
          {(["live", "upcoming", "settled"] as const).map((p) => (
            <button key={p} className={"pill" + (phase === p ? " on" : "")} onClick={() => setPhase(p)}>
              {p === "live" ? t.board.live(liveRows.length) : p === "upcoming" ? t.board.upcoming : t.board.settled}
            </button>
          ))}
        </div>
        <div className="row-of">
          {leaguesOnBoard.length > 2 && leaguesOnBoard.map((l) => <button key={l} className={"chip" + (league === l ? " on" : "")} onClick={() => setLeague(l)}>{l === "ALL" ? t.board.all : comps.find((c) => c.code === l)?.name ?? l}</button>)}
          <button className="chip" onClick={() => setLeagues(true)}>{t.leagues.more}</button>
        </div>
      </div>

      <div className="board-row board-head">
        <span>{phase === "live" ? t.board.colNow : phase === "settled" ? t.board.colStatus : t.board.colStarts}</span>
        <span className="hide-m">{t.board.colCompetition}</span>
        <span>{t.board.colGame}</span>
        <span className="hide-m">{t.board.colCard}</span>
        <span className="hide-m">{t.board.colPlaying}</span>
        <span className="hide-m">{phase === "upcoming" ? t.board.colDeadline : ""}</span>
        <span></span>
      </div>
      {loading && !board && Array.from({ length: 6 }, (_, i) => <div key={i} className="skeleton" style={{ animationDelay: `${i * 90}ms` }} />)}
      {board && rows.length === 0 && followed?.size === 0 && <Empty>{t.leagues.emptyBoard} <button className="btn" onClick={() => setLeagues(true)}>{t.leagues.more}</button></Empty>}
      {board && rows.length === 0 && followed?.size !== 0 && <Empty>{t.board.emptyHere}{league !== "ALL" ? t.board.emptyForComp : ""}. {phase === "live" ? t.board.emptyLive : phase === "upcoming" ? t.board.emptyUpcoming : t.board.emptySettled}</Empty>}
      {rows.map((r, i) => {
        const live = r.phase === "live", settled = r.phase === "settled";
        const mk = allMarkets.filter((k) => offered(k, r));
        return (
          <div className="board-row" key={r.match_id} style={{ "--i": i } as CSSProperties}>
            <div>
              <div style={{ fontSize: 15, fontWeight: 700, color: live ? "var(--magenta)" : "var(--text)" }}>{live ? <><span className="live-dot" />{liveClock(r, t)}</> : settled ? t.board.ft : fmt.time(r.utc_date)}</div>
              <div className="tiny faint">{live ? "" : fmt.day(r.utc_date)}</div>
            </div>
            <div className="hide-m tiny muted" style={{ fontWeight: 700 }}>
              {r.competition_name}
              {r.event_name && <div className="faint" style={{ fontWeight: 400, marginTop: 2 }}>{r.event_name}</div>}
            </div>
            <div className="tie">
              <b>{r.home_team}</b>
              <span className={"score" + (r.phase === "upcoming" ? " v" : "")}>{r.phase === "upcoming" ? t.common.v : `${r.home_score ?? 0} – ${r.away_score ?? 0}`}</span>
              <b>{r.away_team}</b>
            </div>
            <div className="hide-m tiny" style={{ fontWeight: 700, letterSpacing: "0.06em", textTransform: "uppercase", color: r.card_count ? "var(--text-2)" : "var(--mute)" }}>
              {mine(r.match_id) && <div className="lime" style={{ marginBottom: 2 }}>{t.board.yourCardIsIn}</div>}
              {r.public_card_mode ? (r.public_card_mode === "complex" ? t.board.complexCalls(mk.length) : t.board.simpleCalls(mk.filter((k) => k.simple).length)) : r.card_count ? t.board.crewCards(r.card_count) : t.board.noCardYet}
            </div>
            <div className="hide-m small">
              <span className="bar" style={{ width: Math.max(6, Math.min(48, Math.round(Math.sqrt(r.playing) * 1.3))), background: r.playing ? "var(--lime)" : "var(--line)" }} />
              <div className="tiny muted" style={{ marginTop: 4 }}>{r.playing ? t.board.playing(r.playing) : t.board.beTheFirst}</div>
            </div>
            <div className="hide-m small num" style={{ color: live || soon(r.utc_date, now) ? "var(--magenta)" : "var(--soft)" }}>{live ? t.when.inPlay : settled ? t.board.settled : fmt.countdown(r.utc_date, now)}</div>
            <div style={{ textAlign: "right" }}>
              <button className={"btn" + (r.phase === "upcoming" && r.card_count && !mine(r.match_id) ? " primary" : "")} onClick={() => go(r)}>
                {live ? t.board.watch : settled ? t.board.recap : mine(r.match_id) ? t.board.yourCardIsIn : r.card_count ? t.board.join : t.board.openIt}
              </button>
            </div>
          </div>
        );
      })}
      {leagues && <LeaguesDialog onClose={() => { setLeagues(false); setFollows((n) => n + 1); }} />}
      {creating && <CreateCardDialog row={creating} onClose={() => setCreating(null)} onDone={(cardId) => { setCreating(null); reload(); nav(`/card/${cardId}`); }} />}
    </div>
  );
}

const listOf = (ks: Market[], t: Dict) => t.list(ks.map((k) => marketTitle(k, t)));

// §5.6 "Opening a card": pick the audience, pick the scoring
export function CreateCardDialog({ row, onClose, onDone, defaultCrew }: { row: BoardRow; onClose: () => void; onDone: (cardId: string) => void; defaultCrew?: string | null }) {
  const { t, fmt } = useI18n();
  const [mode, setMode] = useState<"simple" | "complex">("complex");
  const [audience, setAudience] = useState<string | null>(defaultCrew ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const { data, error: loadErr } = useLoad(async () => {
    const [crews, markets] = await Promise.all([getMyCrews(), getMarkets()]);
    return { crews, markets: markets.filter((k) => offered(k, row)) };
  }, [row.match_id]);
  const on = (m: "simple" | "complex") => (data?.markets ?? []).filter((k) => m === "complex" || k.simple);
  const create = async () => {
    setBusy(true); setErr(null);
    try { onDone(await openCard(row.match_id, mode, audience)); } catch (e: any) { setErr(e.message); setBusy(false); }
  };
  const simpleKs = on("simple"), extraKs = on("complex").filter((k) => !k.simple);
  return (
    <Modal title={t.createCard.title} onClose={onClose}>
      <div className="eyebrow">{row.competition_name} · {fmt.day(row.utc_date)} {fmt.time(row.utc_date)}</div>
      <h3 className="display" style={{ margin: "6px 0 16px" }}>{row.home_team} {t.common.v} {row.away_team}</h3>
      <div className="eyebrow" style={{ marginBottom: 8 }}>{t.createCard.scoring}</div>
      {(["simple", "complex"] as const).map((m) => (
        <button key={m} className={"choice" + (mode === m ? " on" : "")} onClick={() => setMode(m)}>
          <b>{m === "simple" ? t.createCard.simple(on("simple").length) : t.createCard.complex(on("complex").length)}</b>
          <small>{m === "simple" ? t.createCard.simpleIs(listOf(simpleKs, t)) : t.createCard.complexAdds(listOf(extraKs, t))}</small>
        </button>
      ))}
      <div className="tiny muted" style={{ marginTop: 10 }}>{t.createCard.pots}</div>
      <div className="eyebrow" style={{ margin: "14px 0 8px" }}>{t.createCard.audience}</div>
      <button className={"choice" + (audience === null ? " on" : "")} onClick={() => setAudience(null)}><b>{t.createCard.everyone}</b><small>{t.createCard.everyoneNote}</small></button>
      {(data?.crews ?? []).map((c) => (
        <button key={c.id} className={"choice" + (audience === c.id ? " on" : "")} onClick={() => { setAudience(c.id); setMode(c.mode); }}><b>{c.name}</b><small>{t.createCard.crewNote}</small></button>
      ))}
      <ErrorBox msg={err ?? loadErr} />
      <div style={{ marginTop: 14 }}><button className="btn big" disabled={busy || !data} onClick={create}>{t.createCard.go}</button></div>
    </Modal>
  );
}
