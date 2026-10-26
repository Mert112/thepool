// §5.4 Filling the card: every market on one screen, a stake on each call, a running slip.
//
// Points are a currency (0019). Each call carries a stake of 10, 25, 50, 100 or 200; the stake
// leaves the balance when the card locks at kick-off, and a call that lands returns stake ×
// multiplier. Nothing is free, so there is no boost any more — the stake is the lever.
//
// Two calls that cannot both land are a hedge, and the server refuses the card outright, so a new
// pick replaces the one it contradicts. That used to happen in silence — one line in the slip at the
// foot of a long page, wiped by the next tap — and people saved cards missing the call they thought
// they had made. The replacement is now a banner that stays until it is dismissed or undone, and the
// market it emptied says so where the market is. Saving then reads the entry back and shows exactly
// what the database kept, so "I filled it in" and "it says No pick" can never disagree again.
import { useEffect, useMemo, useState, type CSSProperties } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { getCard, getCrowd, getMarkets, getMatch, getMyEntry, getSquads, myCommittedStake, saveCalls, STAKES,
  type Call, type CallType, type Market, type Player } from "../lib/api";
import { useAuth, useLoad, useNow } from "../lib/auth";
import { countdown, fmtWhen, soon } from "../lib/format";
import { clashes, fmtMult, isPlayerMarket, lineOf, multiplierOf, multiplierOfCall, multiplierRange, offered,
  pickText as describe, returnOf, signed, spreadFor, teamName as nameOf } from "../lib/calls";
import { Bar, Empty, ErrorBox, Spinner } from "../components/ui";

type Picks = Partial<Record<CallType, Call>>;
const DEFAULT_STAKE = 10;

const playerNameOf = (squads: Player[]) => (pid: number | null | undefined) => squads.find((p) => p.id === pid)?.name ?? "";

