// §5.5 Live and full time: score, match log, your card with per-call state, standings, receipt.
import { Fragment, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { getCard, getCrewPosts, getEntries, getEvents, getMarkets, getMatch, getSquads, post, type Call, type Entry } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { ago, ord, plural } from "../lib/format";
import { liveClock, offered, pickText as describe } from "../lib/calls";
import { Avatar, Empty, ErrorBox, Spinner } from "../components/ui";

export default function LiveCard() {
  const { id } = useParams();
  const { session } = useAuth();
  const uid = session!.user.id;
  const [text, setText] = useState("");
  const { data, error, loading, reload } = useLoad(async () => {
    const card = await getCard(id!);
    if (!card) throw new Error("Card not found.");
    const match = await getMatch(card.match_id);
    if (!match) throw new Error("Fixture missing.");
    const [markets, entries, events, posts, squads] = await Promise.all([
      getMarkets(match.sport), getEntries(card.id), getEvents(card.match_id), card.crew_id ? getCrewPosts(card.crew_id) : Promise.resolve([]),
      getSquads(match.home_team_id, match.away_team_id),
    ]);
    return { card, match, markets: markets.filter((k) => (card.mode === "complex" || k.simple) && offered(k, match)), entries, events, posts, squads };
  }, [id]);

  // poll while live
  useEffect(() => {
    if (!data || data.match.phase !== "live") return;
    const t = setInterval(reload, 30000);
    return () => clearInterval(t);
  }, [data?.match.phase]);

  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const { card, match, markets, entries, events, posts, squads } = data!;
  if (!match) return <Empty>Fixture missing.</Empty>;
  const live = match.phase === "live", settled = match.phase === "settled";
  const mine = entries.find((e) => e.user_id === uid);
  const ranked = [...entries].sort((a, b) => b.points - a.points || b.hits - a.hits);
  const myPos = ranked.findIndex((e) => e.user_id === uid) + 1;
  const callOf = (e: Entry, ct: string) => e.calls.find((c) => c.call_type === ct);
  const pickText = (c: Call | undefined) => describe(c, match, (pid) => squads.find((p) => p.id === pid)?.name ?? events.find((e) => (e as any).player_id === pid)?.player_name ?? "");
  const soccer = match.sport === "soccer";
  const periodLabel = (i: number) => match.sport === "baseball" ? String(i + 1) : match.sport === "tennis" ? `S${i + 1}` : match.sport === "hockey" ? (i < 3 ? `P${i + 1}` : "OT") : match.sport === "mma" ? `R${i + 1}` : i < 4 ? `Q${i + 1}` : "OT";
  const periods = match.home_periods?.length && match.away_periods?.length ? Math.max(match.home_periods.length, match.away_periods.length) : 0;
  const detail = match.result_detail ?? {};
  const stateOf = (c: Call | undefined, k: { settles_on: string }) => !c ? "No pick" : c.result === "hit" ? "Hit" : c.result === "miss" ? "Missed" : c.result === "void" ? "Void" : settled ? "Missed" : k.settles_on === "event" ? "Running" : "Open";
  const best = mine ? [...mine.calls].filter((c) => c.result === "hit").sort((a, b) => (b.points_awarded ?? 0) - (a.points_awarded ?? 0))[0] : undefined;
  const bestMarket = best ? markets.find((k) => k.call_type === best.call_type) : undefined;

  const send = async () => { if (!card.crew_id || !text.trim()) return; await post(card.crew_id, text); setText(""); reload(); };

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">{match.competition_name} · {card.crew_id ? card.crews?.name : "Open card"} · {live ? <span className="magenta">{liveClock(match)}</span> : settled ? (soccer ? "Full time" : "Final") : soccer ? "Locked · waiting for kick-off" : "Locked · waiting for the start"}</div>
          {match.event_name && <div className="tiny muted" style={{ marginTop: 4 }}>{match.event_name}</div>}
          <div className="scoreline" style={{ margin: "10px 0" }}>{match.home_score ?? 0} – {match.away_score ?? 0}</div>
          <div style={{ display: "flex", justifyContent: "space-between", fontWeight: 700 }}><span>{match.home_team}</span><span>{match.away_team}</span></div>
          {soccer && match.ft_home != null && match.duration && match.duration !== "REGULAR" && <div className="tiny muted" style={{ marginTop: 6 }}>After extra time / penalties: {match.ft_home}–{match.ft_away}. Calls settle on the 90-minute score above.</div>}
          {periods > 0 && match.sport !== "mma" && (
            <div className="periods" style={{ gridTemplateColumns: `minmax(0,1fr) repeat(${periods}, 28px)` }}>
              <span className="h"></span>{Array.from({ length: periods }, (_, i) => <span key={i} className="h">{periodLabel(i)}</span>)}
              {([["home", match.home_team, match.home_periods!], ["away", match.away_team, match.away_periods!]] as const).map(([k, name, ps]) => (
                <Fragment key={k}><span className="t">{name}</span>{Array.from({ length: periods }, (_, i) => <span key={i}>{ps[i] ?? ""}</span>)}</Fragment>
              ))}
            </div>
          )}
          {settled && match.sport === "mma" && detail.method && <div className="small muted" style={{ marginTop: 8 }}>{detail.method}{detail.method !== "Decision" && detail.round ? ` · round ${detail.round}` : ""}</div>}
          {settled && match.sport === "mma" && detail.winner === "none" && <div className="small muted" style={{ marginTop: 8 }}>Draw or no contest — winner and method calls are void.</div>}
          {settled && match.sport === "tennis" && detail.retired && <div className="small muted" style={{ marginTop: 8 }}>Ended by retirement or walkover — set calls are void; the winner stands.</div>}
          {!live && !settled && match.total_line != null && <div className="tiny muted" style={{ marginTop: 8 }}>Line on this game: {match.total_line}</div>}
        </div>

        {settled && mine && (
          <div className="brag">
            <div className="eyebrow" style={{ color: "#3a3a35" }}>Your receipt</div>
            <div className="display">{bestMarket ? `I called ${bestMarket.short}` : "Nothing landed"}</div>
            <div style={{ marginTop: 6 }}>{bestMarket ? `${plural(mine.points, "point")}, ${ord(myPos)} of ${entries.length} on this card.` : "Blank card. It happens — the streak survives one."}</div>
          </div>
        )}

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{mine ? "Your card" : "You did not play this card"}</div>
          {mine && markets.map((k) => {
            const c = callOf(mine, k.call_type);
            const st = stateOf(c, k);
            const cls = st === "Hit" ? "tag hit" : st === "Missed" ? "tag miss" : "tag";
            const label = pickText(c);
            return (
              <div key={k.call_type} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) auto 60px", gap: 12, alignItems: "center", padding: "9px 0", borderBottom: "1px solid var(--raise)" }}>
                <div><div className="small" style={{ fontWeight: 700 }}>{k.title}{mine.boost_call_type === k.call_type && <span className="tag" style={{ marginLeft: 8, borderColor: "var(--magenta)", color: "var(--magenta)" }}>Boost</span>}</div><div className="tiny muted">{label}</div></div>
                <span className={cls}>{st}</span>
                <div className="num" style={{ fontSize: 17, textAlign: "right", color: st === "Hit" ? "var(--lime)" : "#4a4a44" }}>{st === "Hit" ? `+${c!.points_awarded}` : "0"}</div>
              </div>
            );
          })}
          {mine && <div style={{ display: "flex", justifyContent: "space-between", marginTop: 12 }}><span className="muted small">{settled ? "Final" : "Banked so far"}</span><span className="num lime" style={{ fontSize: 28 }}>{mine.points}</span></div>}
          {mine && live && <div className="tiny muted" style={{ marginTop: 6 }}>{soccer ? "Result calls (winner, draw, scoreline) stay open until full time even if they look right now." : "Result calls stay open until the final result. Player calls land the moment they happen."}</div>}
        </div>

        {soccer && <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>Match log</div>
          {events.length === 0 && <div className="muted small">Nothing yet.</div>}
          {events.map((e) => (
            <div className="log" key={e.id}>
              <div className="min">{e.minute}{e.injury_time ? `+${e.injury_time}` : ""}'</div>
              <div>
                <div className="small" style={{ fontWeight: 700 }}>{e.type === "goal" ? (e.own_goal ? "Own goal" : "Goal") : e.type === "yellow" ? "Yellow" : e.type === "yellow_red" ? "Second yellow — off" : "Red"} — {e.player_name}</div>
                <div className="tiny muted">{e.assist_name ? `Assist ${e.assist_name}. ` : ""}{!e.counts ? "After 90 — does not count." : ""}</div>
              </div>
            </div>
          ))}
        </div>}
      </div>

      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{settled ? "Final standings" : "Standings"} · {entries.length}</div>
          {ranked.slice(0, 12).map((e, i) => (
            <div key={e.id} style={{ display: "flex", alignItems: "center", gap: 12, padding: "9px 12px", borderRadius: 10, background: e.user_id === uid ? "var(--raise)" : "transparent" }}>
              <span className="pos">{i + 1}</span>
              <Avatar name={e.profiles?.display_name} me={e.user_id === uid} />
              <span style={{ flex: 1 }} className="small">{e.user_id === uid ? "You" : e.profiles?.display_name ?? "Player"}<span className="tiny muted" style={{ marginLeft: 8 }}>{e.hits} of {e.calls.length}</span></span>
              <span className="num lime" style={{ fontSize: 20 }}>{e.points}</span>
            </div>
          ))}
        </div>
        {card.crew_id && (
          <div className="panel">
            <div className="eyebrow" style={{ marginBottom: 8 }}>{card.crews?.name} room · <Link to={`/crews/${card.crew_id}`} className="lime">open</Link></div>
            <div className="row-of" style={{ marginBottom: 8 }}>
              <input className="input" placeholder="Say it to the crew…" value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === "Enter" && send()} />
              <button className="btn primary" onClick={send}>Post</button>
            </div>
            {posts.slice(0, 10).map((p) => (
              <div className="post" key={p.id}>
                <Avatar name={p.profiles?.display_name} me={p.user_id === uid} sm />
                <div><span className="who">{p.user_id === uid ? "You" : p.profiles?.display_name}</span><span className="when">{ago(p.created_at)}</span>
                  {p.body && <div className="small">{p.body}</div>}
                  {p.calls && <div className="receipt">Called {markets.find((k) => k.call_type === p.calls!.call_type)?.short ?? p.calls.call_type} · +{p.calls.points_awarded}</div>}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
