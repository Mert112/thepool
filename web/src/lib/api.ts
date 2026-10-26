// Thin data layer over Supabase. Every write goes through an rpc_* function in the database.
import { supabase } from "./supabase";

// The Pool is football only (0017). These are the eight live markets, plus the two kept disabled.
export type CallType = "winner" | "draw" | "motm" | "score" | "scorer" | "assist" | "yellow" | "red" | "total" | "spread";
export type Market = { options: string[] | null; call_type: CallType; title: string; short: string;
  description: string; explainer: string; simple: boolean; enabled: boolean; sort_order: number;
  settles_on: "event" | "result" };
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
// decimal prices from the feed (frozen at the start)
export type Odds = { provider?: string | null; home?: number; away?: number; draw?: number;
  spread?: { home_line: number; home: number; away: number }; total?: { line: number; over: number; under: number } };
export type Card = { id: string; match_id: number; mode: "simple" | "complex"; crew_id: string | null; created_by: string | null; status: "open" | "locked" | "live" | "settled" | "disputed"; crews?: { name: string } | null };
export type Call = { id?: string; call_type: CallType; team_id?: number | null; yes?: boolean | null; player_id?: number | null; home_goals?: number | null; away_goals?: number | null; pick?: string | null; line?: number | null; stake?: number; staked?: boolean; result?: "pending" | "hit" | "miss" | "void"; points_awarded?: number };
export type Entry = { id: string; card_id: string; user_id: string; points: number; hits: number; calls: Call[]; profiles?: { display_name: string | null } };
// the five stakes a call can carry, from pool.stakes
export const STAKES = [1, 2, 5, 10, 25, 50] as const;
export type Player = { id: number; team_id: number | null; name: string; position: string | null };
export type Crew = { id: string; name: string; description: string | null; mode: "simple" | "complex"; owner_id: string; rival_crew_id: string | null; created_at: string };
export type Profile = { id: string; display_name: string | null; streak: number; balance: number };
export type MatchEvent = { id: number; type: "goal" | "yellow" | "red" | "yellow_red"; minute: number; injury_time: number | null; team_id: number; player_name: string; assist_name: string | null; own_goal: boolean; counts: boolean };

const fail = (e: any) => { throw new Error(e?.message ?? String(e)); };

// every market on the card
export async function getMarkets(): Promise<Market[]> {
  const { data, error } = await supabase.from("markets").select("*").eq("enabled", true).order("sort_order");
  if (error) fail(error);
  return data as Market[];
}

// The board: two days back to a week out. Paged past the API's 1000-row cap.
export async function getBoard(): Promise<BoardRow[]> {
  const from = new Date(Date.now() - 2 * 86400000).toISOString();
  const to = new Date(Date.now() + 8 * 86400000).toISOString();
  const rows: BoardRow[] = [];
  for (let page = 0; page < 10; page++) {
    const { data, error } = await supabase.from("v_board").select("*").gte("utc_date", from).lte("utc_date", to)
      .order("utc_date").order("match_id").range(page * 1000, page * 1000 + 999);
    if (error) fail(error);
    rows.push(...(data as BoardRow[]));
    if ((data ?? []).length < 1000) break;
  }
  return rows;
}

export async function getMatches(ids: number[]): Promise<BoardRow[]> {
  if (ids.length === 0) return [];
  const { data, error } = await supabase.from("v_board").select("*").in("match_id", ids);
  if (error) fail(error);
  return data as BoardRow[];
}

export async function getMatch(id: number): Promise<BoardRow | null> {
  const { data, error } = await supabase.from("v_board").select("*").eq("match_id", id).maybeSingle();
  if (error) fail(error);
  return data as BoardRow | null;
}

export async function getCard(id: string): Promise<Card | null> {
  const { data, error } = await supabase.from("cards").select("*, crews(name)").eq("id", id).maybeSingle();
  if (error) fail(error);
  return data as Card | null;
}

export async function getCardsForMatch(matchId: number): Promise<Card[]> {
  const { data, error } = await supabase.from("cards").select("*, crews(name)").eq("match_id", matchId);
  if (error) fail(error);
  return data as Card[];
}

