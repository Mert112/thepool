// §0026 Phone verification before the first prize claim: an SMS code through Twilio Verify.
//
//   POST { action: "start", phone }        → a code is texted to the number
//   POST { action: "check", phone, code }  → { verified: true } once Twilio approves the code
//
// Called from the browser with the player's own JWT. The database decides who may be sent a
// code (one number per account, rationed) and records the result; this function only talks to
// Twilio, whose keys live in the TWILIO_* secrets and never reach the page. Behind the
// `phone_verification` flag.
import { createClient } from "npm:@supabase/supabase-js@2";
import { serviceClient } from "../_shared/db.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const refuse = (error: string, status = 400) => reply({ error }, status);

// "+90 (555) 123-45 67" → "+905551234567"; anything else is left for the database to refuse
const normalise = (p: unknown) => String(p ?? "").replace(/[\s().-]/g, "").replace(/^00/, "+");

async function twilio(path: string, form: Record<string, string>) {
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID")!, token = Deno.env.get("TWILIO_AUTH_TOKEN")!;
  const svc = Deno.env.get("TWILIO_VERIFY_SERVICE_SID")!;
  const res = await fetch(`https://verify.twilio.com/v2/Services/${svc}/${path}`, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(`${sid}:${token}`), "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form),
  });
  return { ok: res.ok, status: res.status, body: await res.json().catch(() => ({})) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return refuse("POST only", 405);

  // who is asking: the player's own token, checked by Supabase Auth
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const auth = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false } });
  const { data: { user } } = await auth.auth.getUser(jwt);
  if (!user) return refuse("not signed in", 401);

  const db = serviceClient();
  const { data: flag } = await db.from("app_flags").select("enabled").eq("key", "phone_verification").maybeSingle();
  if (!flag?.enabled) return refuse("Phone verification is switched off right now.");
  if (!Deno.env.get("TWILIO_ACCOUNT_SID") || !Deno.env.get("TWILIO_AUTH_TOKEN") || !Deno.env.get("TWILIO_VERIFY_SERVICE_SID")) {
    return refuse("Phone verification is not set up yet.", 503);
  }

  const body = await req.json().catch(() => ({}));
  const phone = normalise(body.phone);

  if (body.action === "start") {
    const { data: why, error } = await db.rpc("phone_can_start", { p_user: user.id, p_phone: phone });
    if (error) return refuse(error.message, 500);
    if (why) return refuse(why);
    const r = await twilio("Verifications", { To: phone, Channel: "sms" });
    if (!r.ok) return refuse("We could not text that number. Check it and try again.", 502);
    return reply({ sent: true });
  }

  if (body.action === "check") {
    const code = String(body.code ?? "").replace(/\D/g, "");
    if (code.length < 4 || code.length > 10) return refuse("That code is not right. Check the text and try again.");
    const r = await twilio("VerificationCheck", { To: phone, Code: code });
    if (!r.ok || r.body?.status !== "approved") return refuse("That code is not right. Check the text and try again.");
    const { error } = await db.rpc("phone_mark_verified", { p_user: user.id, p_phone: phone });
    if (error) return refuse(error.message);
    return reply({ verified: true });
  }

  return refuse("unknown action");
});
