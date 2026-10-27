// §ads Flags and public config, and the rewarded ad: a nonce minted before the ad is asked for,
// spent when it is granted, never twice (0025); each credit carries a device fingerprint (0026).
import { must, supabase } from "../../lib/supabase";
import { deviceFingerprint } from "./rewarded";

export const getFlag = async (key: string) =>
  !!(await must<{ enabled: boolean } | null>(supabase.from("app_flags").select("enabled").eq("key", key).maybeSingle()))?.enabled;
// the public half of a `config` row — the ad unit has to reach the browser, the rest does not
export const getConfig = async <T,>(key: string) =>
  (await must<{ value: T } | null>(supabase.from("config").select("value").eq("key", key).maybeSingle()))?.value ?? null;

export type AdNonce = { nonce: string; reward: number; watched_today: number; left_today: number };
export const adNonce = () => must<AdNonce>(supabase.rpc("rpc_ad_nonce"));
export type AdCredit = { credited: number; watched_today: number; left_today: number; balance: number };
// the server adds the IP and user-agent from the request itself
export const watchAd = async (nonce?: string | null) =>
  must<AdCredit>(supabase.rpc("rpc_watch_ad", { p_nonce: nonce ?? null, p_fingerprint: await deviceFingerprint() }));
