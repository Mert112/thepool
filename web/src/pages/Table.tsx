// §5.8 The table: overall, per crew, this week, per competition — with rank movement
import { useState } from "react";
import { getCompetitions, getMyCrews, leaderboard } from "../lib/api";
import { pts as fmtPts, signedPts } from "../lib/calls";
import { useAuth, useLoad } from "../lib/auth";
import { Avatar, Empty, ErrorBox, Spinner } from "../components/ui";

type Scope = { id: string; label: string; scope: "overall" | "crew" | "week" | "competition"; key?: string };

export default function Table() {
  const { session } = useAuth();
  const uid = session!.user.id;
  const [sel, setSel] = useState("overall");
  const { data: meta } = useLoad(async () => {
    const [crews, comps] = await Promise.all([getMyCrews(), getCompetitions()]);
    const scopes: Scope[] = [{ id: "overall", label: "Overall", scope: "overall" }, ...crews.map((c) => ({ id: "crew:" + c.id, label: c.name, scope: "crew" as const, key: c.id })), { id: "week", label: "This week", scope: "week" },
      ...comps.map((c) => ({ id: "comp:" + c.code, label: c.name, scope: "competition" as const, key: c.code }))];
    return { scopes };
  }, []);
  const scope = meta?.scopes.find((s) => s.id === sel) ?? { id: "overall", label: "Overall", scope: "overall" as const };
  const { data: rows, error, loading } = useLoad(async () => leaderboard(scope.scope, scope.key), [sel, !!meta]);

  // rank movement: compare to a ranking on points_prev (points as of 7 days ago)
  const prevOrder = [...(rows ?? [])].sort((a, b) => b.points_prev - a.points_prev).map((r) => r.user_id);
  const move = (r: { user_id: string }, i: number) => { const p = prevOrder.indexOf(r.user_id); return p < 0 ? 0 : p - i; };

  return (
    <div>
      <h2 className="display">The table</h2>
      <div className="small muted" style={{ margin: "-8px 0 14px" }}>Points are a currency, so the overall table is a rich list: it ranks on what you hold. A crew, a week or a competition ranks on what you won there.</div>
      <div className="row-of" style={{ marginBottom: 16 }}>
        {(meta?.scopes ?? []).map((s) => <button key={s.id} className={"pill" + (sel === s.id ? " on" : "")} onClick={() => setSel(s.id)}>{s.label}</button>)}
      </div>
      {error && <ErrorBox msg={error} />}
      {loading && !rows && <Spinner />}
      {rows && rows.length === 0 && <Empty>Nothing settled in this scope yet.</Empty>}
      {rows && rows.length > 0 && (
        <div>
          <div className="trow thead lb"><span>#</span><span></span><span>Player</span><span className="hide-s">Cards</span><span className="hide-s">Hit rate</span><span className="hide-s">On settled cards</span><span style={{ textAlign: "right" }}>Points held</span></div>
          {rows.map((r, i) => { const mv = move(r, i); return (
            <div key={r.user_id} className={"trow lb" + (r.user_id === uid ? " me" : "")}>
              <span><span className="pos">{i + 1}</span> <span className={"move" + (mv > 0 ? " up" : mv < 0 ? " down" : "")}>{mv > 0 ? `▲${mv}` : mv < 0 ? `▼${-mv}` : "–"}</span></span>
              <Avatar name={r.display_name} me={r.user_id === uid} />
              <span className="small" style={{ fontWeight: 700 }}>{r.user_id === uid ? "You" : r.display_name ?? "Player"}</span>
              <span className="small muted hide-s">{r.cards} cards</span>
              <span className="small muted hide-s">{r.hit_rate}%</span>
              <span className="small hide-s" style={{ color: r.points > 0 ? "var(--lime)" : r.points < 0 ? "var(--magenta)" : "var(--soft)" }}>{signedPts(Number(r.points))}</span>
              <span className="ptsc">{fmtPts(r.balance)}</span>
            </div>
          ); })}
        </div>
      )}
    </div>
  );
}
