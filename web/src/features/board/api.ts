// §board The board's rows (v_board), and "My leagues": which competitions this account follows.
import { must, supabase } from "../../lib/supabase";

export type Odds = { provider?: string | null; home?: number; away?: number; draw?: number;
  spread?: { home_line: number; home: number; away: number }; total?: { line: number; over: number; under: number } };
export type BoardRow = {
  match_id: number; competition_code: string; competition_name: string; season: string | null; utc_date: string; status: string; minute: number | null;
  home_score: number | null; away_score: number | null; ft_home: number | null; ft_away: number | null; duration: string | null;
  home_team_id: number; home_team: string; home_short: string | null; home_crest: string | null;
  away_team_id: number; away_team: string; away_short: string | null; away_crest: string | null;
  public_card_id: string | null; public_card_mode: "simple" | "complex" | null; public_card_status: string | null;
  card_count: number; playing: number; phase: "live" | "upcoming" | "settled";
  clock: string | null; event_name: string | null; total_line: number | null;
  result_detail: { winner?: string };
  odds: Odds;
};

// a week back (the Settled tab) to a week out, paged past the API's 1000-row cap
export async function getBoard(): Promise<BoardRow[]> {
  const from = new Date(Date.now() - 7 * 86400000).toISOString();
  const to = new Date(Date.now() + 8 * 86400000).toISOString();
  const rows: BoardRow[] = [];
  for (let page = 0; page < 10; page++) {
    const data = await must<BoardRow[]>(supabase.from("v_board").select("*").gte("utc_date", from).lte("utc_date", to)
      .order("utc_date").order("match_id").range(page * 1000, page * 1000 + 999), []);
    rows.push(...data);
    if (data.length < 1000) break;
  }
  return rows;
}
export const getMatches = async (ids: number[]) =>
  ids.length === 0 ? [] : must<BoardRow[]>(supabase.from("v_board").select("*").in("match_id", ids));
export const getMatch = (id: number) => must<BoardRow | null>(supabase.from("v_board").select("*").eq("match_id", id).maybeSingle());

// the matches this player already has a card on, so the board can say so
export async function getMyCardMatches(userId: string): Promise<Set<number>> {
  const rows = await must<Array<{ cards: { match_id: number } | null }>>(supabase.from("entries").select("cards!inner(match_id)").eq("user_id", userId), []);
  return new Set(rows.map((r) => r.cards?.match_id).filter((n): n is number => typeof n === "number"));
}
export const getCompetitions = () => must<Array<{ code: string; name: string; season: string | null; sort_order: number }>>(
  supabase.from("competitions").select("code, name, season, sort_order").eq("active", true).order("sort_order"), []);

// §provider Twelve club competitions plus Türkiye's and Bulgaria's national-team matches are on for
// a new account; the rest of the provider's ~1,250 leagues live under "More leagues" (0024).
export type Following = { code: string; name: string; country: string | null; type: "league" | "cup" | null;
  tier: number | null; flag_url: string | null; emblem_url: string | null; default: boolean; sort_order: number };
export type CountryRow = { country: string; flag_url: string | null; n: number };
export type LeagueRow = Following & { following: boolean };
export const myCompetitions = () =>
  must<{ following: Following[]; countries: CountryRow[] }>(supabase.rpc("my_competitions"), { following: [], countries: [] });
export const competitionsIn = (country: string) => must<LeagueRow[]>(supabase.rpc("competitions_in", { p_country: country }), []);
export const followCompetition = (code: string) => must<void>(supabase.rpc("rpc_follow_competition", { p_code: code }));
export const unfollowCompetition = (code: string) => must<void>(supabase.rpc("rpc_unfollow_competition", { p_code: code }));
