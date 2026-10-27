import { createClient } from "npm:@supabase/supabase-js@2";

// Service-role client. send-notifications runs from the sync host; phone-verify checks the
// player's own token first and only then acts for them through this.
export function serviceClient() {
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  return createClient(url, key, { auth: { persistSession: false }, db: { schema: "pool" } });
}

// Only the sync host (with the service key) may call send-notifications.
export function assertServiceCall(req: Request) {
  const auth = req.headers.get("Authorization") ?? "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (auth !== `Bearer ${key}`) {
    return new Response("forbidden", { status: 403 });
  }
  return null;
}

export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
