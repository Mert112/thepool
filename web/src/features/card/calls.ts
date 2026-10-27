// How a call reads on screen. Football only (0017), and in three languages (§i18n).
//
// A call is never turned into a sentence anywhere but here. `partsOf` breaks a pick into the
// pieces that mean something — the team, the player, the line, the scoreline — and `labelOf`
// says them in the language the app is speaking. The database sends the same pieces for calls
// other people made (pool.call_parts, 0023), so a crowd split and a history row read the same
// as the card they came from. Team and player names are the provider's and pass through as given.
import type { BoardRow } from "../board/api";
import type { Call, CallType, Market, Player } from "./api";
import type { Dict } from "../../lib/i18n/en";

export const teamName = (m: BoardRow, t: number | null | undefined) => (t === m.home_team_id ? m.home_team : t === m.away_team_id ? m.away_team : "");

// mirrors pool.call_parts(): what a call is made of, before anyone puts words round it
export type Parts = {
  call_type: CallType;
  team?: string;
  side?: "home" | "away";
  player?: string;
  yes?: boolean;
  line?: string;
  home_goals?: number;
  away_goals?: number;
  pick?: string;          // 'draw' on a result call, a minute window on a red card
};

export function partsOf(c: Call, m: BoardRow, playerName: (id: number | null | undefined) => string): Parts {
  const line = c.call_type === "total" ? c.line ?? lineOf(m) : c.call_type === "spread" ? c.line ?? spreadFor(m, c.team_id) : c.line;
  return {
    call_type: c.call_type,
    team: c.team_id != null ? teamName(m, c.team_id) || undefined : undefined,
    side: c.team_id === m.home_team_id ? "home" : c.team_id === m.away_team_id ? "away" : undefined,
    player: c.player_id != null ? playerName(c.player_id) || undefined : undefined,
    yes: c.yes ?? undefined,
    line: line == null ? undefined : String(line),
    home_goals: c.home_goals ?? undefined,
    away_goals: c.away_goals ?? undefined,
    pick: c.pick ?? undefined,
  };
}

export function labelOf(p: Parts | null | undefined, t: Dict): string {
  if (!p) return t.pick.none;
  switch (p.call_type) {
    case "winner": return p.pick === "draw" ? t.pick.draw : p.team ?? "";
    case "draw":   return p.yes ? t.pick.drawYes : t.pick.drawNo;
    case "total":  return (p.yes ? t.pick.over : t.pick.under)(p.line ?? "").trim();
    case "spread": return t.pick.handicap(p.team ?? "", p.line == null ? "" : signed(Number(p.line))).trim();
    case "score":  return t.pick.scoreline(p.home_goals ?? 0, p.away_goals ?? 0);
    default:       return p.pick
      ? t.pick.playerWindow(p.player ?? t.common.player, p.pick)
      : t.pick.player(p.player ?? t.common.player);
  }
}

// one saved call, in the player's language
export const pickText = (c: Call | undefined, m: BoardRow, playerName: (id: number | null | undefined) => string, t: Dict) =>
  c ? labelOf(partsOf(c, m, playerName), t) : t.pick.none;

// player markets pick a name from either squad
export const isPlayerMarket = (k: Market) => ["scorer", "assist", "yellow", "red", "motm"].includes(k.call_type);

export const signed = (n: number) => (n > 0 ? `+${n}` : `${n}`);
export const lineOf = (m: BoardRow) => m.odds?.total?.line ?? m.total_line;
export const spreadFor = (m: BoardRow, team: number | null | undefined) => { const hl = m.odds?.spread?.home_line; return hl == null ? null : team === m.home_team_id ? hl : -hl; };

// a market the card can offer for this match: an over/under needs a goals line, a handicap needs one on the board
export const offered = (k: Market, m: BoardRow) =>
  k.call_type === "total" ? lineOf(m) != null : k.call_type === "spread" ? m.odds?.spread?.home_line != null : true;

// §i18n the title, the one-liner and the short form live in the translation files, keyed on the
// call type. The database keeps the English, which is what a language we do not speak falls back to.
export const marketTitle = (k: Market, t: Dict) => t.markets[k.call_type]?.title ?? k.title;
export const marketShort = (k: Market, t: Dict) => t.markets[k.call_type]?.short ?? k.short;
export const marketExplainer = (k: Market, t: Dict) => t.markets[k.call_type]?.explainer ?? k.explainer;

// what a pick returns per point staked, at the split as it stands
export const perPoint = (purse: number, pickStake: number) =>
  pickStake > 0 ? Math.floor((purse / pickStake) * 100) / 100 : null;

export const squadOf = (squads: Player[], teamId: number) => squads.filter((p) => p.team_id === teamId);

// the live status line
export const liveClock = (m: BoardRow, t: Dict) => m.clock ?? (m.minute ? `${m.minute}'` : t.when.inPlay);

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
