// §economy Points: the pots on a card, the jackpots, the ledger, the standings and the prize.
// Every balance movement happens inside a database function; nothing here moves a point.
import { must, supabase } from "../../lib/supabase";
import type { CallType } from "../card/api";

// the quick-pick stakes, as in pool.stakes. Any whole number from 1 is a stake (0027).
export const STAKES = [1, 5, 10, 25, 50] as const;

// §4 what is in each pot on this card right now, and what a point staked on each pick would
// return if that pick came in at the current split. Aggregate only, like the crowd split.
export type PotRow = { call_type: CallType; key: string; label: string; pick_stake: number;
  pot: number; jackpot: number; purse: number; per_point: number };
export async function getCardPots(cardId: string): Promise<PotRow[]> {
  const rows = await must<Array<Record<string, unknown>>>(supabase.rpc("card_pots", { p_card: cardId }), []);
  return rows.map((r) => ({ ...r, pick_stake: Number(r.pick_stake), pot: Number(r.pot), jackpot: Number(r.jackpot),
    purse: Number(r.purse), per_point: Number(r.per_point) })) as PotRow[];
}
// §1 what a card nobody landed rolled forward on each call type, less the rake
export async function getJackpots(competition: string): Promise<Partial<Record<CallType, number>>> {
  const rows = await must<Array<{ call_type: CallType; amount: number }>>(
    supabase.from("jackpots").select("call_type, amount").eq("competition_code", competition).gt("amount", 0), []);
  return Object.fromEntries(rows.map((r) => [r.call_type, r.amount]));
}
export const myCommittedStake = async () => Number(await must<number | null>(supabase.rpc("my_committed_stake"), 0));

export type LedgerRow = { amount: number; reason: "signup" | "adjustment" | "stake" | "pot" | "jackpot" | "refund" | "ad_reward" | "prize"; created_at: string };
export const myLedger = (limit = 30) => must<LedgerRow[]>(supabase.rpc("my_ledger", { p_limit: limit }), []);

export type LbRow = { user_id: string; display_name: string | null; icon: string; balance: number; points: number; points_prev: number; cards: number; hits: number; calls: number; hit_rate: number; best_call: CallType | null; best_points: number | null };
export const leaderboard = (scope: "overall" | "competition" | "crew" | "week", key?: string) =>
  must<LbRow[]>(supabase.rpc("leaderboard", { p_scope: scope, p_key: key ?? null }), []);

export type Stats = {
  balance: number; points: number; rank: number | null; players: number; cards: number; hit_rate: number; streak: number;
  committed: number; ads_today: number; ads_left: number; ad_reward: number; ads_enabled: boolean;
  ads_gam: boolean; phone_needed: boolean; prize_target: number;
  prize_claim: { id: string; status: "pending" | "approved" | "rejected" | "fulfilled"; created_at: string } | null;
  competitions: Array<{ code: string; name: string; points: number; rank: number }>;
};
export const myStats = () => must<Stats>(supabase.rpc("my_stats"));
export const claimPrize = () => must<string>(supabase.rpc("rpc_claim_prize"));

// §0026 a phone, once, before the first prize claim: the edge function texts a code and checks it
export async function verifyPhone(body: { action: "start"; phone: string } | { action: "check"; phone: string; code: string }) {
  const { data, error } = await supabase.functions.invoke("phone-verify", { body });
  if (error) {
    // the function answers {error} with a 4xx; supabase-js keeps that body inside the response
    const ctx = (error as { context?: Response }).context;
    const msg = await ctx?.json?.().then((b: { error?: string }) => b?.error).catch(() => null);
    throw new Error(msg ?? error.message);
  }
  return data as { sent?: boolean; verified?: boolean };
}

/** §0027 The most one call can take: what is free, and half of what the others have in its pot
 *  plus ten — unless the call already holds more, which is never taken away. Mirrors rpc_save_calls. */
export function stakeLimit(potOnCall: number, storedStake: number, free: number) {
  const cap = Math.max(Math.floor((potOnCall - storedStake) * 0.5) + 10, storedStake);
  return { cap, max: Math.min(Math.max(0, Math.floor(free)), cap) };
}