export default function FillCard() {
  const { id } = useParams();
  const nav = useNavigate();
  const now = useNow();
  const { session, profile, refreshProfile } = useAuth();
  const uid = session!.user.id;
  const [picks, setPicks] = useState<Picks>({});
  const [stakes, setStakes] = useState<Partial<Record<CallType, number>>>({});
  const [side, setSide] = useState<Partial<Record<CallType, "h" | "a">>>({});
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState<{ calls: Call[] } | null>(null);
  const [clash, setClash] = useState<{ dropped: CallType[]; by: CallType; before: Picks } | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const { data, error, loading } = useLoad(async () => {
    const card = await getCard(id!);
    if (!card) throw new Error("This card does not exist or is not yours to see.");
    const match = await getMatch(card.match_id);
    if (!match) throw new Error("Fixture missing.");
    const [markets, entry, crowd, squads, committed] = await Promise.all([
      getMarkets(), getMyEntry(card.id, uid), getCrowd(card.id), getSquads(match.home_team_id, match.away_team_id), myCommittedStake(),
    ]);
    // committed counts this card too; the page works out what is left after this card's own stakes
    const mine = (entry?.calls ?? []).reduce((s, c) => s + (c.stake ?? 0), 0);
    return { card, match, markets: markets.filter((k) => (card.mode === "complex" || k.simple) && offered(k, match)), entry, crowd, squads, elsewhere: committed - mine };
  }, [id]);

  // hydrate from the saved entry
  useEffect(() => {
    if (!data?.entry) return;
    const p: Picks = {}; const st: Partial<Record<CallType, number>> = {}; const s: Partial<Record<CallType, "h" | "a">> = {};
    for (const c of data.entry.calls) {
      p[c.call_type] = c;
      st[c.call_type] = c.stake ?? DEFAULT_STAKE;
      if (c.player_id) { const pl = data.squads.find((x) => x.id === c.player_id); if (pl) s[c.call_type] = pl.team_id === data.match.home_team_id ? "h" : "a"; }
    }
    setPicks(p); setStakes(st); setSide(s);
  }, [data]);

  const editable = data ? data.card.status === "open" && new Date(data.match.utc_date).getTime() > now : false;
  const titleOf = (c: CallType) => data?.markets.find((x) => x.call_type === c)?.title ?? c;
  const stakeOf = (c: CallType) => stakes[c] ?? DEFAULT_STAKE;

  // a new pick replaces any call it contradicts (the server refuses hedged cards), loudly and undoably
  const set = (k: CallType, v: Call | null) => {
    setSaved(null); setErr(null);
    const before = picks;
    const dropped: CallType[] = [];
    const n = { ...picks };
    if (v) {
      n[k] = v;
      for (const other of Object.values(n)) if (other && other.call_type !== k && clashes(v, other, data!.match)) { delete n[other.call_type]; dropped.push(other.call_type); }
    } else delete n[k];
    setPicks(n);
    // the warning survives until it is dismissed, undone, or the market it emptied is filled again
    if (dropped.length) setClash({ dropped, by: k, before });
    else if (clash && (clash.dropped.includes(k) || clash.by === k)) setClash(null);
  };
  const undoClash = () => { if (!clash) return; setPicks(clash.before); setClash(null); setSaved(null); };
  const setStake = (k: CallType, n: number) => { setSaved(null); setErr(null); setStakes((s) => ({ ...s, [k]: n })); };

  const slip = useMemo(() => (data?.markets ?? []).filter((k) => picks[k.call_type]), [data, picks]);
  // what a call returns if it lands: the stake times the multiplier it was taken at
  const payout = (k: Market) => { const c = picks[k.call_type]; return c ? returnOf(stakeOf(k.call_type), multiplierOfCall(k, c)) : 0; };
  const staked = slip.reduce((s, k) => s + stakeOf(k.call_type), 0);
  const toWin = slip.reduce((s, k) => s + payout(k), 0);
  // what is left for this card: the balance, less what other open cards have already promised
  const purse = (profile?.balance ?? 0) - (data?.elsewhere ?? 0);
  const overdrawn = staked > purse;

  // what identifies a pick, for checking the database kept what we sent. `line` is the server's to set.
  const sig = (c: Call) => [c.call_type, c.team_id ?? "", c.yes ?? "", c.player_id ?? "", c.home_goals ?? "", c.away_goals ?? "", c.pick ?? "", c.stake ?? DEFAULT_STAKE].join("|");

  const save = async () => {
    if (!data) return;
    setSaving(true); setErr(null); setSaved(null);
    try {
      const off = Object.values(picks).filter((c) => !data.markets.some((k) => k.call_type === c.call_type));
      if (off.length) throw new Error(`${off.map((c) => `“${titleOf(c.call_type)}”`).join(" and ")} is no longer on this card. Remove it and save again.`);
      const calls: Call[] = Object.values(picks).map((c) => ({
        call_type: c.call_type, team_id: c.team_id ?? null, yes: c.yes ?? null, player_id: c.player_id ?? null,
        home_goals: c.home_goals ?? null, away_goals: c.away_goals ?? null, pick: c.pick ?? null, stake: stakeOf(c.call_type),
      }));
      await saveCalls(data.card.id, calls);

      // read it back: the confirmation is what the database holds, not what we hoped it would hold
      const entry = await getMyEntry(data.card.id, uid);
      const stored = entry?.calls ?? [];
      const want = new Set(calls.map(sig)), got = new Set(stored.map(sig));
      const missing = calls.filter((c) => !got.has(sig(c))).map((c) => titleOf(c.call_type));
      const extra = stored.filter((c) => !want.has(sig(c))).map((c) => titleOf(c.call_type));
      if (missing.length || extra.length) {
        throw new Error(`Your card did not save as you set it. ${missing.length ? `${missing.join(", ")} did not save. ` : ""}${extra.length ? `${extra.join(", ")} is on the card but not as you set it. ` : ""}Nothing is lost — check the calls below and save again.`);
      }
      setSaved({ calls: stored });
      setClash(null);
      refreshProfile();
      // §3: land back on the match page rather than sitting on the form, with the receipt in hand
      nav(`/match/${data.match.match_id}`, {
        replace: true,
        state: { saved: {
          n: stored.length,
          staked: stored.reduce((s, c) => s + (c.stake ?? 0), 0),
          calls: stored.map((c) => `${titleOf(c.call_type)} — ${describe(c, data.match, playerNameOf(data.squads))} · ${c.stake}`),
        } },
      });
    } catch (e: any) { setErr(e.message ?? String(e)); }
    setSaving(false);
  };

  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const { card, match, markets, crowd, squads } = data!;
  if (!match) return <Empty>Fixture missing.</Empty>;
  const teamName = (t: number) => nameOf(match, t);
  const playerName = playerNameOf(squads);
  const crowdFor = (ct: CallType) => crowd.filter((c) => c.call_type === ct).sort((a, b) => b.n - a.n);
  const pickText = (c: Call) => describe(c, match, playerName);
  const sides = [match.home_team_id, match.away_team_id];

  const opt = (k: Market, on: boolean, label: string, v: Call) => (
    <button key={label} disabled={!editable} className={"opt" + (on ? " on" : "")} onClick={() => set(k.call_type, on ? null : v)}>
      {label}<span className="odds">{fmtMult(multiplierOf(k, v.pick ?? null))}</span>
    </button>
  );

  return (
    <div>
      <div className="grid two">
        <div>
          <div className="eyebrow">{match.competition_name} · {fmtWhen(match.utc_date)} · {card.crew_id ? card.crews?.name : "Open card"}</div>
          <h2 className="display" style={{ margin: "6px 0 4px" }}>{match.home_team} v {match.away_team}</h2>
          <div className="small num" style={{ marginBottom: 10, color: soon(match.utc_date, now) ? "var(--magenta)" : "var(--soft)" }}>
            {editable ? `Locks in ${countdown(match.utc_date, now)} · edit as often as you like until then` : "This card is locked."}
          </div>
          <div className="tiny muted" style={{ marginBottom: 16 }}>
            Every call carries a stake. Nothing leaves your balance until kick-off; after that a call that
            lands returns its stake times the multiplier, a call that misses loses the stake, and a void
            call hands the stake back.
          </div>

          {err && <div className="banner bad" role="alert"><div><b>Not saved.</b> {err}</div></div>}
          {saved && (
            <div className="banner ok" role="status">
              <b>Saved ✓</b>{" "}
              {saved.calls.length === 0
                ? "Your card is withdrawn — you have no calls on this match."
                : `${saved.calls.length} ${saved.calls.length === 1 ? "call is" : "calls are"} on your card: ${saved.calls.map((c) => `${titleOf(c.call_type)} — ${pickText(c)}`).join(" · ")}.`}
            </div>
          )}
          {clash && (
            <div className="banner warn" role="alert">
              <div>
                <b>{clash.dropped.map((c) => `“${titleOf(c)}”`).join(" and ")} removed.</b>{" "}
                It cannot land alongside your “{titleOf(clash.by)}” pick, and the card is refused if both are on it.
                Pick it again a different way, or undo.
              </div>
              <div className="row-of">
                <button className="btn tiny-btn" onClick={undoClash}>Undo</button>
                <button className="btn ghost tiny-btn" onClick={() => setClash(null)}>Dismiss</button>
              </div>
            </div>
          )}

          {markets.map((k, i) => {
            const cur = picks[k.call_type];
            const on = !!cur;
            const dropped = !!clash?.dropped.includes(k.call_type);
            const sd = side[k.call_type] ?? "h";
            const teamId = sd === "h" ? match.home_team_id : match.away_team_id;
            const squad = squads.filter((p) => p.team_id === teamId);
            const top = crowdFor(k.call_type)[0];
            return (
              <div key={k.call_type} className={"market" + (on ? " on" : "") + (dropped ? " dropped" : "")} style={{ "--i": i } as CSSProperties}>
                {dropped && <div className="dropped-flag">Removed — it clashed with your “{titleOf(clash!.by)}” pick. Nothing here will be saved until you pick again.</div>}
                <div className="head">
                  <div><h3 className="display" style={{ margin: 0 }}>{k.title}</h3><div className="small muted explainer">{k.explainer}</div></div>
                  <div style={{ textAlign: "right" }}>
                    <div className="pts">{on ? fmtMult(multiplierOfCall(k, cur!)) : multiplierRange(k)}</div>
                    <div className="tiny muted">your stake back, times this</div>
                    {on && editable && <button className="remove-call" onClick={() => set(k.call_type, null)}>Remove</button>}
                  </div>
                </div>

                {k.call_type === "winner" && (
                  <div className="opts">
                    {opt(k, !!cur && cur.pick !== "draw" && cur.team_id === match.home_team_id, teamName(match.home_team_id), { call_type: "winner", team_id: match.home_team_id })}
                    {opt(k, cur?.pick === "draw", "Draw", { call_type: "winner", pick: "draw" })}
                    {opt(k, !!cur && cur.pick !== "draw" && cur.team_id === match.away_team_id, teamName(match.away_team_id), { call_type: "winner", team_id: match.away_team_id })}
                  </div>
                )}
                {k.call_type === "total" && (
                  <div className="opts">
                    {opt(k, cur?.yes === true, `Over ${lineOf(match)}`, { call_type: "total", yes: true })}
                    {opt(k, cur?.yes === false, `Under ${lineOf(match)}`, { call_type: "total", yes: false })}
                  </div>
                )}
                {k.call_type === "spread" && (
                  <div className="opts">
                    {sides.map((t) => opt(k, cur?.team_id === t, `${teamName(t)} ${signed(spreadFor(match, t)!)}`, { call_type: "spread", team_id: t }))}
                  </div>
                )}
                {k.call_type === "draw" && (
                  <div className="opts">
                    {opt(k, cur?.yes === true, "Yes — level at 90", { call_type: "draw", yes: true })}
                    {opt(k, cur?.yes === false, "No — someone wins", { call_type: "draw", yes: false })}
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
                    <select className="select" style={{ width: 260 }} disabled={!editable} value={cur?.player_id ?? ""} onChange={(e) => set(k.call_type, e.target.value ? { call_type: k.call_type, player_id: Number(e.target.value), pick: k.call_type === "red" ? cur?.pick ?? null : null } : null)}>
                      <option value="">— pick a player —</option>
                      {squad.map((p) => <option key={p.id} value={p.id}>{p.name}{p.position ? ` · ${p.position}` : ""}</option>)}
                    </select>
                    {squad.length === 0 && <span className="tiny magenta">Squad still loading for this side — check back in a minute.</span>}
                  </div>
                )}
                {k.call_type === "red" && cur?.player_id && (k.options ?? []).length > 0 && (
                  <div style={{ marginTop: 12 }}>
                    <div className="tiny muted" style={{ marginBottom: 6 }}>When? Optional — name the window for a far bigger multiplier. Stoppage time counts in its half's last window.</div>
                    <div className="opts" style={{ marginTop: 0 }}>
                      {opt(k, !cur.pick, "Any time", { call_type: "red", player_id: cur.player_id, pick: null })}
                      {(k.options ?? []).map((w) => opt(k, cur.pick === w, `${w}'`, { call_type: "red", player_id: cur.player_id, pick: w }))}
                    </div>
                  </div>
                )}

                {on && (
                  <div className="stake-row">
                    <span className="eyebrow">Stake</span>
                    {STAKES.map((n) => (
                      <button key={n} disabled={!editable} className={"chip stake" + (stakeOf(k.call_type) === n ? " on" : "")} onClick={() => setStake(k.call_type, n)}>{n}</button>
                    ))}
                    <span className="stake-pay">returns <b>{payout(k)}</b> if it lands</span>
                  </div>
                )}

                <div className="crowd" style={{ marginTop: 14 }}>
                  {top ? <>{top.pct}% · {top.label}<Bar pct={top.pct} width={260} /></> : <span className="faint">Nobody has called this yet.</span>}
                </div>
              </div>
            );
          })}
        </div>

        <div className="stack">
          <div className="panel">
            <div className="eyebrow" style={{ marginBottom: 8 }}>Your points</div>
            <div className="num lime" style={{ fontSize: 40, lineHeight: 1 }}>{profile?.balance ?? "—"}</div>
            <div className="small muted" style={{ marginTop: 6 }}>
              {data!.elsewhere > 0
                ? <>{data!.elsewhere} is already promised to other open cards, leaving <b>{Math.max(0, purse)}</b> for this one.</>
                : <>Nothing is promised elsewhere, so all of it is available here.</>}
            </div>
            <hr className="hr" />
            <div className="small" style={{ display: "flex", justifyContent: "space-between" }}><span className="muted">Staked on this card</span><b className={overdrawn ? "magenta" : undefined}>{staked}</b></div>
            <div className="small" style={{ display: "flex", justifyContent: "space-between", marginTop: 4 }}><span className="muted">Back if it all lands</span><b className="lime">{toWin}</b></div>
            {overdrawn && <div className="tiny magenta" style={{ marginTop: 8 }}>That is more than you have left. Lower a stake, drop a call, or get more points on your profile.</div>}
          </div>
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
        </div>
      </div>

      <div className="slip">
        <div className="items">
          {slip.length === 0 && <span className="muted small">{data!.entry ? "Every call removed — save to withdraw from this card." : "No calls yet. Skipping a call costs nothing — a partial card is always valid."}</span>}
          {slip.map((k) => <span className="item" key={k.call_type}>{k.title}: {pickText(picks[k.call_type]!)} <span className="muted">{stakeOf(k.call_type)} →</span> <b>{payout(k)}</b>{editable && <button onClick={() => set(k.call_type, null)} title="Remove">×</button>}</span>)}
        </div>
        <div style={{ textAlign: "right" }}>
          <div className="total" key={toWin}>{toWin}</div>
          <div className="tiny muted">{staked} staked</div>
        </div>
        {editable ? (
          <button className="btn big" disabled={saving || overdrawn || (slip.length === 0 && !data!.entry)} onClick={save}>
            {saving ? "Saving…" : !data!.entry ? "Save my card" : slip.length ? "Update my card" : "Withdraw my card"}
          </button>
        ) : (
          <button className="btn big" onClick={() => nav(`/card/${card.id}/live`)}>{card.status === "settled" ? "See the recap" : "Watch it live"}</button>
        )}
        {err && <div className="notice bad">Not saved — {err}</div>}
      </div>
    </div>
  );
}
