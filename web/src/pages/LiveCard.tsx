// §5.5 Live and full time: score, match log, your card with per-call state, standings, receipt.
import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { getCard, getCrewPosts, getEntries, getEvents, getMarkets, getMatch, getSquads, post, type Call, type Entry } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { ago, ord, plural } from "../lib/format";
import { liveClock, offered, pickText as describe, pts, signedPts } from "../lib/calls";
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
      getMarkets(), getEntries(card.id), getEvents(card.match_id), card.crew_id ? getCrewPosts(card.crew_id) : Promise.resolve([]),
      getSquads(match.home_team_id, match.away_team_id),
    ]);
    // the card's markets: those on offer, plus any someone actually called
    const called = new Set(entries.flatMap((e) => e.calls.map((c) => c.call_type)));
    return { card, match, markets: markets.filter((k) => (card.mode === "complex" || k.simple) && (offered(k, match) || called.has(k.call_type))), entries, events, posts, squads };
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
  const stateOf = (c: Call | undefined, k: { settles_on: string }) => !c ? "No pick" : c.result === "hit" ? "Hit" : c.result === "miss" ? "Missed" : c.result === "void" ? "Void" : settled ? "Missed" : k.settles_on === "event" ? "Running" : "Open";
  const myStaked = mine ? mine.calls.reduce((s, c) => s + (c.staked ? c.stake ?? 0 : 0), 0) : 0;
  const best = mine ? [...mine.calls].filter((c) => c.result === "hit").sort((a, b) => (b.points_awarded ?? 0) - (a.points_awarded ?? 0))[0] : undefined;
  const bestMarket = best ? markets.find((k) => k.call_type === best.call_type) : undefined;

  const send = async () => { if (!card.crew_id || !text.trim()) return; await post(card.crew_id, text); setText(""); reload(); };

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">{match.competition_name} · {card.crew_id ? card.crews?.name : "Open card"} · {live ? <span className="magenta"><span className="live-dot" />{liveClock(match)}</span> : settled ? "Full time" : "Locked · waiting for kick-off"}</div>
          {match.event_name && <div className="tiny muted" style={{ marginTop: 4 }}>{match.event_name}</div>}
          <div className="scoreline" key={`${match.home_score}-${match.away_score}`} style={{ margin: "10px 0" }}>{match.home_score ?? 0} – {match.away_score ?? 0}</div>
          <div style={{ display: "flex", justifyContent: "space-between", fontWeight: 700 }}><span>{match.home_team}</span><span>{match.away_team}</span></div>
          {match.ft_home != null && match.duration && match.duration !== "REGULAR" && <div className="tiny muted" style={{ marginTop: 6 }}>After extra time / penalties: {match.ft_home}–{match.ft_away}. Calls settle on the 90-minute score above.</div>}
          {!live && !settled && match.total_line != null && <div className="tiny muted" style={{ marginTop: 8 }}>Goals line on this match: {match.total_line}</div>}
        </div>

        {settled && mine && (
          <div className="brag">
            <div className="eyebrow" style={{ color: "#3a3a35" }}>Your receipt</div>
            <div className="display">{bestMarket ? `I called ${bestMarket.short}` : "Nothing landed"}</div>
            <div style={{ marginTop: 6 }}>{bestMarket ? `${signedPts(mine.points)} points, ${ord(myPos)} of ${entries.length} on this card.` : `Blank card — ${pts(myStaked)} points gone. It happens.`}</div>
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
                <div>
                  <div className="small" style={{ fontWeight: 700 }}>{k.title}</div>
                  <div className="tiny muted">{label}{c ? ` · ${c.stake} staked` : ""}</div>
                </div>
                <span className={cls}>{st}</span>
                <div className="num" style={{ fontSize: 17, textAlign: "right", color: st === "Hit" ? "var(--lime)" : "#4a4a44" }} title={c && st !== "Hit" && st !== "Missed" && st !== "Void" ? "returns this if it lands" : undefined}>
                  {st === "Hit" ? (c!.points_awarded ? `+${pts(c!.points_awarded)}` : <span className="faint">pot pending</span>)
                    : st === "Void" ? <span className="faint">{c!.staked ? `${c!.stake} back` : "—"}</span>
                    : "0"}
                </div>
              </div>
            );
          })}
          {mine && (
            <div style={{ marginTop: 12 }}>
              <div style={{ display: "flex", justifyContent: "space-between" }}><span className="muted small">Staked at kick-off</span><span className="num" style={{ fontSize: 20, color: "var(--soft)" }}>{myStaked || "—"}</span></div>
              <div style={{ display: "flex", justifyContent: "space-between", marginTop: 4 }}>
                <span className="muted small">{settled ? "This card, all in" : "This card so far"}</span>
                <span className="num" style={{ fontSize: 28, color: mine.points >= 0 ? "var(--lime)" : "var(--magenta)" }}>{signedPts(mine.points)}</span>
              </div>
            </div>
          )}
          {mine && live && <div className="tiny muted" style={{ marginTop: 6 }}>Result calls stay open until full time even if they look right now, and no pot pays until it closes — what a landed call is worth depends on who else landed it.</div>}
        </div>

        <div className="panel">
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
        </div>
      </div>

      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{settled ? "Final standings" : "Standings"} · {entries.length}</div>
          {ranked.slice(0, 12).map((e, i) => (
            <div key={e.id} style={{ display: "flex", alignItems: "center", gap: 12, padding: "9px 12px", borderRadius: 10, background: e.user_id === uid ? "var(--raise)" : "transparent" }}>
              <span className="pos">{i + 1}</span>
              <Avatar name={e.profiles?.display_name} icon={e.profiles?.icon} me={!e.profiles?.icon && e.user_id === uid} />
              <span style={{ flex: 1 }} className="small">{e.user_id === uid ? "You" : e.profiles?.display_name ?? "Player"}<span className="tiny muted" style={{ marginLeft: 8 }}>{e.hits} of {e.calls.length}</span></span>
              <span className="num" style={{ fontSize: 20, color: e.points >= 0 ? "var(--lime)" : "var(--magenta)" }}>{signedPts(e.points)}</span>
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
                <Avatar name={p.profiles?.display_name} icon={p.profiles?.icon} me={!p.profiles?.icon && p.user_id === uid} sm />
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
