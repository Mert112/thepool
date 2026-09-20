import { createClient } from "@supabase/supabase-js";

// Defaults point at The Pool's project; override with VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY in .env.
// The publishable key is safe to ship in the browser — row-level security does the protecting.
const url = (import.meta.env.VITE_SUPABASE_URL as string) || "https://ephwczmmvbfkbkudehxi.supabase.co";
const key = (import.meta.env.VITE_SUPABASE_ANON_KEY as string) || "sb_publishable_Ya2nKkt5ggmFP3SbcA3BvQ_gdi7H07g";

// The game lives in its own Postgres schema (`pool`), exposed through the API next to `public`.
export const supabase = createClient(url, key, { db: { schema: "pool" } });
