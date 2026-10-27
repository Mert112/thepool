// §card A card, its entries and calls, and what the page needs to fill one: markets, squads, the
// crowd split and the live events. Every write is an rpc_* function in the database.
import { must, supabase } from "../../lib/supabase";
import type { Parts } from "./calls";

// The Pool is football only (0017). These are the eight live markets, plus the two kept disabled.
export type CallType = "winner" | "draw" | "motm" | "score" | "scorer" | "assist" | "yellow" | "red" | "total" | "spread";
export type Market = { options: string[] | null; call_type: CallType; title: string; short: string;
  description: string; explainer: string; simple: boolean; enabled: boolean; sort_order: number;
  settles_on: "event" | "result" };
export type Card = { id: string; match_id: number; mode: "simple" | "complex"; crew_id: string | null; created_by: string | null; status: "open" | "locked" | "live" | "settled" | "disputed"; crews?: { name: string } | null };
export type Call = { id?: string; call_type: CallType; team_id?: number | null; yes?: boolean | null; player_id?: number | null; home_goals?: number | null; away_goals?: number | null; pick?: string | null; line?: number | null; stake?: number; staked?: boolean; result?: "pending" | "hit" | "miss" | "void"; points_awarded?: number };
export type Entry = { id: string; card_id: string; user_id: string; points: number; hits: number; calls: Call[]; profiles?: { display_name: string | null; icon?: string } };
export type Player = { id: number; team_id: number | null; name: string; position: string | null };
export type MatchEvent = { id: number; type: "goal" | "yellow" | "red" | "yellow_red"; minute: number; injury_time: number | null; team_id: number; player_name: string; assist_name: string | null; own_goal: boolean; counts: boolean };
// §i18n the crowd split carries the call in pieces as well as in English, so the app can say it
// in the language the player chose (0023)
export type CrowdRow = { call_type: CallType; label: string; parts: Parts; key: string; n: number; pct: number };
export type CardPlayer = { user_id: string; display_name: string | null; n_calls: number; created_at: string };

export const getMarkets = () => must<Market[]>(supabase.from("markets").select("*").eq("enabled", true).order("sort_order"));
export const getCard = (id: string) => must<Card | null>(supabase.from("cards").select("*, crews(name)").eq("id", id).maybeSingle());
export const getCardsForMatch = (matchId: number) => must<Card[]>(supabase.from("cards").select("*, crews(name)").eq("match_id", matchId));
export const getEntries = (cardId: string) =>
  must<Entry[]>(supabase.from("entries").select("*, calls(*), profiles:user_id(display_name, icon)").eq("card_id", cardId).order("points", { ascending: false }));
export const getMyEntry = (cardId: string, userId: string) =>
  must<Entry | null>(supabase.from("entries").select("*, calls(*)").eq("card_id", cardId).eq("user_id", userId).maybeSingle());
export const getSquads = (homeId: number, awayId: number) =>
  must<Player[]>(supabase.from("players").select("id, team_id, name, position").in("team_id", [homeId, awayId]).order("name"));
export const getEvents = (matchId: number) =>
  must<MatchEvent[]>(supabase.from("match_events").select("*").eq("match_id", matchId).order("minute").order("injury_time"));
export const getCrowd = (cardId: string) => must<CrowdRow[]>(supabase.rpc("card_crowd", { p_card: cardId }), []);
export const getCardPlayers = (cardId: string) => must<CardPlayer[]>(supabase.rpc("card_players", { p_card: cardId }), []);
export const openCard = (matchId: number, mode: "simple" | "complex", crewId: string | null) =>
  must<string>(supabase.rpc("rpc_open_card", { p_match: matchId, p_mode: mode, p_crew: crewId }));
export const saveCalls = (cardId: string, calls: Call[]) => must<string>(supabase.rpc("rpc_save_calls", { p_card: cardId, p_calls: calls }));
