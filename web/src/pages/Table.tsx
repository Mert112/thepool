// §5.8 The table: overall, per crew, this week, per competition — with rank movement
import { useState } from "react";
import { getCompetitions, getMarkets, getMyCrews, leaderboard } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { Avatar, Empty, ErrorBox, Spinner } from "../components/ui";

type Scope = { id: string; label: string; scope: "overall" | "crew" | "week" | "competition"; key?: string };

export default function Table() {
  const { session } = useAuth();
  const uid = session!.user.id;
  const [sel, setSel] = useState("overall");
  const { data: meta } = useLoad(async () => {
    const [crews, comps, markets] = await Promise.all([getMyCrews(), getCompetitions(), getMarkets()]);
    const scopes: Scope[] = [{ id: "overall", label: "Overall", scope: "overall" }, ...crews.map((c) => ({ id: "crew:" + c.id, label: c.name, scope: "crew" as const, key: c.id })), { id: "week", label: "This week", scope: "week" },
      ...comps.map((c) => ({ id: "comp:" + c.code, label: c.name, scope: "competition" as const, key: c.code }))];
    return { scopes, markets };
  }, []);
  const scope = meta?.scopes.find((s) => s.id === sel) ?? { id: "overall", label: "Overall", scope: "overall" as const };
  const { data: rows, error, loading } = useLoad(async () => leaderboard(scope.scope, scope.key), [sel, !!meta]);

  // rank movement: compare to a ranking on points_prev (points as of 7 days ago)
  const prevOrder = [...(rows ?? [])].sort((a, b) => b.points_prev - a.points_prev).map((r) => r.user_id);
  const move = (r: { user_id: string }, i: number) => { const p = prevOrder.indexOf(r.user_id); return p < 0 ? 0 : p - i; };
  const short = (ct: string | null) => meta?.markets.find((k) => k.call_type === ct)?.title ?? ct ?? "";

  return (
    <div>
      <h2 className="display">The table</h2>
      <div className="row-of" style={{ marginBottom: 16 }}>
        {(meta?.scopes ?? []).map((s) => <button key={s.id} className={"pill" + (sel === s.id ? " on" : "")} onClick={() => setSel(s.id)}>{s.label}</button>)}
      </div>
      {error && <ErrorBox msg={error} />}
      {loading && !rows && <Spinner />}
      {rows && rows.length === 0 && <Empty>Nothing settled in this scope yet.</Empty>}
      {rows && rows.length > 0 && (
        <div>
          <div className="trow thead lb"><span>#</span><span></span><span>Player</span><span className="hide-s">Cards</span><span className="hide-s">Hit rate</span><span className="hide-s">Best call</span><span style={{ textAlign: "right" }}>Points</span></div>
          {rows.map((r, i) => { const mv = move(r, i); return (
            <div key={r.user_id} className={"trow lb" + (r.user_id === uid ? " me" : "")}>
              <span><span className="pos">{i + 1}</span> <span className={"move" + (mv > 0 ? " up" : mv < 0 ? " down" : "")}>{mv > 0 ? `▲${mv}` : mv < 0 ? `▼${-mv}` : "–"}</span></span>
              <Avatar name={r.display_name} me={r.user_id === uid} />
              <span className="small" style={{ fontWeight: 700 }}>{r.user_id === uid ? "You" : r.display_name ?? "Player"}</span>
              <span className="small muted hide-s">{r.cards} cards</span>
              <span className="small muted hide-s">{r.hit_rate}%</span>
              <span className="small muted hide-s">{r.best_call ? `${short(r.best_call)} · ${r.best_points}` : "—"}</span>
              <span className="ptsc">{r.points}</span>
            </div>
          ); })}
        </div>
      )}
    </div>
  );
}
