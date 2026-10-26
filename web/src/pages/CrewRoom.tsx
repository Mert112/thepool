// §5.6 The crew room: cards open this week, season table, crew-v-crew, invite code, feed
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { challengeCrew, crewScore, getMatches, getCrew, getCrewCards, getCrewInviteCode, getCrewMembers, getCrewPosts, getMarkets, leaderboard, post } from "../lib/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { useI18n } from "../i18n";
import { Avatar, Empty, ErrorBox, Spinner } from "../components/ui";
import { marketShort } from "../lib/calls";

export default function CrewRoom() {
  const { id } = useParams();
  const nav = useNavigate();
  const now = useNow();
  const { session } = useAuth();
  const { t, fmt } = useI18n();
  const uid = session!.user.id;
  const [text, setText] = useState("");
  const [rivalCode, setRivalCode] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const crew = await getCrew(id!);
    if (!crew) throw new Error(t.crewRoom.notIn);
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
  const nameOf = (u: string) => (u === uid ? t.common.you : members.find((m) => m.user_id === u)?.profiles?.display_name ?? t.common.player);
  const send = async () => { if (!text.trim()) return; try { await post(crew.id, text); setText(""); reload(); } catch (e: any) { setErr(e.message); } };
  const setRival = async () => { try { await challengeCrew(crew.id, rivalCode); setRivalCode(""); reload(); } catch (e: any) { setErr(e.message); } };
  const openCards = cards.map((c) => ({ c, m: board.find((b) => b.match_id === c.match_id) })).filter((x) => x.m);

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="row-of" style={{ justifyContent: "space-between" }}>
            <div>
              <div className="eyebrow">{owner ? t.crewRoom.youOwn : t.crewRoom.member} · {t.crews.members(members.length)} · {t.crews.mode[crew.mode]}</div>
              <h1 className="display" style={{ margin: "6px 0" }}>{crew.name}</h1>
              {crew.description && <div className="muted">{crew.description}</div>}
            </div>
            <div style={{ textAlign: "right" }}>
              <div className="eyebrow">{t.crewRoom.inviteCode}</div>
              <div className="num lime" style={{ fontSize: 34 }}>{code ?? t.common.dash}</div>
              <button className="btn ghost tiny" onClick={() => code && navigator.clipboard?.writeText(code)}>{t.common.copy}</button>
            </div>
          </div>
        </div>

        <div className="panel">
          <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 8 }}>
            <div className="eyebrow">{t.crewRoom.cardsOpenNow}</div>
            <Link to="/" className="btn">{t.crewRoom.openFromBoard}</Link>
          </div>
          {openCards.length === 0 && <div className="muted small">{t.crewRoom.noCards(crew.name)}</div>}
          {openCards.map(({ c, m }) => {
            const filled = c.players.length, mine = c.players.some((e) => e.user_id === uid);
            const upcoming = m!.phase === "upcoming";
            return (
              <div key={c.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, padding: "12px 0", borderBottom: "1px solid var(--raise)", flexWrap: "wrap" }}>
                <div>
                  <b>{m!.home_team} {t.common.v} {m!.away_team}</b>
                  <div className="tiny muted">{m!.competition_name} · {t.crewRoom.calls(markets.filter((k) => c.mode === "complex" || k.simple).length)} · {upcoming ? t.crewRoom.locks(fmt.countdown(m!.utc_date, now)) : m!.phase === "live" ? t.crewRoom.inPlay : t.crewRoom.settling}</div>
                  <div className="small" style={{ marginTop: 4 }}><span className={filled < members.length ? "magenta" : "lime"}>{t.crewRoom.filled(filled, members.length)}</span></div>
                </div>
                <div className="row-of">
                  <span className="av-stack">{c.players.slice(0, 4).map((e) => <Avatar key={e.user_id} name={nameOf(e.user_id)} me={e.user_id === uid} sm />)}</span>
                  {upcoming
                    ? <button className={"btn" + (mine ? "" : " primary")} onClick={() => nav(`/card/${c.id}`)}>{mine ? t.crewRoom.cardInEdit : t.crewRoom.fillYours}</button>
                    : <button className="btn" onClick={() => nav(`/card/${c.id}/live`)}>{t.crewRoom.watch}</button>}
                </div>
              </div>
            );
          })}
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{t.crewRoom.seasonTable}</div>
          <div className="trow thead lb crew"><span>#</span><span></span><span>{t.table.colPlayer}</span><span className="hide-s">{t.table.colCards}</span><span className="hide-s">{t.table.colHitRate}</span><span style={{ textAlign: "right" }}>{t.common.pts}</span></div>
          {table.length === 0 && <div className="muted small" style={{ padding: "10px 0" }}>{t.crewRoom.tableEmpty}</div>}
          {table.map((r, i) => (
            <div key={r.user_id} className={"trow lb crew" + (r.user_id === uid ? " me" : "")}>
              <span className="pos">{i + 1}</span>
              <Avatar name={r.display_name} icon={r.icon} me={false} />
              <span className="small">{nameOf(r.user_id)} {i === 0 && <span className="tag solid" style={{ marginLeft: 6 }}>{t.crewRoom.leader}</span>}</span>
              <span className="small muted hide-s">{t.table.cards(r.cards)}</span>
              <span className="small muted hide-s">{r.hit_rate}%</span>
              <span className="ptsc">{fmt.pts(Number(r.points))}</span>
            </div>
          ))}
          {members.filter((m) => !table.some((r) => r.user_id === m.user_id)).map((m) => (
            <div key={m.user_id} className="trow lb crew">
              <span className="pos">–</span><Avatar name={m.profiles?.display_name} me={m.user_id === uid} /><span className="small muted">{nameOf(m.user_id)}</span><span className="small muted hide-s">{t.crewRoom.noCards0}</span><span className="hide-s"></span><span className="ptsc" style={{ color: "var(--mute)" }}>0</span>
            </div>
          ))}
        </div>
      </div>

      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 6 }}>{t.crewRoom.crewVCrew}</div>
          {rival ? (
            <>
              <div className="num" style={{ fontSize: 40, color: us >= them ? "var(--lime)" : "var(--magenta)" }}>{fmt.pts(us)} – {fmt.pts(them)}</div>
              <div className="small muted">{t.crewRoom.rivalLine(crew.name, rival.name)}</div>
            </>
          ) : (
            <div className="small muted">{owner ? t.crewRoom.noRivalOwner : t.crewRoom.noRivalMember}</div>
          )}
          {owner && (
            <div className="row-of" style={{ marginTop: 10 }}>
              <input className="input" style={{ width: 150 }} placeholder={t.crewRoom.rivalPlaceholder} value={rivalCode} onChange={(e) => setRivalCode(e.target.value.toUpperCase())} />
              <button className="btn" onClick={setRival} disabled={rivalCode.length < 6}>{rival ? t.crewRoom.changeRival : t.crewRoom.challenge}</button>
            </div>
          )}
        </div>

        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{t.crewRoom.theRoom}</div>
          <div className="row-of" style={{ marginBottom: 8 }}>
            <input className="input" placeholder={t.live.sayIt} value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === "Enter" && send()} />
            <button className="btn primary" onClick={send}>{t.common.post}</button>
          </div>
          <ErrorBox msg={err} />
          {posts.length === 0 && <Empty>{t.crewRoom.quiet}</Empty>}
          {posts.map((p) => {
            const k = p.calls ? markets.find((x) => x.call_type === p.calls!.call_type) : undefined;
            return (
              <div className="post" key={p.id}>
                <Avatar name={p.profiles?.display_name} me={p.user_id === uid} />
                <div>
                  <span className="who">{nameOf(p.user_id)}</span><span className="when">{fmt.ago(p.created_at)}</span>
                  {p.body && <div className="small">{p.body}</div>}
                  {p.calls && <div className="receipt">{t.crewRoom.called(k ? marketShort(k, t) : p.calls.call_type, fmt.pts(Number(p.calls.points_awarded)))}</div>}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