export async function getEntries(cardId: string): Promise<Entry[]> {
  const { data, error } = await supabase.from("entries").select("*, calls(*), profiles:user_id(display_name)").eq("card_id", cardId).order("points", { ascending: false });
  if (error) fail(error);
  return data as Entry[];
}

export async function getMyEntry(cardId: string, userId: string): Promise<Entry | null> {
  const { data, error } = await supabase.from("entries").select("*, calls(*)").eq("card_id", cardId).eq("user_id", userId).maybeSingle();
  if (error) fail(error);
  return data as Entry | null;
}

export async function getSquads(homeId: number, awayId: number): Promise<Player[]> {
  const { data, error } = await supabase.from("players").select("id, team_id, name, position").in("team_id", [homeId, awayId]).order("name");
  if (error) fail(error);
  return data as Player[];
}

export async function getEvents(matchId: number): Promise<MatchEvent[]> {
  const { data, error } = await supabase.from("match_events").select("*").eq("match_id", matchId).order("minute").order("injury_time");
  if (error) fail(error);
  return data as MatchEvent[];
}

export async function getCrowd(cardId: string) {
  const { data, error } = await supabase.rpc("card_crowd", { p_card: cardId });
  if (error) fail(error);
  return (data ?? []) as Array<{ call_type: CallType; label: string; key: string; n: number; pct: number }>;
}

export async function openCard(matchId: number, mode: "simple" | "complex", crewId: string | null) {
  const { data, error } = await supabase.rpc("rpc_open_card", { p_match: matchId, p_mode: mode, p_crew: crewId });
  if (error) fail(error);
  return data as string;
}
export async function saveCalls(cardId: string, calls: Call[]) {
  const { data, error } = await supabase.rpc("rpc_save_calls", { p_card: cardId, p_calls: calls });
  if (error) fail(error);
  return data as string;
}
// §4 what is in each pot on this card right now, and what a point staked on each pick would
// return if that pick came in at the current split. Aggregate only, like the crowd split.
export type PotRow = { call_type: CallType; key: string; label: string; pick_stake: number;
  pot: number; jackpot: number; purse: number; per_point: number };
export async function getCardPots(cardId: string): Promise<PotRow[]> {
  const { data, error } = await supabase.rpc("card_pots", { p_card: cardId });
  if (error) fail(error);
  return ((data ?? []) as any[]).map((r) => ({
    ...r, pick_stake: Number(r.pick_stake), pot: Number(r.pot), jackpot: Number(r.jackpot),
    purse: Number(r.purse), per_point: Number(r.per_point),
  })) as PotRow[];
}

// §1 the jackpot standing on each call type in a competition: what a card nobody landed rolled
// forward, less the rake. Added to whoever lands that call next.
export async function getJackpots(competition: string): Promise<Partial<Record<CallType, number>>> {
  const { data, error } = await supabase.from("jackpots").select("call_type, amount").eq("competition_code", competition).gt("amount", 0);
  if (error) fail(error);
  const out: Partial<Record<CallType, number>> = {};
  for (const r of (data ?? []) as Array<{ call_type: CallType; amount: number }>) out[r.call_type] = r.amount;
  return out;
}

// feature flags (pool.app_flags): the rewarded-ad stub hides behind one
export async function getFlag(key: string): Promise<boolean> {
  const { data, error } = await supabase.from("app_flags").select("enabled").eq("key", key).maybeSingle();
  if (error) fail(error);
  return !!(data as { enabled: boolean } | null)?.enabled;
}

