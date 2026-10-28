// §5.5 Live and full time: score, match log, your card with per-call state, standings, receipt.
import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { getCard, getEntries, getEvents, getMarkets, getSquads, type Call, type Entry } from "../features/card/api";
import { getCrewPosts, post } from "../features/crews/api";
import { getMatch } from "../features/board/api";
import { useAuth, useLoad } from "../lib/auth";
import { useI18n } from "../lib/i18n";
import { labelOf, liveClock, marketShort, marketTitle, offered, partsOf } from "../features/card/calls";
import { Avatar, Empty, ErrorBox, Spinner } from "../components/ui";

export default function LiveCard() {
  const { id } = useParams();
  const { session } = useAuth();
  const { t, fmt } = useI18n();
  const uid = session!.user.id;
  const [text, setText] = useState("");
  const { data, error, loading, reload } = useLoad(async () => {
    const card = await getCard(id!);
    if (!card) throw new Error(t.live.noCard);
    const match = await getMatch(card.match_id);
    if (!match) throw new Error(t.live.noFixture);
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
    const tm = setInterval(reload, 30000);
    return () => clearInterval(tm);
  }, [data?.match.phase]);

  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const { card, match, markets, entries, events, posts, squads } = data!;
  if (!match) return <Empty>{t.live.noFixture}</Empty>;
  const live = match.phase === "live", settled = match.phase === "settled";
  const mine = entries.find((e) => e.user_id === uid);
  const ranked = [...entries].sort((a, b) => b.points - a.points || b.hits - a.hits);
  const myPos = ranked.findIndex((e) => e.user_id === uid) + 1;
  const callOf = (e: Entry, ct: string) => e.calls.find((c) => c.call_type === ct);
  const playerName = (pid: number | null | undefined) =>
    squads.find((p) => p.id === pid)?.name ?? events.find((e) => (e as any).player_id === pid)?.player_name ?? "";
  const pickText = (c: Call | undefined) => (c ? labelOf(partsOf(c, match, playerName), t) : t.live.state.none);
  type St = "none" | "hit" | "miss" | "void" | "running" | "open";
  const stateOf = (c: Call | undefined, k: { settles_on: string }): St =>
    !c ? "none" : c.result === "hit" ? "hit" : c.result === "miss" ? "miss" : c.result === "void" ? "void"
    : settled ? "miss" : k.settles_on === "event" ? "running" : "open";
  const myStaked = mine ? mine.calls.reduce((s, c) => s + (c.staked ? c.stake ?? 0 : 0), 0) : 0;
  const best = mine ? [...mine.calls].filter((c) => c.result === "hit").sort((a, b) => (b.points_awarded ?? 0) - (a.points_awarded ?? 0))[0] : undefined;
  const bestMarket = best ? markets.find((k) => k.call_type === best.call_type) : undefined;

  const send = async () => { if (!card.crew_id || !text.trim()) return; await post(card.crew_id, text); setText(""); reload(); };

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">{match.competition_name} · {card.crew_id ? card.crews?.name : t.live.openCard} · {live ? <span className="magenta"><span className="live-dot" />{liveClock(match, t)}</span> : settled ? t.live.fullTime : t.live.waiting}</div>
          {match.event_name && <div className="tiny muted" style={{ marginTop: 4 }}>{match.event_name}</div>}
          <div className="scoreline" key={`${match.home_score}-${match.away_score}`} style={{ margin: "10px 0" }}>{match.home_score ?? 0} – {match.away_score ?? 0}</div>
          <div style={{ display: "flex", justifyContent: "space-between", fontWeight: 700 }}><span>{match.home_team}</span><span>{match.away_team}</span></div>
          {match.ft_home != null && match.duration && match.duration !== "REGULAR" && <div className="tiny muted" style={{ marginTop: 6 }}>{t.live.afterExtra(match.ft_home, match.ft_away!)}</div>}
          {!live && !settled && match.total_line != null && <div className="tiny muted" style={{ marginTop: 8 }}>{t.live.goalsLine(fmt.num(match.total_line))}</div>}
        </div>

        {settled && mine && (
          <div className="brag">
            <div className="eyebrow" style={{ color: "#3a3a35" }}>{t.live.receipt}</div>
            <div className="display">{bestMarket ? t.live.iCalled(marketShort(bestMarket, t)) : t.live.nothingLanded}</div>
            <div style={{ marginTop: 6 }}>{bestMarket ? t.live.receiptLine(fmt.signedPts(mine.points), fmt.ord(myPos), entries.length) : t.live.blankCard(fmt.pts(myStaked))}</div>
          </div>
        )}

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{mine ? t.live.yourCard : t.live.didNotPlay}</div>
          {mine && markets.map((k) => {
            const c = callOf(mine, k.call_type);
            const st = stateOf(c, k);
            const cls = st === "hit" ? "tag hit" : st === "miss" ? "tag miss" : "tag";
            return (
              <div key={k.call_type} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) auto 60px", gap: 12, alignItems: "center", padding: "9px 0", borderBottom: "1px solid var(--raise)" }}>
                <div>
                  <div className="small" style={{ fontWeight: 700 }}>{marketTitle(k, t)}</div>
                  <div className="tiny muted">{pickText(c)}{c ? ` · ${t.live.staked(fmt.pts(c.stake))}` : ""}</div>
                </div>
                <span className={cls}>{t.live.state[st]}</span>
                <div className="num" style={{ fontSize: 17, textAlign: "right", color: st === "hit" ? "var(--lime)" : "#4a4a44" }} title={c && st !== "hit" && st !== "miss" && st !== "void" ? t.live.returnsIfLands : undefined}>
                  {st === "hit" ? (c!.points_awarded ? `+${fmt.pts(c!.points_awarded)}` : <span className="faint">{t.live.potPending}</span>)
                    : st === "void" ? <span className="faint">{c!.staked ? t.live.back(fmt.pts(c!.stake)) : t.common.dash}</span>
                    : "0"}
                </div>
              </div>
            );
          })}
          {mine && (
            <div style={{ marginTop: 12 }}>
              <div style={{ display: "flex", justifyContent: "space-between" }}><span className="muted small">{t.live.stakedAtKickoff}</span><span className="num" style={{ fontSize: 20, color: "var(--soft)" }}>{myStaked ? fmt.pts(myStaked) : t.common.dash}</span></div>
              <div style={{ display: "flex", justifyContent: "space-between", marginTop: 4 }}>
                <span className="muted small">{settled ? t.live.cardAllIn : t.live.cardSoFar}</span>
                <span className="num" style={{ fontSize: 28, color: mine.points >= 0 ? "var(--lime)" : "var(--magenta)" }}>{fmt.signedPts(mine.points)}</span>
              </div>
            </div>
          )}
          {mine && live && <div className="tiny muted" style={{ marginTop: 6 }}>{t.live.liveNote}</div>}
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{t.live.matchLog}</div>
          {events.length === 0 && <div className="muted small">{t.common.nothingYet}</div>}
          {events.map((e) => (
            <div className="log" key={e.id}>
              <div className="min">{e.minute}{e.injury_time ? `+${e.injury_time}` : ""}'</div>
              <div>
                <div className="small" style={{ fontWeight: 700 }}>{e.type === "goal" ? (e.own_goal ? t.live.event.ownGoal : t.live.event.goal) : e.type === "yellow" ? t.live.event.yellow : e.type === "yellow_red" ? t.live.event.secondYellow : t.live.event.red} — {e.player_name}</div>
                <div className="tiny muted">{e.assist_name ? t.live.assistBy(e.assist_name) : ""}{!e.counts ? t.live.after90 : ""}</div>
              </div>
            </div>
          ))}
        </div>
      </div>

      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{settled ? t.live.finalStandings : t.live.standings} · {entries.length}</div>
          {ranked.slice(0, 12).map((e, i) => (
            <div key={e.id} style={{ display: "flex", alignItems: "center", gap: 12, padding: "9px 12px", borderRadius: 10, background: e.user_id === uid ? "var(--raise)" : "transparent" }}>
              <span className="pos">{i + 1}</span>
              <Avatar name={e.profiles?.display_name} icon={e.profiles?.icon} pic={e.profiles?.avatar_path} me={!e.profiles?.icon && e.user_id === uid} />
              <span style={{ flex: 1 }} className="small">{e.user_id === uid ? t.common.you : e.profiles?.display_name ?? t.common.player}<span className="tiny muted" style={{ marginLeft: 8 }}>{t.live.ofCalls(e.hits, e.calls.length)}</span></span>
              <span className="num" style={{ fontSize: 20, color: e.points >= 0 ? "var(--lime)" : "var(--magenta)" }}>{fmt.signedPts(e.points)}</span>
            </div>
          ))}
        </div>
        {card.crew_id && (
          <div className="panel">
            <div className="eyebrow" style={{ marginBottom: 8 }}>{t.live.room(card.crews?.name ?? "")} · <Link to={`/crews/${card.crew_id}`} className="lime">{t.common.open}</Link></div>
            <div className="row-of" style={{ marginBottom: 8 }}>
              <input className="input" placeholder={t.live.sayIt} value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === "Enter" && send()} />
              <button className="btn primary" onClick={send}>{t.common.post}</button>
            </div>
            {posts.slice(0, 10).map((p) => (
              <div className="post" key={p.id}>
                <Avatar name={p.profiles?.display_name} icon={p.profiles?.icon} pic={p.profiles?.avatar_path} me={!p.profiles?.icon && p.user_id === uid} sm />
                <div><span className="who">{p.user_id === uid ? t.common.you : p.profiles?.display_name}</span><span className="when">{fmt.ago(p.created_at)}</span>
                  {p.body && <div className="small">{p.body}</div>}
                  {p.calls && <div className="receipt">{t.live.called(markets.find((k) => k.call_type === p.calls!.call_type) ? marketShort(markets.find((k) => k.call_type === p.calls!.call_type)!, t) : p.calls.call_type, fmt.pts(Number(p.calls.points_awarded)))}</div>}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
