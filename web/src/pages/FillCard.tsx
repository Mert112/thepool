// §5.4 Filling the card: all markets on one screen, a running slip, one boost.
import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { getCard, getCrowd, getMarkets, getMatch, getMyEntry, getSquads, saveCalls, setBoost, type Call, type CallType, type Market } from "../lib/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { countdown, fmtWhen, soon } from "../lib/format";
import { isPlayerMarket, offered, pickText as describe, setScores, teamName as nameOf } from "../lib/calls";
import { Bar, Empty, ErrorBox, Pips, Spinner } from "../components/ui";

type Picks = Partial<Record<CallType, Call>>;

export default function FillCard() {
  const { id } = useParams();
  const nav = useNavigate();
  const now = useNow();
  const { session } = useAuth();
  const uid = session!.user.id;
  const [picks, setPicks] = useState<Picks>({});
  const [side, setSide] = useState<Partial<Record<CallType, "h" | "a">>>({});
  const [boost, setBoostState] = useState<CallType | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const { data, error, loading } = useLoad(async () => {
    const card = await getCard(id!);
    if (!card) throw new Error("This card does not exist or is not yours to see.");
    const match = await getMatch(card.match_id);
    if (!match) throw new Error("Fixture missing.");
    const [markets, entry, crowd, squads] = await Promise.all([getMarkets(match.sport), getMyEntry(card.id, uid), getCrowd(card.id), getSquads(match.home_team_id, match.away_team_id)]);
    return { card, match, markets: markets.filter((k) => (card.mode === "complex" || k.simple) && offered(k, match)), entry, crowd, squads };
  }, [id]);

  // hydrate from the saved entry
  useEffect(() => {
    if (!data?.entry) return;
    const p: Picks = {}; const s: Partial<Record<CallType, "h" | "a">> = {};
    for (const c of data.entry.calls) {
      p[c.call_type] = c;
      if (c.player_id) { const pl = data.squads.find((x) => x.id === c.player_id); if (pl) s[c.call_type] = pl.team_id === data.match.home_team_id ? "h" : "a"; }
    }
    setPicks(p); setSide(s); setBoostState(data.entry.boost_call_type);
  }, [data]);

  const editable = data ? data.card.status === "open" && new Date(data.match.utc_date).getTime() > now : false;
  const set = (k: CallType, v: Call | null) => { setSaved(false); setPicks((p) => { const n = { ...p }; if (v) n[k] = v; else delete n[k]; return n; }); if (!v && boost === k) setBoostState(null); };
  const ptsOf = (k: Market) => k.points * (boost === k.call_type ? 2 : 1);
  const slip = useMemo(() => (data?.markets ?? []).filter((k) => picks[k.call_type]), [data, picks]);
  const total = slip.reduce((s, k) => s + ptsOf(k), 0);

  const save = async () => {
    if (!data) return;
    setSaving(true); setErr(null);
    try {
      const calls = Object.values(picks).map((c) => ({ call_type: c.call_type, team_id: c.team_id ?? null, yes: c.yes ?? null, player_id: c.player_id ?? null, home_goals: c.home_goals ?? null, away_goals: c.away_goals ?? null, pick: c.pick ?? null }));
      await saveCalls(data.card.id, calls);
      await setBoost(data.card.id, boost);
      setSaved(true);
    } catch (e: any) { setErr(e.message); }
    setSaving(false);
  };

  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const { card, match, markets, crowd, squads } = data!;
  if (!match) return <Empty>Fixture missing.</Empty>;
  const teamName = (t: number) => nameOf(match, t);
  const playerName = (pid: number | null | undefined) => squads.find((p) => p.id === pid)?.name ?? "";
  const crowdFor = (ct: CallType) => crowd.filter((c) => c.call_type === ct).sort((a, b) => b.n - a.n);
  const pickText = (c: Call) => describe(c, match, playerName);
  const sides = [match.home_team_id, match.away_team_id];
  const distanceLabels = match.sport === "tennis" ? ["Yes — a deciding set", "No — it ends early"] : ["Yes — to the judges", "No — someone finishes it"];
  const opt = (k: CallType, on: boolean, label: string, v: Call) => <button key={label} disabled={!editable} className={"opt" + (on ? " on" : "")} onClick={() => set(k, on ? null : v)}>{label}</button>;

  return (
    <div>
      <div className="grid two">
        <div>
          <div className="eyebrow">{match.competition_name} · {fmtWhen(match.utc_date)} · {card.crew_id ? card.crews?.name : "Open card"}</div>
          <h2 className="display" style={{ margin: "6px 0 4px" }}>{match.home_team} v {match.away_team}</h2>
          <div className="small num" style={{ marginBottom: 18, color: soon(match.utc_date, now) ? "var(--magenta)" : "var(--soft)" }}>
            {editable ? `Locks in ${countdown(match.utc_date, now)} · edit as often as you like until then` : "This card is locked."}
          </div>

          {markets.map((k) => {
            const cur = picks[k.call_type];
            const on = !!cur, boosted = boost === k.call_type;
            const sd = side[k.call_type] ?? "h";
            const teamId = sd === "h" ? match.home_team_id : match.away_team_id;
            const squad = squads.filter((p) => p.team_id === teamId);
            const top = crowdFor(k.call_type)[0];
            return (
              <div key={k.call_type} className={"market" + (on ? " on" : "")}>
                <div className="head">
                  <div><h3 className="display" style={{ margin: 0 }}>{k.title}</h3><div className="small muted">{k.description}</div></div>
                  <div style={{ textAlign: "right" }}><div className="pts">{ptsOf(k)}</div><Pips n={Math.min(8, k.points)} /></div>
                </div>

                {k.call_type === "winner" && (
                  <div className="opts">
                    {[match.home_team_id, match.away_team_id].map((t) => <button key={t} disabled={!editable} className={"opt" + (cur?.team_id === t ? " on" : "")} onClick={() => set("winner", cur?.team_id === t ? null : { call_type: "winner", team_id: t })}>{teamName(t)}</button>)}
                  </div>
                )}
                {k.call_type === "total" && (
                  <div className="opts">
                    {opt("total", cur?.yes === true, `Over ${match.total_line}`, { call_type: "total", yes: true, line: match.total_line })}
                    {opt("total", cur?.yes === false, `Under ${match.total_line}`, { call_type: "total", yes: false, line: match.total_line })}
                  </div>
                )}
                {k.call_type === "distance" && (
                  <div className="opts">
                    {opt("distance", cur?.yes === true, distanceLabels[0], { call_type: "distance", yes: true })}
                    {opt("distance", cur?.yes === false, distanceLabels[1], { call_type: "distance", yes: false })}
                  </div>
                )}
                {k.call_type === "margin" && (
                  <div className="stack" style={{ marginTop: 14, gap: 8 }}>
                    {sides.map((t) => (
                      <div key={t} className="row-of">
                        <span className="small" style={{ fontWeight: 700, minWidth: 140 }}>{teamName(t)} by</span>
                        {(k.options ?? []).map((b) => { const on = cur?.team_id === t && cur?.pick === b; return <button key={b} disabled={!editable} className={"opt" + (on ? " on" : "")} style={{ flex: "none", minWidth: 64 }} onClick={() => set("margin", on ? null : { call_type: "margin", team_id: t, pick: b })}>{b}</button>; })}
                      </div>
                    ))}
                  </div>
                )}
                {k.call_type === "sets" && (
                  <div className="opts">
                    {setScores(match.best_of).map(([h, a]) => opt("sets", cur?.home_goals === h && cur?.away_goals === a, `${teamName(h > a ? match.home_team_id : match.away_team_id)} ${Math.max(h, a)}–${Math.min(h, a)}`, { call_type: "sets", home_goals: h, away_goals: a }))}
                  </div>
                )}
                {k.call_type === "method" && (
                  <div className="opts">
                    {(k.options ?? []).map((m) => opt("method", cur?.pick === m, m, { call_type: "method", pick: m }))}
                  </div>
                )}
                {k.call_type === "round" && (
                  <div className="opts">
                    {Array.from({ length: match.best_of ?? 3 }, (_, i) => String(i + 1)).map((r) => opt("round", cur?.pick === r, `Round ${r}`, { call_type: "round", pick: r }))}
                  </div>
                )}
                {k.call_type === "draw" && (
                  <div className="opts">
                    <button disabled={!editable} className={"opt" + (cur?.yes === true ? " on" : "")} onClick={() => set("draw", cur?.yes === true ? null : { call_type: "draw", yes: true })}>Yes — level at 90</button>
                    <button disabled={!editable} className={"opt" + (cur?.yes === false ? " on" : "")} onClick={() => set("draw", cur?.yes === false ? null : { call_type: "draw", yes: false })}>No — someone wins</button>
                  </div>
                )}
                {k.call_type === "score" && (
                  <div className="row-of" style={{ marginTop: 14, gap: 24 }}>
                    {(["home", "away"] as const).map((sideKey) => {
                      const val = sideKey === "home" ? (cur?.home_goals ?? 1) : (cur?.away_goals ?? 1);
                      const upd = (n: number) => set("score", { call_type: "score", home_goals: sideKey === "home" ? n : (cur?.home_goals ?? 1), away_goals: sideKey === "away" ? n : (cur?.away_goals ?? 1) });
                      return (
                        <div key={sideKey}>
                          <div className="tiny muted" style={{ marginBottom: 6 }}>{sideKey === "home" ? match.home_team : match.away_team}</div>
                          <div className="stepper"><button disabled={!editable} onClick={() => upd(Math.max(0, val - 1))}>−</button><span className="n">{val}</span><button disabled={!editable} onClick={() => upd(Math.min(9, val + 1))}>+</button></div>
                        </div>
                      );
                    })}
                    {cur && <button className="btn ghost" disabled={!editable} onClick={() => set("score", null)}>Clear</button>}
                  </div>
                )}
                {isPlayerMarket(k) && (
                  <div className="row-of" style={{ marginTop: 14 }}>
                    <select className="select" style={{ width: 220 }} disabled={!editable} value={sd} onChange={(e) => { setSide((s) => ({ ...s, [k.call_type]: e.target.value as "h" | "a" })); set(k.call_type, null); }}>
                      <option value="h">{match.home_team} (home)</option>
                      <option value="a">{match.away_team} (away)</option>
                    </select>
                    <select className="select" style={{ width: 260 }} disabled={!editable} value={cur?.player_id ?? ""} onChange={(e) => set(k.call_type, e.target.value ? { call_type: k.call_type, player_id: Number(e.target.value) } : null)}>
                      <option value="">— pick a player —</option>
                      {squad.map((p) => <option key={p.id} value={p.id}>{p.name}{p.position ? ` · ${p.position}` : ""}</option>)}
                    </select>
                    {squad.length === 0 && <span className="tiny magenta">Squad still loading for this side — check back in a minute.</span>}
                  </div>
                )}

                <div className="row-of" style={{ marginTop: 14, justifyContent: "space-between" }}>
                  <div className="crowd">
                    {top ? <>{top.pct}% · {top.label}<Bar pct={top.pct} width={260} /></> : <span className="faint">Nobody has called this yet.</span>}
                  </div>
                  {on && editable && (
                    <button className={"boost" + (boosted ? " on" : "")} onClick={() => { setSaved(false); setBoostState(boosted ? null : k.call_type); }}>
                      {boosted ? "Boosted ×2" : boost ? "Move the boost here" : "Boost this call · ×2"}
                    </button>
                  )}
                </div>
                {boosted && <div className="tiny muted" style={{ marginTop: 8 }}>Doubled: {k.points} → {k.points * 2} if it lands. Nothing lost if it misses. One boost per matchday, across every card you play.</div>}
              </div>
            );
          })}
        </div>

        <div className="stack">
          <div className="panel">
            <div className="eyebrow" style={{ marginBottom: 10 }}>Where the pool has gone</div>
            {markets.map((k) => { const rows = crowdFor(k.call_type).slice(0, 2); return (
              <div key={k.call_type} style={{ padding: "8px 0", borderBottom: "1px solid var(--raise)" }}>
                <div className="tiny muted" style={{ textTransform: "uppercase", letterSpacing: "0.08em" }}>{k.title}</div>
                {rows.length === 0 && <div className="faint small">—</div>}
                {rows.map((r) => <div key={r.key} className="small" style={{ display: "flex", justifyContent: "space-between", gap: 8 }}><span>{r.label}</span><span className="lime">{r.pct}%</span></div>)}
              </div>
            ); })}
          </div>
          <div className="panel">
            <div className="eyebrow">Your boost</div>
            <div className="small muted" style={{ marginTop: 6 }}>{boost ? `On “${markets.find((k) => k.call_type === boost)?.title}” for this match.` : "Unspent on this card. One per matchday — pick the call you believe in most."}</div>
          </div>
        </div>
      </div>

      <div className="slip">
        <div className="items">
          {slip.length === 0 && <span className="muted small">No calls yet. Skipping a call only forfeits its points — a partial card is always valid.</span>}
          {slip.map((k) => <span className="item" key={k.call_type}>{k.title}: {pickText(picks[k.call_type]!)} <b>+{ptsOf(k)}</b>{editable && <button onClick={() => set(k.call_type, null)} title="Remove">×</button>}</span>)}
        </div>
        <div className="total">{total}</div>
        {editable ? (
          <button className="btn big" disabled={saving || slip.length === 0} onClick={save}>{saving ? "Saving…" : saved ? "Saved ✓" : data!.entry ? "Update my card" : "Lock in my card"}</button>
        ) : (
          <button className="btn big" onClick={() => nav(`/card/${card.id}/live`)}>{card.status === "settled" ? "See the recap" : "Watch it live"}</button>
        )}
        <ErrorBox msg={err} />
      </div>
    </div>
  );
}
