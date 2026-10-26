// §5.3 The match page: everything about a card before you play it
import { useState } from "react";
import { Link, useLocation, useNavigate, useParams } from "react-router-dom";
import { getCardPlayers, getCardsForMatch, getCrowd, getJackpots, getMarkets, getMatch, getMyCrews, getMyEntry, type Card } from "../lib/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { soon } from "../lib/format";
import { useI18n } from "../i18n";
import { Avatar, Empty, ErrorBox, Spinner } from "../components/ui";
import { CreateCardDialog } from "./Board";
import { labelOf, marketExplainer, marketTitle, offered } from "../lib/calls";

export default function Match() {
  const { id } = useParams();
  const matchId = Number(id);
  const nav = useNavigate();
  const now = useNow();
  const loc = useLocation();
  const { t, fmt } = useI18n();
  // the receipt FillCard hands over when it redirects here after a save
  const justSaved = (loc.state as { saved?: { n: number; staked: number; calls: string[] } } | null)?.saved ?? null;
  const { session } = useAuth();
  const [creatingFor, setCreatingFor] = useState<string | null | undefined>(undefined); // undefined = closed, null = public
  const [selected, setSelected] = useState<string | null>(null);

  const { data, error, loading, reload } = useLoad(async () => {
    const [match, cards, crews] = await Promise.all([getMatch(matchId), getCardsForMatch(matchId), getMyCrews()]);
    const markets = match ? (await getMarkets()).filter((k) => offered(k, match)) : [];
    const jackpots = match ? await getJackpots(match.competition_code) : {};
    const cardId = selected ?? cards.find((c) => c.crew_id === null)?.id ?? cards[0]?.id ?? null;
    const [players, crowd, mine] = cardId ? await Promise.all([getCardPlayers(cardId), getCrowd(cardId), getMyEntry(cardId, session!.user.id)]) : [[], [], null];
    return { match, cards, crews, markets, jackpots, cardId, players, crowd, mine };
  }, [matchId, selected]);

  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const { match, cards, crews, markets, jackpots, cardId, players, crowd, mine } = data!;
  if (!match) return <Empty>{t.match.unknown}</Empty>;
  const card: Card | undefined = cards.find((c) => c.id === cardId);
  const complex = card?.mode === "complex";
  const shown = markets.filter((k) => complex || k.simple);
  const upcoming = match.phase === "upcoming" && new Date(match.utc_date).getTime() > now;   // closed at the start, live data or not
  const topCrowd = (ct: string) => crowd.filter((c) => c.call_type === ct).sort((a, b) => b.n - a.n)[0];

  return (
    <div className="grid two">
      <div className="stack">
        {justSaved && (
          <div className="banner ok" role="status">
            <div>
              <b>{t.common.saved}</b>{" "}
              {justSaved.n === 0 ? t.match.withdrawn : t.match.savedCalls(justSaved.n, fmt.pts(justSaved.staked), justSaved.calls.join(" · "))}
            </div>
            <button className="btn ghost tiny-btn" onClick={() => nav(loc.pathname, { replace: true })}>{t.common.dismiss}</button>
          </div>
        )}
        <div className="panel">
          <div className="eyebrow">{match.competition_name} · {fmt.when(match.utc_date)}</div>
          {match.event_name && <div className="tiny muted" style={{ marginTop: 4 }}>{match.event_name}</div>}
          <h1 className="display" style={{ margin: "8px 0 14px" }}>{match.home_team} <span className="faint">{t.common.v}</span> {match.away_team}</h1>
          {/* every card on this game, plus a public one if nobody has opened it yet (a crew card must not block it) */}
          {(cards.length > 1 || (cards.length > 0 && upcoming && !cards.some((c) => c.crew_id === null))) && (
            <div className="row-of" style={{ marginBottom: 12 }}>
              {cards.map((c) => <button key={c.id} className={"pill" + (c.id === cardId ? " on" : "")} onClick={() => setSelected(c.id)}>{c.crew_id ? c.crews?.name : t.match.openCard}</button>)}
              {upcoming && !cards.some((c) => c.crew_id === null) && <button className="pill" onClick={() => setCreatingFor(null)}>{t.match.cardForEveryone}</button>}
            </div>
          )}
          {card ? (
            <>
              <div className="row-of" style={{ marginBottom: 12 }}>
                <span className="badge">{complex ? t.match.complexCard(shown.length) : t.match.simpleCard(shown.length)}{match.odds?.provider ? t.match.pricedByOdds : ""}</span>
                <span className="small muted">{card.crew_id ? t.match.crewOnly(card.crews?.name ?? "") : t.match.openToAll}</span>
                <span className="small num" style={{ color: soon(match.utc_date, now) ? "var(--magenta)" : "var(--soft)" }}>
                  {upcoming ? t.match.locksIn(fmt.countdown(match.utc_date, now)) : match.phase === "live" ? t.when.inPlay : t.board.settled}
                </span>
              </div>
              <p className="muted">
                {players.length ? t.match.cardsIn(players.length) : t.match.beTheFirst} {t.match.howItWorks}
              </p>
              <div className="row-of">
                {upcoming && <button className="btn big" onClick={() => nav(`/card/${card.id}`)}>{mine ? t.match.editCard : t.match.fillCard}</button>}
                {!upcoming && <button className="btn big" onClick={() => nav(`/card/${card.id}/live`)}>{match.phase === "live" ? t.match.watchLive : t.match.seeRecap}</button>}
                {mine && upcoming && <span className="tag hit">{t.match.cardIn(mine.calls.length, shown.length)}</span>}
              </div>
            </>
          ) : (
            <div>
              <p className="muted">{t.match.noCardYet}</p>
              {upcoming && <button className="btn big" onClick={() => setCreatingFor(null)}>{t.match.openFirst}</button>}
            </div>
          )}
        </div>

        {card && (
          <div className="panel">
            <div className="eyebrow" style={{ marginBottom: 12 }}>{t.match.callsHeading}</div>
            {shown.map((k) => {
              const top = topCrowd(k.call_type);
              return (
                <div key={k.call_type} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) 64px minmax(0,1.2fr)", gap: 14, alignItems: "center", padding: "10px 0", borderBottom: "1px solid var(--raise)" }}>
                  <div>
                    <b>{marketTitle(k, t)}</b>
                    {upcoming && !!jackpots[k.call_type] && <div className="jackpot">{t.match.jackpot(fmt.pts(jackpots[k.call_type]))}</div>}
                    <div className="tiny muted explainer">{marketExplainer(k, t)}</div>
                  </div>
                  <div className="num lime" style={{ fontSize: 20, whiteSpace: "nowrap" }}>{jackpots[k.call_type] ? `+${fmt.pts(jackpots[k.call_type])}` : t.common.dash}</div>
                  <div className="small muted">{top ? <span>{top.pct}% · {labelOf(top.parts, t)}</span> : <span className="faint">{t.match.noCallsYet}</span>}</div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      <div className="stack">
        {card && (
          <div className="panel">
            <div className="eyebrow" style={{ marginBottom: 10 }}>{t.match.alreadyPlaying} · {players.length}</div>
            {players.length === 0 && <div className="muted small">{t.match.nobodyYet}</div>}
            {players.slice(0, 8).map((e) => (
              <div key={e.user_id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 0" }}>
                <Avatar name={e.display_name} me={e.user_id === session?.user.id} />
                <div style={{ flex: 1 }}><div className="small" style={{ fontWeight: 700 }}>{e.user_id === session?.user.id ? t.common.you : e.display_name ?? t.common.player}</div><div className="tiny muted">{t.match.calls(Number(e.n_calls))}</div></div>
              </div>
            ))}
            {players.length > 8 && <div className="tiny muted">{t.match.andMore(players.length - 8)}</div>}
          </div>
        )}
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 10 }}>{t.match.yourCrews}</div>
          {crews.length === 0 && <div className="muted small">{t.match.noCrews} <Link to="/crews" className="lime">{t.match.makeOne}</Link>{t.match.andInvite}</div>}
          {crews.map((c) => {
            const has = cards.find((x) => x.crew_id === c.id);
            return (
              <div key={c.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, padding: "10px 0", borderBottom: "1px solid var(--raise)" }}>
                <div><b>{c.name}</b><div className="tiny muted">{has ? t.match.crewHasCard : t.match.crewNoCard}</div></div>
                {has ? <button className="btn primary" onClick={() => setSelected(has.id)}>{t.match.playIt}</button>
                     : upcoming ? <button className="btn" onClick={() => setCreatingFor(c.id)}>{t.match.openOne}</button> : null}
              </div>
            );
          })}
        </div>
      </div>
      {creatingFor !== undefined && <CreateCardDialog row={match} defaultCrew={creatingFor} onClose={() => setCreatingFor(undefined)} onDone={(cid) => { setCreatingFor(undefined); reload(); nav(`/card/${cid}`); }} />}
    </div>
  );
}
