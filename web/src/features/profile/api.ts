// §profile The player: profile, icons, history, stickers, settings and language.
import { must, supabase } from "../../lib/supabase";
import type { Lang } from "../../lib/i18n/lang";
import type { Card, CallType } from "../card/api";
import type { Parts } from "../card/calls";

export type Profile = { id: string; display_name: string | null; streak: number; balance: number; icon: string; language: Lang | null };
export const getProfile = (userId: string) =>
  must<Profile | null>(supabase.from("profiles").select("id, display_name, streak, balance, icon, language").eq("id", userId).maybeSingle());
export const setDisplayName = (name: string) => must<void>(supabase.rpc("rpc_set_display_name", { p_name: name }));
// §i18n the choice follows the player, so the mails match the screen
export const setLanguage = (lang: Lang) => must<void>(supabase.rpc("rpc_set_language", { p_lang: lang }));

// §profile icons — ten of them, nine earned. The catalogue lives in pool.icons; the glyph map in
// components/ui.tsx mirrors it so an avatar can render without waiting for a fetch.
export type Rarity = "common" | "uncommon" | "rare" | "epic" | "legendary";
export type IconRow = { code: string; name: string; rarity: Rarity; how: string; glyph: string;
  sort_order: number; earned_at: string | null; wearing: boolean };
export const myIcons = () => must<IconRow[]>(supabase.rpc("my_icons"), []);
export const setIcon = (code: string) => must<void>(supabase.rpc("rpc_set_icon", { p_code: code }));
export const refreshIcons = () => must<string[]>(supabase.rpc("rpc_refresh_icons"), []);

// §5.8 every card played, newest first, with each call and how it ended
export type HistoryCall = { call_type: CallType; title: string; label: string; parts: Parts; result: "pending" | "hit" | "miss" | "void"; points: number };
export type HistoryCard = {
  entry_id: string; card_id: string; match_id: number; mode: "simple" | "complex"; crew: string | null;
  card_status: Card["status"]; competition: string; utc_date: string;
  home: string; away: string; home_score: number | null; away_score: number | null;
  points: number; hits: number; calls: HistoryCall[];
};
export const myHistory = (limit = 40) => must<HistoryCard[]>(supabase.rpc("my_history", { p_limit: limit }), []);
export const getStickers = () => must<Array<{ competition_code: string; season: string; call_type: CallType; earned_at: string }>>(
  supabase.from("stickers").select("competition_code, season, call_type, earned_at"), []);

export type Settings = { new_card: boolean; deadline_reminder: boolean; crew_activity: boolean; result: boolean; weekly_digest: boolean; watched_competitions: string[] };
export const getSettings = (userId: string) => must<Settings>(supabase.from("notification_settings").select("*").eq("user_id", userId).single());
export const saveSettings = (userId: string, s: Partial<Settings>) => must<void>(supabase.from("notification_settings").update(s).eq("user_id", userId));
