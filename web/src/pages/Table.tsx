// §5.8 The table: overall, per crew, this week, per competition — with rank movement
import { useState } from "react";
import { getCompetitions, getMyCrews, leaderboard } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { useI18n } from "../i18n";
import { Avatar, Empty, ErrorBox, Spinner } from "../components/ui";

type Scope = { id: string; label: string; scope: "overall" | "crew" | "week" | "competition"; key?: string };

export default function Table() {
  const { session } = useAuth();
  const { t, fmt } = useI18n();
  const uid = session!.user.id;
  const [sel, setSel] = useState("overall");
  const { data: meta } = useLoad(async () => {
    const [crews, comps] = await Promise.all([getMyCrews(), getCompetitions()]);
    const scopes: Scope[] = [{ id: "overall", label: t.table.overall, scope: "overall" }, ...crews.map((c) => ({ id: "crew:" + c.id, label: c.name, scope: "crew" as const, key: c.id })), { id: "week", label: t.table.thisWeek, scope: "week" },
      ...comps.map((c) => ({ id: "comp:" + c.code, label: c.name, scope: "competition" as const, key: c.code }))];
    return { scopes };
  }, [t.code]);
  const scope = meta?.scopes.find((s) => s.id === sel) ?? { id: "overall", label: t.table.overall, scope: "overall" as const };
  const { data: rows, error, loading } = useLoad(async () => leaderboard(scope.scope, scope.key), [sel, !!meta]);

  // rank movement: compare to a ranking on points_prev (points as of 7 days ago)
  const prevOrder = [...(rows ?? [])].sort((a, b) => b.points_prev - a.points_prev).map((r) => r.user_id);
  const move = (r: { user_id: string }, i: number) => { const p = prevOrder.indexOf(r.user_id); return p < 0 ? 0 : p - i; };

  return (
    <div>
      <h2 className="display">{t.table.title}</h2>
      <div className="small muted" style={{ margin: "-8px 0 14px" }}>{t.table.blurb}</div>
      <div className="row-of" style={{ marginBottom: 16 }}>
        {(meta?.scopes ?? []).map((s) => <button key={s.id} className={"pill" + (sel === s.id ? " on" : "")} onClick={() => setSel(s.id)}>{s.label}</button>)}
      </div>
      {error && <ErrorBox msg={error} />}
      {loading && !rows && <Spinner />}
      {rows && rows.length === 0 && <Empty>{t.table.empty}</Empty>}
      {rows && rows.length > 0 && (
        <div>
          <div className="trow thead lb"><span>#</span><span></span><span>{t.table.colPlayer}</span><span className="hide-s">{t.table.colCards}</span><span className="hide-s">{t.table.colHitRate}</span><span className="hide-s">{t.table.colOnSettled}</span><span style={{ textAlign: "right" }}>{t.table.colHeld}</span></div>
          {rows.map((r, i) => { const mv = move(r, i); return (
            <div key={r.user_id} className={"trow lb" + (r.user_id === uid ? " me" : "")}>
              <span><span className="pos">{i + 1}</span> <span className={"move" + (mv > 0 ? " up" : mv < 0 ? " down" : "")}>{mv > 0 ? `▲${mv}` : mv < 0 ? `▼${-mv}` : "–"}</span></span>
              <Avatar name={r.display_name} icon={r.icon} me={false} />
              <span className="small" style={{ fontWeight: 700 }}>{r.user_id === uid ? t.common.you : r.display_name ?? t.common.player}</span>
              <span className="small muted hide-s">{t.table.cards(r.cards)}</span>
              <span className="small muted hide-s">{r.hit_rate}%</span>
              <span className="small hide-s" style={{ color: r.points > 0 ? "var(--lime)" : r.points < 0 ? "var(--magenta)" : "var(--soft)" }}>{fmt.signedPts(Number(r.points))}</span>
              <span className="ptsc">{fmt.pts(r.balance)}</span>
            </div>
          ); })}
        </div>
      )}
    </div>
  );
}
