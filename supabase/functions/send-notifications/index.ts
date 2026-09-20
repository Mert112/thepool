// Every minute: render and send due rows from `notifications` through Resend (§7).
import { assertServiceCall, json, serviceClient } from "../_shared/db.ts";

const BATCH = 40;
const SITE = () => (Deno.env.get("SITE_URL") ?? "https://thepool.today").replace(/\/$/, "");
const FROM = () => Deno.env.get("MAIL_FROM") ?? "The Pool <hello@thepool.today>";

type Row = { id: number; user_id: string; type: string; payload: Record<string, any>; profiles: { email: string; display_name: string | null } };

// ---- brand shell -------------------------------------------------------------------------
function shell(title: string, body: string, cta?: { label: string; href: string }) {
  return `<!doctype html><html><body style="margin:0;background:#111110;color:#f2f1ea;font-family:Archivo,Helvetica,Arial,sans-serif">
  <div style="max-width:560px;margin:0 auto;padding:32px 20px">
    <div style="font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#9b9b92">The Pool</div>
    <h1 style="font-family:Anton,Impact,'Arial Narrow',sans-serif;font-weight:400;text-transform:uppercase;font-size:34px;line-height:1;margin:14px 0 20px;color:#f2f1ea">${title}</h1>
    <div style="font-size:15px;line-height:1.5;color:#c9c8bf">${body}</div>
    ${cta ? `<a href="${cta.href}" style="display:inline-block;margin-top:24px;background:#d7ff3f;color:#111110;text-decoration:none;font-weight:700;text-transform:uppercase;letter-spacing:.05em;font-size:13px;padding:12px 18px;border-radius:9px">${cta.label}</a>` : ""}
    <p style="margin-top:36px;font-size:12px;color:#6f6f68">You get this because it is switched on in <a href="${SITE()}/settings" style="color:#9b9b92">settings</a>. Every mail is switchable.</p>
  </div></body></html>`;
}
const lime = (s: string | number) => `<span style="color:#d7ff3f;font-weight:700">${s}</span>`;
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

