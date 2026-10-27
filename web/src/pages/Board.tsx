import { useEffect, useState, type CSSProperties } from "react";
import { useNavigate } from "react-router-dom";
import { getBoard, getMyCardMatches, type BoardRow } from "../features/board/api";
import { getCardsForMatch, getMarkets } from "../features/card/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { useFollows } from "../features/board/follows";
import { liveClock, offered } from "../features/card/calls";
import { soon } from "../lib/format";
import { useI18n } from "../lib/i18n";
import { Empty, ErrorBox } from "../components/ui";
import { CreateCardDialog } from "../features/card/CreateCardDialog";
import { LeaguesDialog } from "../features/board/LeaguesDialog";

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
  // §provider the board is the competitions this account follows — twelve plus the national
  // teams out of the box, and whatever else was added under "More leagues" (0024). Read from the
  // one shared list, so a follow in the dialog changes the board while the dialog is still open.
  const follows = useFollows();
  const { data: meta } = useLoad(async () => {
    const [markets, mine] = await Promise.all([getMarkets(), getMyCardMatches(uid)]);
    return { markets, mine };
  }, []);
  // reloaded when the follows change, every 30 seconds while the tab is open, and on coming back
  // to it — so a card someone else just opened shows as open without a page refresh
  const followKey = follows.following.map((c) => c.code).join(",");
  const { data: board, error, loading, reload } = useLoad(() => getBoard(), [followKey]);
  useEffect(() => {
    const tick = () => { if (document.visibilityState === "visible") reload(); };
    const timer = setInterval(tick, 30000);
    window.addEventListener("focus", tick);
    return () => { clearInterval(timer); window.removeEventListener("focus", tick); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (error) return <ErrorBox msg={error} />;
  // a game past its start is closed for cards even when the feed has no live data for it yet
  const followed = follows.loaded ? new Set(follows.following.map((c) => c.code)) : undefined;
  const rowsAll = (board ?? [])
    .filter((r) => !followed || followed.has(r.competition_code))
    .map((r) => (r.phase === "upcoming" && new Date(r.utc_date).getTime() <= now ? { ...r, phase: "live" as const, clock: r.clock ?? t.board.started } : r));
  const liveRows = rowsAll.filter((r) => r.phase === "live");
  // the chips are "My leagues", every one of them, in the same order as everywhere else; one with
  // no games in the window yet (just followed, or between seasons) is dimmed, not hidden
  const comps = follows.following;
  const hasGames = new Set(rowsAll.map((r) => r.competition_code));
  // a league just unfollowed falls back to all, rather than an empty board
  const shown = comps.some((c) => c.code === league) ? league : "ALL";
  const rows = rowsAll.filter((r) => r.phase === phase).filter((r) => shown === "ALL" || r.competition_code === shown);
  if (phase === "settled") rows.reverse();
  const allMarkets = meta?.markets ?? [];
  // a match this player already has a card on reads "Your card is in", not "Join"
  const mine = (id: number) => !!meta?.mine.has(id);

  const go = async (r: BoardRow) => {
    if (r.phase === "upcoming") {
      if (r.card_count > 0 || mine(r.match_id)) return nav(`/match/${r.match_id}`);
      // the board may be up to 30 seconds old: if somebody opened a card meanwhile, join it
      if ((await getCardsForMatch(r.match_id)).some((c) => c.opened_at)) { reload(); return nav(`/match/${r.match_id}`); }
      return setCreating(r);
    }
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
          {comps.length > 1 && <button className={"chip" + (shown === "ALL" ? " on" : "")} onClick={() => setLeague("ALL")}>{t.board.all}</button>}
          {comps.length > 1 && comps.map((c) => (
            <button key={c.code} className={"chip" + (shown === c.code ? " on" : "") + (hasGames.has(c.code) ? "" : " dim")}
                    title={hasGames.has(c.code) ? undefined : t.board.noGamesYet} onClick={() => setLeague(c.code)}>{c.name}</button>
          ))}
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
      {board && rows.length === 0 && followed?.size !== 0 && <Empty>{t.board.emptyHere}{shown !== "ALL" ? t.board.emptyForComp : ""}. {phase === "live" ? t.board.emptyLive : phase === "upcoming" ? t.board.emptyUpcoming : t.board.emptySettled}</Empty>}
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
      {leagues && <LeaguesDialog onClose={() => setLeagues(false)} />}
      {creating && <CreateCardDialog row={creating} onClose={() => setCreating(null)} onDone={(cardId) => { setCreating(null); reload(); nav(`/card/${cardId}`); }} />}
    </div>
  );
}
