// §5.6 The crew room: cards open this week, season table, crew-v-crew, invite code, feed
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { challengeCrew, crewScore, getMatches, getCrew, getCrewCards, getCrewInviteCode, getCrewMembers, getCrewPosts, getMarkets, leaderboard, post } from "../lib/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { ago, countdown, plural } from "../lib/format";
import { Avatar, Empty, ErrorBox, Spinner } from "../components/ui";

export default function CrewRoom() {
  const { id } = useParams();
  const nav = useNavigate();
  const now = useNow();
  const { session } = useAuth();
  const uid = session!.user.id;
  const [text, setText] = useState("");
  const [rivalCode, setRivalCode] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const crew = await getCrew(id!);
    if (!crew) throw new Error("You are not in this crew.");
    const [members, table, cards, posts, markets, us, code] = await Promise.all([
      getCrewMembers(crew.id), leaderboard("crew", crew.id), getCrewCards(crew.id), getCrewPosts(crew.id), getMarkets(), crewScore(crew.id), getCrewInviteCode(crew.id),
    ]);
    const board = await getMatches(cards.map((c) => c.match_id));   // just this crew's games
    const rival = crew.rival_crew_id ? await getCrew(crew.rival_crew_id) : null;
    const them = crew.rival_crew_id ? await crewScore(crew.rival_crew_id) : 0;
    return { crew, members, table, cards, posts, board, markets, us, them, rival, code };
  }, [id]);
  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const { crew, members, table, cards, posts, board, markets, us, them, rival, code } = data!;
  const owner = crew.owner_id === uid;
  const nameOf = (u: string) => (u === uid ? "You" : members.find((m) => m.user_id === u)?.profiles?.display_name ?? "Player");
  const send = async () => { if (!text.trim()) return; try { await post(crew.id, text); setText(""); reload(); } catch (e: any) { setErr(e.message); } };
  const setRival = async () => { try { await challengeCrew(crew.id, rivalCode); setRivalCode(""); reload(); } catch (e: any) { setErr(e.message); } };
  const openCards = cards.map((c) => ({ c, m: board.find((b) => b.match_id === c.match_id) })).filter((x) => x.m);

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="row-of" style={{ justifyContent: "space-between" }}>
            <div>
              <div className="eyebrow">{owner ? "You own this crew" : "Member"} · {plural(members.length, "member")} · {crew.mode} cards</div>
              <h1 className="display" style={{ margin: "6px 0" }}>{crew.name}</h1>
              {crew.description && <div className="muted">{crew.description}</div>}
            </div>
            <div style={{ textAlign: "right" }}>
              <div className="eyebrow">Invite code</div>
              <div className="num lime" style={{ fontSize: 34 }}>{code ?? "—"}</div>
              <button className="btn ghost tiny" onClick={() => code && navigator.clipboard?.writeText(code)}>Copy</button>
            </div>
          </div>
        </div>

        <div className="panel">
          <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 8 }}>
            <div className="eyebrow">Cards open now</div>
            <Link to="/" className="btn">Open a card from the board</Link>
          </div>
          {openCards.length === 0 && <div className="muted small">No cards open. Pick a fixture on the board and open one for {crew.name}.</div>}
          {openCards.map(({ c, m }) => {
            const filled = c.players.length, mine = c.players.some((e) => e.user_id === uid);
            const upcoming = m!.phase === "upcoming";
            return (
              <div key={c.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, padding: "12px 0", borderBottom: "1px solid var(--raise)", flexWrap: "wrap" }}>
                <div>
                  <b>{m!.home_team} v {m!.away_team}</b>
                  <div className="tiny muted">{m!.competition_name} · {markets.filter((k) => k.sport === m!.sport && (c.mode === "complex" || k.simple)).length} calls · {upcoming ? `locks ${countdown(m!.utc_date, now)}` : m!.phase === "live" ? "in play" : "settling"}</div>
                  <div className="small" style={{ marginTop: 4 }}><span className={filled < members.length ? "magenta" : "lime"}>{filled} of {members.length} filled in</span></div>
                </div>
                <div className="row-of">
                  <span className="av-stack">{c.players.slice(0, 4).map((e) => <Avatar key={e.user_id} name={nameOf(e.user_id)} me={e.user_id === uid} sm />)}</span>
                  {upcoming
                    ? <button className={"btn" + (mine ? "" : " primary")} onClick={() => nav(`/card/${c.id}`)}>{mine ? "Card in · edit" : "Fill yours"}</button>
                    : <button className="btn" onClick={() => nav(`/card/${c.id}/live`)}>Watch</button>}
                </div>
              </div>
            );
          })}
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>Season table</div>
          <div className="trow thead" style={{ gridTemplateColumns: "30px 32px minmax(0,1fr) 78px 72px 62px" }}><span>#</span><span></span><span>Player</span><span>Cards</span><span>Hit rate</span><span style={{ textAlign: "right" }}>Pts</span></div>
          {table.length === 0 && <div className="muted small" style={{ padding: "10px 0" }}>Nothing settled yet. The table fills after the first full time.</div>}
          {table.map((r, i) => (
            <div key={r.user_id} className={"trow" + (r.user_id === uid ? " me" : "")} style={{ gridTemplateColumns: "30px 32px minmax(0,1fr) 78px 72px 62px" }}>
              <span className="pos">{i + 1}</span>
              <Avatar name={r.display_name} me={r.user_id === uid} />
              <span className="small">{nameOf(r.user_id)} {i === 0 && <span className="tag solid" style={{ marginLeft: 6 }}>Leader</span>}</span>
              <span className="small muted">{r.cards} cards</span>
              <span className="small muted">{r.hit_rate}%</span>
              <span className="ptsc">{r.points}</span>
            </div>
          ))}
          {members.filter((m) => !table.some((r) => r.user_id === m.user_id)).map((m) => (
            <div key={m.user_id} className="trow" style={{ gridTemplateColumns: "30px 32px minmax(0,1fr) 78px 72px 62px" }}>
              <span className="pos">–</span><Avatar name={m.profiles?.display_name} me={m.user_id === uid} /><span className="small muted">{nameOf(m.user_id)}</span><span className="small muted">0 cards</span><span></span><span className="ptsc" style={{ color: "var(--mute)" }}>0</span>
            </div>
          ))}
        </div>
      </div>

      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 6 }}>Crew v crew</div>
          {rival ? (
            <>
              <div className="num" style={{ fontSize: 40, color: us >= them ? "var(--lime)" : "var(--magenta)" }}>{us} – {them}</div>
              <div className="small muted">{crew.name} v {rival.name} · season points on each crew's own cards.</div>
            </>
          ) : (
            <div className="small muted">No rivalry set. {owner ? "Paste another crew's invite code to challenge them." : "The owner can challenge another crew."}</div>
          )}
          {owner && (
            <div className="row-of" style={{ marginTop: 10 }}>
              <input className="input" style={{ width: 150 }} placeholder="KY-2093" value={rivalCode} onChange={(e) => setRivalCode(e.target.value.toUpperCase())} />
              <button className="btn" onClick={setRival} disabled={rivalCode.length < 6}>{rival ? "Change rival" : "Challenge"}</button>
            </div>
          )}
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>The room</div>
          <div className="row-of" style={{ marginBottom: 8 }}>
            <input className="input" placeholder="Say it to the crew…" value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === "Enter" && send()} />
            <button className="btn primary" onClick={send}>Post</button>
          </div>
          <ErrorBox msg={err} />
          {posts.length === 0 && <Empty>Quiet in here. Receipts for landed calls land here automatically.</Empty>}
          {posts.map((p) => (
            <div className="post" key={p.id}>
              <Avatar name={p.profiles?.display_name} me={p.user_id === uid} />
              <div>
                <span className="who">{nameOf(p.user_id)}</span><span className="when">{ago(p.created_at)}</span>
                {p.body && <div className="small">{p.body}</div>}
                {p.calls && <div className="receipt">Called {markets.find((k) => k.call_type === p.calls!.call_type)?.short ?? p.calls.call_type} · +{p.calls.points_awarded}</div>}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
