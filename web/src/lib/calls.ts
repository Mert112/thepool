// How a call reads on screen. Football only (0017).
import type { BoardRow, Call, Market, Player } from "./api";

export const teamName = (m: BoardRow, t: number | null | undefined) => (t === m.home_team_id ? m.home_team : t === m.away_team_id ? m.away_team : "");

export function pickText(c: Call | undefined, m: BoardRow, playerName: (id: number | null | undefined) => string): string {
  if (!c) return "No pick";
  switch (c.call_type) {
    case "winner": return c.pick === "draw" ? "Draw" : teamName(m, c.team_id);
    case "draw": return c.yes ? "Yes" : "No";
    case "total": return `${c.yes ? "Over" : "Under"} ${c.line ?? lineOf(m) ?? ""}`.trim();
    case "spread": { const l = c.line ?? spreadFor(m, c.team_id); return `${teamName(m, c.team_id)} ${l == null ? "" : signed(l)}`.trim(); }
    case "score": return `${c.home_goals}–${c.away_goals}`;
    default: return `${playerName(c.player_id) || "Player"}${c.pick ? ` · ${c.pick}'` : ""}`;   // the red card's time window
  }
}

// player markets pick a name from either squad
export const isPlayerMarket = (k: Market) => ["scorer", "assist", "yellow", "red", "motm"].includes(k.call_type);

export const signed = (n: number) => (n > 0 ? `+${n}` : `${n}`);
export const lineOf = (m: BoardRow) => m.odds?.total?.line ?? m.total_line;
export const spreadFor = (m: BoardRow, team: number | null | undefined) => { const hl = m.odds?.spread?.home_line; return hl == null ? null : team === m.home_team_id ? hl : -hl; };

// a market the card can offer for this match: an over/under needs a goals line, a handicap needs one on the board
export const offered = (k: Market, m: BoardRow) =>
  k.call_type === "total" ? lineOf(m) != null : k.call_type === "spread" ? m.odds?.spread?.home_line != null : true;

// What a call pays back, per point staked (mirrors pool.call_multiplier). The draw has its own
// multiplier on the 3-way result, and a narrower call — the red card's 15-minute window — scales it.
export function multiplierOf(k: Market, pick?: string | null): number {
  if (pick && k.pick_multiplier?.[pick] != null) return k.pick_multiplier[pick];
  return k.multiplier * (pick ? k.option_mult?.[pick] ?? 1 : 1);
}
// a saved call keeps the multiplier it was taken at
export const multiplierOfCall = (k: Market, c: Call) => c.multiplier ?? multiplierOf(k, c.pick);
// a landed call returns the stake times the multiplier
export const returnOf = (stake: number, multiplier: number) => Math.round(stake * multiplier);
export const fmtMult = (m: number) => `${Number(m.toFixed(2))}×`;

export const squadOf = (squads: Player[], teamId: number) => squads.filter((p) => p.team_id === teamId);

// the live status line
export const liveClock = (m: BoardRow) => m.clock ?? (m.minute ? `${m.minute}'` : "Live");

// Two calls that cannot both land (mirrors pool.call_conflict in 0017). A new pick replaces any call it clashes with.
export function clashes(a: Call, b: Call, m: BoardRow): boolean {
  const pair = (x: string, y: string) => (a.call_type === x && b.call_type === y ? [a, b] : b.call_type === x && a.call_type === y ? [b, a] : null);
  const winnerOf = (h: number, aw: number) => (h > aw ? m.home_team_id : aw > h ? m.away_team_id : null);
  let p;
  if ((p = pair("winner", "draw"))) return p[1].yes === true && p[0].pick !== "draw";
  if ((p = pair("score", "winner"))) return p[1].pick === "draw" ? p[0].home_goals !== p[0].away_goals : winnerOf(p[0].home_goals!, p[0].away_goals!) !== p[1].team_id;
  if ((p = pair("score", "spread"))) { const d = p[1].team_id === m.home_team_id ? p[0].home_goals! - p[0].away_goals! : p[0].away_goals! - p[0].home_goals!; return d + (p[1].line ?? spreadFor(m, p[1].team_id) ?? 0) < 0; }
  if ((p = pair("spread", "winner"))) { const l = p[0].line ?? spreadFor(m, p[0].team_id) ?? 0; return l < 0 && (p[1].pick === "draw" || p[1].team_id !== p[0].team_id); }
  if ((p = pair("score", "draw"))) return (p[0].home_goals === p[0].away_goals) !== p[1].yes;
  if ((p = pair("score", "total"))) { const t = p[0].home_goals! + p[0].away_goals!, line = p[1].line ?? lineOf(m) ?? 0; return p[1].yes ? t < line : t > line; }
  return false;
}

// what a market pays per point staked: one multiplier, or the range across its options
export function multiplierRange(k: Market): string {
  const picks: Array<string | null> = [null, ...Object.keys(k.pick_multiplier ?? {}), ...Object.keys(k.option_mult ?? {})];
  const ms = picks.map((p) => multiplierOf(k, p));
  const lo = Math.min(...ms), hi = Math.max(...ms);
  return lo === hi ? fmtMult(lo) : `${Number(lo.toFixed(2))}–${fmtMult(hi)}`;
}