// ---- data helpers ---------------------------------------------------------------------------
async function matchLine(db: any, matchId: number) {
  const { data } = await db.from("v_board").select("*").eq("match_id", matchId).single();
  if (!data) return null;
  const when = new Date(data.utc_date).toLocaleString("en-GB", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Europe/London" });
  return { ...data, tie: `${data.home_team} v ${data.away_team}`, when };
}

async function render(db: any, n: Row): Promise<{ subject: string; html: string } | null> {
  const name = n.profiles.display_name ?? "there";
  switch (n.type) {
    case "new_card": {
      const m = await matchLine(db, n.payload.match_id);
      const { data: card } = await db.from("cards").select("mode, crew_id, crews(name), profiles:created_by(display_name)").eq("id", n.payload.card_id).single();
      if (!m || !card) return null;
      const where = card.crews?.name ? `in ${esc(card.crews.name)}` : `on the open board`;
      return {
        subject: `Card open: ${m.tie}`,
        html: shell(`${esc(m.tie)}`, `${esc(card.profiles?.display_name ?? "Someone")} opened a ${lime(card.mode === "complex" ? "complex card · 8 calls" : "simple card · 3 calls")} ${where}.<br>${esc(m.competition_name)} · kicks off ${esc(m.when)} UK time. The card locks at kick-off.`,
          { label: "Fill the card", href: `${SITE()}/match/${m.match_id}` }),
      };
    }
    case "deadline_reminder": {
      const m = await matchLine(db, n.payload.match_id);
      if (!m) return null;
      const { data: entries } = await db.from("entries").select("id, card_id, cards(mode), calls(call_type)").eq("user_id", n.user_id).in("card_id", n.payload.card_ids ?? []);
      const { data: markets } = await db.from("markets").select("call_type, title, simple").eq("enabled", true);
      const blanks = new Set<string>();
      for (const e of entries ?? []) {
        const have = new Set((e.calls ?? []).map((c: any) => c.call_type));
        for (const k of markets ?? []) if ((e.cards?.mode === "complex" || k.simple) && !have.has(k.call_type)) blanks.add(k.title);
      }
      const list = blanks.size ? `Still blank: ${lime([...blanks].join(", "))}.` : `You have not started your card yet.`;
      return {
        subject: `One hour: ${m.tie}`,
        html: shell(`One hour to the lock`, `${esc(m.tie)} locks at ${esc(m.when)} UK time.<br>${list}`, { label: "Finish the card", href: `${SITE()}/match/${m.match_id}` }),
      };
    }
    case "crew_activity": {
      const { data: crew } = await db.from("crews").select("name").eq("id", n.payload.crew_id).single();
      const { data: posts } = await db.from("crew_posts").select("body, created_at, profiles:user_id(display_name), calls(call_type, points_awarded)")
        .eq("crew_id", n.payload.crew_id).gte("created_at", n.payload.since).neq("user_id", n.user_id).order("created_at").limit(20);
      if (!crew || !posts?.length) return null;
      const items = posts.map((p: any) => {
        const who = esc(p.profiles?.display_name ?? "Someone");
        return p.calls ? `<li>${who} — receipt: called ${esc(p.calls.call_type)} ${lime("+" + p.calls.points_awarded)}</li>` : `<li><b>${who}:</b> ${esc(p.body)}</li>`;
      }).join("");
      return { subject: `${crew.name}: ${posts.length} new in the crew room`, html: shell(esc(crew.name), `<ul style="padding-left:18px">${items}</ul>`, { label: "Open the crew room", href: `${SITE()}/crews` }) };
    }
    case "result":
    case "correction": {
      const m = await matchLine(db, n.payload.match_id);
      if (!m) return null;
      const { data: entry } = await db.from("entries").select("id, points, hits, card_id, cards(mode, crew_id, crews(name)), calls(call_type, result, points_awarded)").eq("user_id", n.user_id).eq("card_id", n.payload.card_id ?? "").maybeSingle();
      const { data: lb } = await db.rpc("leaderboard", { p_scope: "overall" });
      const pos = (lb ?? []).findIndex((r: any) => r.user_id === n.user_id) + 1;
      const hits = (entry?.calls ?? []).filter((c: any) => c.result === "hit").map((c: any) => `${esc(c.call_type)} ${lime("+" + c.points_awarded)}`).join(", ") || "nothing landed";
      const isFix = n.type === "correction";
      return {
        subject: `${isFix ? "Correction: " : ""}${m.home_team} ${m.home_score} – ${m.away_score} ${m.away_team}`,
        html: shell(`${esc(m.home_team)} ${m.home_score} – ${m.away_score} ${esc(m.away_team)}`,
          (isFix ? `The provider corrected this match after settlement, so it has been re-scored. Your total moved from ${n.payload.from} to ${lime(n.payload.to)}.<br><br>` : `Full time, ${name}. `) +
          (entry ? `Your card${entry.cards?.crews?.name ? ` in ${esc(entry.cards.crews.name)}` : ""}: ${lime(entry.points + " points")} from ${entry.hits} calls (${hits}).` : "") +
          (pos ? `<br>You are ${lime(pos + (pos === 1 ? "st" : pos === 2 ? "nd" : pos === 3 ? "rd" : "th"))} overall.` : ""),
          { label: "See the recap", href: `${SITE()}/match/${m.match_id}` }),
      };
    }
    case "weekly_digest": {
      const { data: rows } = await db.from("v_board").select("*").eq("phase", "upcoming").gte("utc_date", new Date().toISOString()).lte("utc_date", new Date(Date.now() + 7 * 86400_000).toISOString()).order("utc_date").limit(15);
      const { data: crews } = await db.from("crew_members").select("crews(id, name, rival_crew_id)").eq("user_id", n.user_id);
      let crewLines = "";
      for (const c of crews ?? []) {
        const cr: any = c.crews;
        const { data: us } = await db.rpc("crew_score", { p_crew: cr.id });
        let line = `<li><b>${esc(cr.name)}</b> — ${lime(us ?? 0)} pts`;
        if (cr.rival_crew_id) { const { data: them } = await db.rpc("crew_score", { p_crew: cr.rival_crew_id }); line += ` · crew v crew ${lime(`${us ?? 0} – ${them ?? 0}`)}`; }
        crewLines += line + "</li>";
      }
      const fixtures = (rows ?? []).map((r: any) => `<li>${esc(r.home_team)} v ${esc(r.away_team)} · ${esc(r.competition_name)} · ${new Date(r.utc_date).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" })}${r.playing ? ` · ${r.playing} playing` : ""}</li>`).join("");
      return { subject: "Your Friday crew card", html: shell("The week ahead", `<b>Fixtures</b><ul style="padding-left:18px">${fixtures || "<li>Quiet week.</li>"}</ul><b>Your crews</b><ul style="padding-left:18px">${crewLines || "<li>No crews yet — make one and invite the group chat.</li>"}</ul>`, { label: "Open the board", href: SITE() }) };
    }
  }
  return null;
}

async function resend(to: string, subject: string, html: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) throw new Error("RESEND_API_KEY is not set");
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
    body: JSON.stringify({ from: FROM(), to, subject, html }),
  });
  if (!res.ok) throw new Error(`resend ${res.status}: ${await res.text()}`);
}

Deno.serve(async (req) => {
  const denied = assertServiceCall(req);
  if (denied) return denied;
  const db = serviceClient();
  const { data: due, error } = await db.from("notifications")
    .select("id, user_id, type, payload, profiles:user_id(email, display_name)")
    .is("sent_at", null).lte("scheduled_for", new Date().toISOString()).is("error", null)
    .order("scheduled_for").limit(BATCH);
  if (error) return json({ ok: false, error: error.message }, 500);

  let sent = 0, skipped = 0, failed = 0;
  for (const n of (due ?? []) as Row[]) {
    try {
      const mail = await render(db, n);
      if (!mail) { await db.from("notifications").update({ sent_at: new Date().toISOString(), error: "nothing to send" }).eq("id", n.id); skipped++; continue; }
      await resend(n.profiles.email, mail.subject, mail.html);
      await db.from("notifications").update({ sent_at: new Date().toISOString() }).eq("id", n.id);
      sent++;
    } catch (e) {
      failed++;
      await db.from("notifications").update({ error: String(e).slice(0, 500) }).eq("id", n.id);
    }
  }
  return json({ ok: true, sent, skipped, failed });
});
