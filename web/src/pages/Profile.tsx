// §5.8 Profile: season points, overall rank, cards, hit rate, streak, points by competition, recent cards
import { Link } from "react-router-dom";
import { myStats } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { fmtDay, ord } from "../lib/format";
import { Bar, ErrorBox, Spinner } from "../components/ui";

export default function Profile() {
  const { profile } = useAuth();
  const { data: s, error, loading } = useLoad(myStats, []);
  if (loading && !s) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const max = Math.max(1, ...s!.competitions.map((c) => c.points));
  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">You</div>
          <h1 className="display" style={{ margin: "6px 0 10px" }}>{profile?.display_name ?? "Player"}</h1>
          <div className="muted">{s!.rank ? `${ord(s!.rank)} of ${s!.players} overall.` : "No settled cards yet — the first full time puts you on the table."} <Link to="/settings" className="lime small">Settings</Link></div>
          <div className="tiles" style={{ marginTop: 16 }}>
            <div className="tile"><div className="v">{s!.points}</div><div className="k">Points</div></div>
            <div className="tile"><div className="v">{s!.rank ? ord(s!.rank) : "–"}</div><div className="k">Overall</div></div>
            <div className="tile"><div className="v">{s!.cards}</div><div className="k">Cards</div></div>
            <div className="tile"><div className="v">{s!.hit_rate}%</div><div className="k">Hit rate</div></div>
          </div>
        </div>
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>Recent cards</div>
          {s!.recent.length === 0 && <div className="muted small">None yet.</div>}
          {s!.recent.map((r) => (
            <Link to={`/match/${r.match_id}`} key={r.match_id + r.mode} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) auto 50px", gap: 12, alignItems: "center", padding: "10px 0", borderBottom: "1px solid var(--raise)" }}>
              <div><div className="small" style={{ fontWeight: 700 }}>{r.home} {r.home_score} – {r.away_score} {r.away}</div><div className="tiny muted">{r.competition_code} · {fmtDay(r.utc_date)} · {r.hits} landed</div></div>
              <span className={"tag" + (r.hits > 0 ? " hit" : "")}>{r.hits > 0 ? "Hit" : "Miss"}</span>
              <span className="num" style={{ fontSize: 19, textAlign: "right", color: r.points > 0 ? "var(--lime)" : "#4a4a44" }}>{r.points > 0 ? `+${r.points}` : "0"}</span>
            </Link>
          ))}
        </div>
      </div>
      <div className="stack">
        <div className="panel">
          <div className="eyebrow">Matchday streak</div>
          <div className="num lime" style={{ fontSize: 56, lineHeight: 1 }}>{s!.streak}</div>
          <div className="small muted">Consecutive matchdays with at least one call landed. Miss a whole matchday and it resets. Loss aversion, no punishment beyond the reset.</div>
        </div>
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>Points by competition</div>
          {s!.competitions.length === 0 && <div className="muted small">Play a card in a competition to appear on its table.</div>}
          {s!.competitions.map((c) => (
            <div key={c.code} style={{ padding: "8px 0" }}>
              <div className="small" style={{ display: "flex", justifyContent: "space-between" }}><span>{c.name} <span className="muted">· {ord(c.rank)}</span></span><span className="lime">{c.points}</span></div>
              <Bar pct={c.points / max * 100} />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