// §4 the point economy — every balance movement happens inside one of these
export async function watchAd(): Promise<{ credited: number; watched_today: number; left_today: number; balance: number }> {
  const { data, error } = await supabase.rpc("rpc_watch_ad");
  if (error) fail(error);
  return data as { credited: number; watched_today: number; left_today: number; balance: number };
}
export async function claimPrize(): Promise<string> {
  const { data, error } = await supabase.rpc("rpc_claim_prize");
  if (error) fail(error);
  return data as string;
}
export async function myCommittedStake(): Promise<number> {
  const { data, error } = await supabase.rpc("my_committed_stake");
  if (error) fail(error);
  return Number(data ?? 0);
}
export type LedgerRow = { amount: number; reason: "signup" | "adjustment" | "stake" | "pot" | "jackpot" | "refund" | "ad_reward" | "prize"; created_at: string };
export async function myLedger(limit = 30): Promise<LedgerRow[]> {
  const { data, error } = await supabase.rpc("my_ledger", { p_limit: limit });
  if (error) fail(error);
  return (data ?? []) as LedgerRow[];
}

// crews — only these columns are readable (the invite code comes from crew_invite_code())
const CREW_COLS = "id, name, description, mode, owner_id, rival_crew_id, created_at";
export async function getMyCrews(): Promise<Crew[]> {
  const { data: u } = await supabase.auth.getUser();
  const { data, error } = await supabase.from("crew_members").select(`crews(${CREW_COLS})`).eq("user_id", u.user?.id ?? "").order("joined_at");
  if (error) fail(error);
  return (data ?? []).map((r: any) => r.crews).filter(Boolean) as Crew[];
}
export async function getCrew(id: string): Promise<Crew | null> {
  const { data, error } = await supabase.from("crews").select(CREW_COLS).eq("id", id).maybeSingle();
  if (error) fail(error);
  return data as Crew | null;
}
export async function getCrewInviteCode(id: string): Promise<string | null> {
  const { data, error } = await supabase.rpc("crew_invite_code", { p_crew: id });
  if (error) fail(error);
  return (data as string | null) ?? null;
}
export type CardPlayer = { user_id: string; display_name: string | null; n_calls: number; created_at: string };
export async function getCardPlayers(cardId: string): Promise<CardPlayer[]> {
  const { data, error } = await supabase.rpc("card_players", { p_card: cardId });
  if (error) fail(error);
  return (data ?? []) as CardPlayer[];
}
export async function getCrewMembers(id: string) {
  const { data, error } = await supabase.from("crew_members").select("user_id, role, joined_at, profiles:user_id(display_name)").eq("crew_id", id);
  if (error) fail(error);
  return (data ?? []) as unknown as Array<{ user_id: string; role: string; joined_at: string; profiles: { display_name: string | null } }>;
}
export async function getCrewCards(crewId: string): Promise<Array<Card & { players: CardPlayer[] }>> {
  const { data, error } = await supabase.from("cards").select("*").eq("crew_id", crewId).in("status", ["open", "locked", "live"]);
  if (error) fail(error);
  const cards = (data ?? []) as Card[];
  const players = await Promise.all(cards.map((c) => getCardPlayers(c.id)));
  return cards.map((c, i) => ({ ...c, players: players[i] }));
}
export async function getCrewPosts(crewId: string) {
  const { data, error } = await supabase.from("crew_posts").select("id, body, created_at, user_id, profiles:user_id(display_name), calls(call_type, points_awarded)").eq("crew_id", crewId).order("created_at", { ascending: false }).limit(40);
  if (error) fail(error);
  return (data ?? []) as unknown as Array<{ id: string; body: string | null; created_at: string; user_id: string; profiles: { display_name: string | null }; calls: { call_type: CallType; points_awarded: number } | null }>;
}
export async function crewScore(crewId: string): Promise<number> {
  const { data, error } = await supabase.rpc("crew_score", { p_crew: crewId });
  if (error) fail(error);
  return Number(data ?? 0);
}
export async function createCrew(name: string, description: string, mode: "simple" | "complex") {
  const { data, error } = await supabase.rpc("rpc_create_crew", { p_name: name, p_description: description, p_mode: mode });
  if (error) fail(error);
  return data as string;
}
export async function joinCrew(code: string) {
  const { data, error } = await supabase.rpc("rpc_join_crew", { p_code: code });
  if (error) fail(error);
  return data as string;
}
export async function post(crewId: string, body: string) {
  const { error } = await supabase.rpc("rpc_post", { p_crew: crewId, p_body: body });
  if (error) fail(error);
}
export async function challengeCrew(crewId: string, code: string) {
  const { error } = await supabase.rpc("rpc_challenge_crew", { p_crew: crewId, p_rival_code: code });
  if (error) fail(error);
}

