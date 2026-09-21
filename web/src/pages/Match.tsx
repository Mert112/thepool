// §5.3 The match page: everything about a card before you play it
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { getCardPlayers, getCardsForMatch, getCrowd, getMarkets, getMatch, getMyCrews, getMyEntry, type Card } from "../lib/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { countdown, fmtWhen, plural, soon } from "../lib/format";
import { Avatar, Empty, ErrorBox, Pips, Spinner } from "../components/ui";
import { CreateCardDialog } from "./Board";
import { offered } from "../lib/calls";

export default function Match() {
  const { id } = useParams();
  const matchId = Number(id);
  const nav = useNavigate();
  const now = useNow();
  const { session } = useAuth();
  const [creatingFor, setCreatingFor] = useState<string | null | undefined>(undefined); // undefined = closed, null = public
  const [selected, setSelected] = useState<string | null>(null);

  const { data, error, loading, reload } = useLoad(async () => {
    const [match, cards, crews] = await Promise.all([getMatch(matchId), getCardsForMatch(matchId), getMyCrews()]);
    const markets = match ? (await getMarkets(match.sport)).filter((k) => offered(k, match)) : [];
    const cardId = selected ?? cards.find((c) => c.crew_id === null)?.id ?? cards[0]?.id ?? null;
    const [players, crowd, mine] = cardId ? await Promise.all([getCardPlayers(cardId), getCrowd(cardId), getMyEntry(cardId, session!.user.id)]) : [[], [], null];
    return { match, cards, crews, markets, cardId, players, crowd, mine };
  }, [matchId, selected]);

  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const { match, cards, crews, markets, cardId, players, crowd, mine } = data!;
  if (!match) return <Empty>Unknown fixture.</Empty>;
  const card: Card | undefined = cards.find((c) => c.id === cardId);
  const complex = card?.mode === "complex";
  const shown = markets.filter((k) => complex || k.simple);
  const upcoming = match.phase === "upcoming" && new Date(match.utc_date).getTime() > now;   // closed at the start, live data or not
  const topCrowd = (ct: string) => crowd.filter((c) => c.call_type === ct).sort((a, b) => b.n - a.n)[0];

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">{match.sport_name} · {match.competition_name} · {fmtWhen(match.utc_date)}</div>
          {match.event_name && <div className="tiny muted" style={{ marginTop: 4 }}>{match.event_name}</div>}
          <h1 className="display" style={{ margin: "8px 0 14px" }}>{match.home_team} <span className="faint">v</span> {match.away_team}</h1>
          {/* every card on this game, plus a public one if nobody has opened it yet (a crew card must not block it) */}
          {(cards.length > 1 || (cards.length > 0 && upcoming && !cards.some((c) => c.crew_id === null))) && (
            <div className="row-of" style={{ marginBottom: 12 }}>
              {cards.map((c) => <button key={c.id} className={"pill" + (c.id === cardId ? " on" : "")} onClick={() => setSelected(c.id)}>{c.crew_id ? c.crews?.name : "Open card"}</button>)}
              {upcoming && !cards.some((c) => c.crew_id === null) && <button className="pill" onClick={() => setCreatingFor(null)}>+ Card for everyone</button>}
            </div>
          )}
          {card ? (
            <>
              <div className="row-of" style={{ marginBottom: 12 }}>
                <span className="badge">{complex ? `Complex card · ${shown.length} calls · ${shown.reduce((s, k) => s + k.points, 0)} max` : `Simple card · ${shown.length} calls · ${shown.reduce((s, k) => s + k.points, 0)} max`}</span>
                <span className="small muted">{card.crew_id ? `${card.crews?.name} only` : "Open card · anyone can join"}</span>
                <span className="small num" style={{ color: soon(match.utc_date, now) ? "var(--magenta)" : "var(--soft)" }}>
                  {upcoming ? `Locks in ${countdown(match.utc_date, now)}` : match.phase === "live" ? "In play" : "Settled"}
                </span>
              </div>
              <p className="muted">
                {players.length ? `${players.length.toLocaleString()} ${players.length === 1 ? "card is" : "cards are"} already in on this match.` : "Nobody has filled a card yet — be the first."} Same calls for everyone; the biggest total takes it, level totals share the top. Nothing is staked but the argument.
              </p>
              <div className="row-of">
                {upcoming && <button className="btn big" onClick={() => nav(`/card/${card.id}`)}>{mine ? "Edit your card" : "Fill the card"}</button>}
                {!upcoming && <button className="btn big" onClick={() => nav(`/card/${card.id}/live`)}>{match.phase === "live" ? "Watch it live" : "See the recap"}</button>}
                {mine && upcoming && <span className="tag hit">Card in · {mine.calls.length} of {shown.length}</span>}
              </div>
            </>
          ) : (
            <div>
              <p className="muted">No card on this fixture yet.</p>
              {upcoming && <button className="btn big" onClick={() => setCreatingFor(null)}>Open the first card</button>}
            </div>
          )}
        </div>

        {card && (
          <div className="panel">
            <div className="eyebrow" style={{ marginBottom: 12 }}>The scoring · what the pool is calling</div>
            {shown.map((k) => {
              const t = topCrowd(k.call_type);
              return (
                <div key={k.call_type} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) 40px minmax(0,1.2fr)", gap: 14, alignItems: "center", padding: "10px 0", borderBottom: "1px solid var(--raise)" }}>
                  <div><b>{k.title}</b><div className="tiny muted">{k.description}</div></div>
                  <div className="num lime" style={{ fontSize: 22 }}>{k.points}</div>
                  <div className="small muted">{t ? <span>{t.pct}% · {t.label}</span> : <span className="faint">no calls yet</span>}<Pips n={Math.min(8, k.points)} /></div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      <div className="stack">
        {card && (
          <div className="panel">
            <div className="eyebrow" style={{ marginBottom: 10 }}>Already playing · {players.length}</div>
            {players.length === 0 && <div className="muted small">Nobody yet.</div>}
            {players.slice(0, 8).map((e) => (
              <div key={e.user_id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 0" }}>
                <Avatar name={e.display_name} me={e.user_id === session?.user.id} />
                <div style={{ flex: 1 }}><div className="small" style={{ fontWeight: 700 }}>{e.user_id === session?.user.id ? "You" : e.display_name ?? "Player"}</div><div className="tiny muted">{plural(Number(e.n_calls), "call")}</div></div>
              </div>
            ))}
            {players.length > 8 && <div className="tiny muted">and {players.length - 8} more</div>}
          </div>
        )}
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 10 }}>Your crews on this match</div>
          {crews.length === 0 && <div className="muted small">You are in no crew yet. <Link to="/crews" className="lime">Make one</Link> and invite the group chat.</div>}
          {crews.map((c) => {
            const has = cards.find((x) => x.crew_id === c.id);
            return (
              <div key={c.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, padding: "10px 0", borderBottom: "1px solid var(--raise)" }}>
                <div><b>{c.name}</b><div className="tiny muted">{has ? "card already open" : "no card yet"}</div></div>
                {has ? <button className="btn primary" onClick={() => setSelected(has.id)}>Play it</button>
                     : upcoming ? <button className="btn" onClick={() => setCreatingFor(c.id)}>Open one</button> : null}
              </div>
            );
          })}
        </div>
      </div>
      {creatingFor !== undefined && <CreateCardDialog row={match} defaultCrew={creatingFor} onClose={() => setCreatingFor(undefined)} onDone={(cid) => { setCreatingFor(undefined); reload(); nav(`/card/${cid}`); }} />}
    </div>
  );
}
