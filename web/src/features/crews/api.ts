// §crews Crews, their members, cards and feed. Only these columns are readable; the invite code
// comes from crew_invite_code(), so it is never in a row anyone can list.
import { must, supabase } from "../../lib/supabase";
import { getCardPlayers, listedCards, type Card, type CallType, type CardPlayer } from "../card/api";

export type Crew = { id: string; name: string; description: string | null; mode: "simple" | "complex"; owner_id: string; rival_crew_id: string | null; created_at: string };
const CREW_COLS = "id, name, description, mode, owner_id, rival_crew_id, created_at";
type Who = { display_name: string | null; icon?: string };

export async function getMyCrews(): Promise<Crew[]> {
  const { data: u } = await supabase.auth.getUser();
  const rows = await must<Array<{ crews: Crew | null }>>(supabase.from("crew_members").select(`crews(${CREW_COLS})`).eq("user_id", u.user?.id ?? "").order("joined_at"), []);
  return rows.map((r) => r.crews).filter((c): c is Crew => !!c);
}
export const getCrew = (id: string) => must<Crew | null>(supabase.from("crews").select(CREW_COLS).eq("id", id).maybeSingle());
export const getCrewInviteCode = (id: string) => must<string | null>(supabase.rpc("crew_invite_code", { p_crew: id }), null);
export const getCrewMembers = (id: string) => must<Array<{ user_id: string; role: string; joined_at: string; profiles: Who }>>(
  supabase.from("crew_members").select("user_id, role, joined_at, profiles:user_id(display_name, icon)").eq("crew_id", id), []);
export async function getCrewCards(crewId: string): Promise<Array<Card & { players: CardPlayer[] }>> {
  const cards = await must<Card[]>(supabase.from("cards").select("*").eq("crew_id", crewId).in("status", ["open", "locked", "live"]).or(await listedCards()), []);
  const players = await Promise.all(cards.map((c) => getCardPlayers(c.id)));
  return cards.map((c, i) => ({ ...c, players: players[i] }));
}
export const getCrewPosts = (crewId: string) => must<Array<{ id: string; body: string | null; created_at: string; user_id: string; profiles: Who; calls: { call_type: CallType; points_awarded: number } | null }>>(
  supabase.from("crew_posts").select("id, body, created_at, user_id, profiles:user_id(display_name, icon), calls(call_type, points_awarded)").eq("crew_id", crewId).order("created_at", { ascending: false }).limit(40), []);
export const crewScore = async (crewId: string) => Number(await must<number | null>(supabase.rpc("crew_score", { p_crew: crewId }), 0));
export const createCrew = (name: string, description: string, mode: "simple" | "complex") =>
  must<string>(supabase.rpc("rpc_create_crew", { p_name: name, p_description: description, p_mode: mode }));
export const joinCrew = (code: string) => must<string>(supabase.rpc("rpc_join_crew", { p_code: code }));
export const post = (crewId: string, body: string) => must<void>(supabase.rpc("rpc_post", { p_crew: crewId, p_body: body }));
export const challengeCrew = (crewId: string, code: string) => must<void>(supabase.rpc("rpc_challenge_crew", { p_crew: crewId, p_rival_code: code }));
