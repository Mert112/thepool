// How a call reads on screen, for every sport's markets.
import type { BoardRow, Call, Market, Player, Prop } from "./api";

export const teamName = (m: BoardRow, t: number | null | undefined) => (t === m.home_team_id ? m.home_team : t === m.away_team_id ? m.away_team : "");

export function pickText(c: Call | undefined, m: BoardRow, playerName: (id: number | null | undefined) => string): string {
  if (!c) return "No pick";
  switch (c.call_type) {
    case "winner": return c.pick === "draw" ? "Draw" : teamName(m, c.team_id);
    case "draw": case "distance": return c.yes ? "Yes" : "No";
    case "total": return `${c.yes ? "Over" : "Under"} ${c.line ?? lineOf(m) ?? ""}`.trim();
    case "spread": { const l = c.line ?? spreadFor(m, c.team_id); return `${teamName(m, c.team_id)} ${l == null ? "" : signed(l)}`.trim(); }
    case "player_line": return `${playerName(c.player_id) || "Player"} ${c.yes ? "over" : "under"} ${c.line ?? ""} ${STAT_LABEL[c.pick ?? ""] ?? c.pick}`;
    case "score": case "sets": return `${c.home_goals}–${c.away_goals}`;
    case "margin": return `${teamName(m, c.team_id)} by ${c.pick}`;
    case "method": return c.team_id ? `${teamName(m, c.team_id)} by ${c.pick}` : c.pick ?? "";
    case "round": return `Round ${c.pick}`;
    default: return `${playerName(c.player_id) || "Player"}${c.pick ? ` · ${c.pick}'` : ""}`;   // the red card's time window
  }
}

// player markets pick a name from either squad
export const isPlayerMarket = (k: Market) => ["scorer", "assist", "yellow", "red", "motm", "top_scorer"].includes(k.call_type);

export const STAT_LABEL: Record<string, string> = { pts: "points", reb: "rebounds", ast: "assists", pass_yds: "passing yards", rush_yds: "rushing yards", rec_yds: "receiving yards", rec: "receptions" };
export const signed = (n: number) => (n > 0 ? `+${n}` : `${n}`);
export const lineOf = (m: BoardRow) => m.odds?.total?.line ?? m.total_line;
export const spreadFor = (m: BoardRow, team: number | null | undefined) => { const hl = m.odds?.spread?.home_line; return hl == null ? null : team === m.home_team_id ? hl : -hl; };

// a market the card can offer for this game: an over/under needs a line, a spread a handicap, a player line a posted prop
export const offered = (k: Market, m: BoardRow, props?: Prop[]) =>
  k.call_type === "total" ? lineOf(m) != null : k.call_type === "spread" ? m.odds?.spread?.home_line != null : k.call_type === "player_line" ? (props ?? []).length > 0 : true;

// the price a pick is taken at (mirrors pool.call_price): the board's odds where there are any, else the market's standard price
export function priceOf(k: Market, c: Partial<Call>, m: BoardRow): number {
  const o = m.odds ?? {};
  const p = k.call_type === "winner" ? (c.pick === "draw" ? o.draw : c.team_id === m.home_team_id ? o.home : c.team_id === m.away_team_id ? o.away : undefined)
    : k.call_type === "total" ? (c.yes ? o.total?.over : c.yes === false ? o.total?.under : undefined)
    : k.call_type === "spread" ? (c.team_id === m.home_team_id ? o.spread?.home : c.team_id === m.away_team_id ? o.spread?.away : undefined)
    : undefined;
  // a narrower call (the red card's time window) multiplies the standard price
  return p ?? (k.default_price ?? k.points / 10) * (c.pick ? k.option_mult?.[c.pick] ?? 1 : 1);
}
// points = 10 × price; a saved call keeps the price it was taken at
export const pointsFor = (price: number) => Math.round(10 * price);
export const priceOfCall = (k: Market, c: Call, m: BoardRow) => c.price ?? priceOf(k, c, m);

// the possible set scores for a best-of-N, from the home side's view: 2–0, 2–1, 1–2, 0–2
export function setScores(bestOf: number | null): Array<[number, number]> {
  const need = Math.ceil((bestOf ?? 3) / 2);
  const out: Array<[number, number]> = [];
  for (let l = 0; l < need; l++) out.push([need, l]);
  for (let l = need - 1; l >= 0; l--) out.push([l, need]);
  return out;
}

export const squadOf = (squads: Player[], teamId: number) => squads.filter((p) => p.team_id === teamId);

// the live status line for any sport
export const liveClock = (m: BoardRow) => m.clock ?? (m.minute ? `${m.minute}'` : "Live");

// Two calls that cannot both land (mirrors pool.call_conflict in 0011). A new pick replaces any call it clashes with.
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
  if ((p = pair("margin", "winner"))) return p[0].team_id !== p[1].team_id;
  if ((p = pair("sets", "winner"))) return winnerOf(p[0].home_goals!, p[0].away_goals!) !== p[1].team_id;
  if ((p = pair("sets", "distance"))) return (p[0].home_goals! + p[0].away_goals! === (m.best_of ?? 3)) !== p[1].yes;
  if (m.sport === "mma") {
    if ((p = pair("method", "winner"))) return p[0].team_id != null && p[1].team_id !== p[0].team_id;
    if ((p = pair("method", "distance"))) return (p[0].pick === "Decision") !== p[1].yes;
    if ((p = pair("round", "distance"))) return p[1].yes === true;
    if ((p = pair("round", "method"))) return p[1].pick === "Decision";
  }
  return false;
}

// what a market pays on this game: one number, or the range across its options
export function pointsRange(k: Market, m: BoardRow): string {
  const vs: Partial<Call>[] = k.call_type === "winner" ? [{ team_id: m.home_team_id }, { team_id: m.away_team_id }, ...(m.sport === "soccer" ? [{ pick: "draw" }] : [])]
    : k.call_type === "total" ? [{ yes: true }, { yes: false }]
    : k.call_type === "spread" ? [{ team_id: m.home_team_id }, { team_id: m.away_team_id }]
    : k.option_mult ? [{}, ...Object.keys(k.option_mult).map((pick) => ({ pick }))] : [{}];
  const ps = vs.map((v) => pointsFor(priceOf(k, v, m)));
  const lo = Math.min(...ps), hi = Math.max(...ps);
  return lo === hi ? String(lo) : `${lo}–${hi}`;
}
