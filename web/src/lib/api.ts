// Thin data layer over Supabase. Every write goes through an rpc_* function in the database.
import { supabase } from "./supabase";

export type CallType = "winner" | "draw" | "motm" | "score" | "scorer" | "assist" | "yellow" | "red" | "total" | "margin" | "top_scorer" | "sets" | "distance" | "method" | "round";
export type Sport = { code: string; name: string; sort_order: number };
export type Market = { sport: string; options: string[] | null; call_type: CallType; title: string; short: string; description: string; points: number; simple: boolean; enabled: boolean; sort_order: number; settles_on: "event" | "result" };
export type BoardRow = {
  match_id: number; competition_code: string; competition_name: string; season: string | null; utc_date: string; status: string; minute: number | null;
  home_score: number | null; away_score: number | null; ft_home: number | null; ft_away: number | null; duration: string | null;
  home_team_id: number; home_team: string; home_short: string | null; home_crest: string | null;
  away_team_id: number; away_team: string; away_short: string | null; away_crest: string | null;
  public_card_id: string | null; public_card_mode: "simple" | "complex" | null; public_card_status: string | null;
  card_count: number; playing: number; phase: "live" | "upcoming" | "settled";
  sport: string; sport_name: string; clock: string | null; event_name: string | null; home_periods: number[] | null; away_periods: number[] | null;
  total_line: number | null; best_of: number | null; result_detail: { winner?: string; method?: string; round?: string; retired?: boolean };
};
export type Card = { id: string; match_id: number; mode: "simple" | "complex"; crew_id: string | null; created_by: string | null; status: "open" | "locked" | "live" | "settled" | "disputed"; crews?: { name: string } | null };
export type Call = { id?: string; call_type: CallType; team_id?: number | null; yes?: boolean | null; player_id?: number | null; home_goals?: number | null; away_goals?: number | null; pick?: string | null; line?: number | null; result?: "pending" | "hit" | "miss" | "void"; points_awarded?: number };
export type Entry = { id: string; card_id: string; user_id: string; boost_call_type: CallType | null; points: number; hits: number; calls: Call[]; profiles?: { display_name: string | null } };
export type Player = { id: number; team_id: number | null; name: string; position: string | null };
export type Crew = { id: string; name: string; description: string | null; mode: "simple" | "complex"; owner_id: string; rival_crew_id: string | null; created_at: string };
export type Profile = { id: string; display_name: string | null; streak: number };
export type MatchEvent = { id: number; type: "goal" | "yellow" | "red" | "yellow_red"; minute: number; injury_time: number | null; team_id: number; player_name: string; assist_name: string | null; own_goal: boolean; counts: boolean };

const fail = (e: any) => { throw new Error(e?.message ?? String(e)); };

// markets for one sport (a card's), or every sport's when omitted
export async function getMarkets(sport?: string): Promise<Market[]> {
  let q = supabase.from("markets").select("*").eq("enabled", true);
  if (sport) q = q.eq("sport", sport);
  const { data, error } = await q.order("sort_order");
  if (error) fail(error);
  return data as Market[];
}

export async function getSports(): Promise<Sport[]> {
  const { data, error } = await supabase.from("sports").select("*").order("sort_order");
  if (error) fail(error);
  return data as Sport[];
}

// The board: two days back to a week out, optionally one sport. Paged past the API's 1000-row cap.
export async function getBoard(sport?: string): Promise<BoardRow[]> {
  const from = new Date(Date.now() - 2 * 86400000).toISOString();
  const to = new Date(Date.now() + 8 * 86400000).toISOString();
  const rows: BoardRow[] = [];
  for (let page = 0; page < 10; page++) {
    let q = supabase.from("v_board").select("*").gte("utc_date", from).lte("utc_date", to);
    if (sport) q = q.eq("sport", sport);
    const { data, error } = await q.order("utc_date").order("match_id").range(page * 1000, page * 1000 + 999);
    if (error) fail(error);
    rows.push(...(data as BoardRow[]));
    if ((data ?? []).length < 1000) break;
  }
  return rows;
}

// live games per sport, for the counts on the sport filter
export async function getLiveCounts(): Promise<Record<string, number>> {
  const { data, error } = await supabase.from("v_board").select("sport").eq("phase", "live");
  if (error) fail(error);
  const out: Record<string, number> = {};
  for (const r of (data ?? []) as Array<{ sport: string }>) out[r.sport] = (out[r.sport] ?? 0) + 1;
  return out;
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
export async function setBoost(cardId: string, call: CallType | null) {
  const { error } = await supabase.rpc("rpc_set_boost", { p_card: cardId, p_call: call });
  if (error) fail(error);
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
  return (data ?? []) as Array<{ user_id: string; role: string; joined_at: string; profiles: { display_name: string | null } }>;
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
  return (data ?? []) as Array<{ id: string; body: string | null; created_at: string; user_id: string; profiles: { display_name: string | null }; calls: { call_type: CallType; points_awarded: number } | null }>;
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
export type LbRow = { user_id: string; display_name: string | null; points: number; points_prev: number; cards: number; hits: number; calls: number; hit_rate: number; best_call: CallType | null; best_points: number | null };
export async function leaderboard(scope: "overall" | "competition" | "crew" | "week" | "sport", key?: string): Promise<LbRow[]> {
  const { data, error } = await supabase.rpc("leaderboard", { p_scope: scope, p_key: key ?? null });
  if (error) fail(error);
  return (data ?? []) as LbRow[];
}
export async function myStats() {
  const { data, error } = await supabase.rpc("my_stats");
  if (error) fail(error);
  return data as { points: number; rank: number | null; players: number; cards: number; hit_rate: number; streak: number; competitions: Array<{ code: string; name: string; points: number; rank: number }>; recent: Array<{ match_id: number; home: string; away: string; home_score: number; away_score: number; utc_date: string; points: number; hits: number; mode: string; competition_code: string }> };
}
export async function getStickers() {
  const { data, error } = await supabase.from("stickers").select("competition_code, season, call_type, earned_at");
  if (error) fail(error);
  return (data ?? []) as Array<{ competition_code: string; season: string; call_type: CallType; earned_at: string }>;
}
export async function getCompetitions() {
  const { data, error } = await supabase.from("competitions").select("code, name, season, sort_order, sport").eq("active", true).order("sort_order");
  if (error) fail(error);
  return (data ?? []) as Array<{ code: string; name: string; season: string | null; sort_order: number; sport: string }>;
}

// profile & settings
export async function getProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await supabase.from("profiles").select("id, display_name, streak").eq("id", userId).maybeSingle();
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