// standings
export type LbRow = { user_id: string; display_name: string | null; balance: number; points: number; points_prev: number; cards: number; hits: number; calls: number; hit_rate: number; best_call: CallType | null; best_points: number | null };
export async function leaderboard(scope: "overall" | "competition" | "crew" | "week", key?: string): Promise<LbRow[]> {
  const { data, error } = await supabase.rpc("leaderboard", { p_scope: scope, p_key: key ?? null });
  if (error) fail(error);
  return (data ?? []) as LbRow[];
}
export type Stats = {
  balance: number; points: number; rank: number | null; players: number; cards: number; hit_rate: number; streak: number;
  committed: number; ads_today: number; ads_left: number; ad_reward: number; ads_enabled: boolean; prize_target: number;
  prize_claim: { id: string; status: "pending" | "approved" | "rejected" | "fulfilled"; created_at: string } | null;
  competitions: Array<{ code: string; name: string; points: number; rank: number }>;
};
export async function myStats(): Promise<Stats> {
  const { data, error } = await supabase.rpc("my_stats");
  if (error) fail(error);
  return data as Stats;
}
// the matches this player already has a card on, so the board can say so
export async function getMyCardMatches(userId: string): Promise<Set<number>> {
  const { data, error } = await supabase.from("entries").select("cards!inner(match_id)").eq("user_id", userId);
  if (error) fail(error);
  return new Set((data ?? []).map((r: any) => r.cards?.match_id as number).filter((n) => typeof n === "number"));
}

// §5.8 Prediction history: every card played, newest first, with each call and how it ended
export type HistoryCall = { call_type: CallType; title: string; label: string; result: "pending" | "hit" | "miss" | "void"; points: number };
export type HistoryCard = {
  entry_id: string; card_id: string; match_id: number; mode: "simple" | "complex"; crew: string | null;
  card_status: Card["status"]; competition: string; utc_date: string;
  home: string; away: string; home_score: number | null; away_score: number | null;
  points: number; hits: number; calls: HistoryCall[];
};
export async function myHistory(limit = 40): Promise<HistoryCard[]> {
  const { data, error } = await supabase.rpc("my_history", { p_limit: limit });
  if (error) fail(error);
  return (data ?? []) as HistoryCard[];
}

export async function getStickers() {
  const { data, error } = await supabase.from("stickers").select("competition_code, season, call_type, earned_at");
  if (error) fail(error);
  return (data ?? []) as Array<{ competition_code: string; season: string; call_type: CallType; earned_at: string }>;
}
export async function getCompetitions() {
  const { data, error } = await supabase.from("competitions").select("code, name, season, sort_order").eq("active", true).order("sort_order");
  if (error) fail(error);
  return (data ?? []) as Array<{ code: string; name: string; season: string | null; sort_order: number }>;
}

// profile & settings
export async function getProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await supabase.from("profiles").select("id, display_name, streak, balance").eq("id", userId).maybeSingle();
  if (error) fail(error);
  return data as Profile | null;
}
export async function setDisplayName(name: string) {
  const { error } = await supabase.rpc("rpc_set_display_name", { p_name: name });
  if (error) fail(error);
}
export type Settings = { new_card: boolean; deadline_reminder: boolean; crew_activity: boolean; result: boolean; weekly_digest: boolean; watched_competitions: string[] };
export async function getSettings(userId: string): Promise<Settings> {
  const { data, error } = await supabase.from("notification_settings").select("*").eq("user_id", userId).single();
  if (error) fail(error);
  return data as Settings;
}
export async function saveSettings(userId: string, s: Partial<Settings>) {
  const { error } = await supabase.from("notification_settings").update(s).eq("user_id", userId);
  if (error) fail(error);
}
