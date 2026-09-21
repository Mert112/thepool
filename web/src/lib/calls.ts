// How a call reads on screen, for every sport's markets.
import type { BoardRow, Call, Market, Player } from "./api";

export const teamName = (m: BoardRow, t: number | null | undefined) => (t === m.home_team_id ? m.home_team : t === m.away_team_id ? m.away_team : "");

export function pickText(c: Call | undefined, m: BoardRow, playerName: (id: number | null | undefined) => string): string {
  if (!c) return "No pick";
  switch (c.call_type) {
    case "winner": return teamName(m, c.team_id);
    case "draw": case "distance": return c.yes ? "Yes" : "No";
    case "total": return `${c.yes ? "Over" : "Under"} ${c.line ?? m.total_line ?? ""}`.trim();
    case "score": case "sets": return `${c.home_goals}–${c.away_goals}`;
    case "margin": return `${teamName(m, c.team_id)} by ${c.pick}`;
    case "method": return c.pick ?? "";
    case "round": return `Round ${c.pick}`;
    default: return playerName(c.player_id) || "Player";
  }
}

// player markets pick a name from either squad
export const isPlayerMarket = (k: Market) => ["scorer", "assist", "yellow", "red", "motm", "top_scorer"].includes(k.call_type);

// a market the card can offer for this game (an over/under needs a posted line)
export const offered = (k: Market, m: BoardRow) => k.call_type !== "total" || m.total_line != null;

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
