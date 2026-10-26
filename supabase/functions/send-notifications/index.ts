// Every minute: render and send due rows from `notifications` through Resend (§7).
// §i18n each mail is written in the language on the recipient's profile (0023), falling back
// to English for anyone who has never chosen one.
import { assertServiceCall, json, serviceClient } from "../_shared/db.ts";
import { dayOf, kickoff, langOf, mailIn, num, type Lang, type Mail } from "../_shared/i18n.ts";

const BATCH = 40;
const SITE = () => (Deno.env.get("SITE_URL") ?? "https://thepool.today").replace(/\/$/, "");
const FROM = () => Deno.env.get("MAIL_FROM") ?? "The Pool <hello@thepool.today>";

type Row = { id: number; user_id: string; type: string; payload: Record<string, any>;
  profiles: { email: string; display_name: string | null; language: string | null } };

// ---- brand shell -------------------------------------------------------------------------
function shell(lang: Lang, m: Mail, title: string, body: string, cta?: { label: string; href: string }) {
  return `<!doctype html><html lang="${lang}"><body style="margin:0;background:#111110;color:#f2f1ea;font-family:Archivo,Helvetica,Arial,sans-serif">
  <div style="max-width:560px;margin:0 auto;padding:32px 20px">
    <div style="font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#9b9b92">The Pool</div>
    <h1 style="font-family:Anton,Impact,'Arial Narrow',sans-serif;font-weight:400;text-transform:uppercase;font-size:34px;line-height:1;margin:14px 0 20px;color:#f2f1ea">${title}</h1>
    <div style="font-size:15px;line-height:1.5;color:#c9c8bf">${body}</div>
    ${cta ? `<a href="${cta.href}" style="display:inline-block;margin-top:24px;background:#d7ff3f;color:#111110;text-decoration:none;font-weight:700;text-transform:uppercase;letter-spacing:.05em;font-size:13px;padding:12px 18px;border-radius:9px">${cta.label}</a>` : ""}
    <p style="margin-top:36px;font-size:12px;color:#6f6f68">${m.footerPre}<a href="${SITE()}/settings" style="color:#9b9b92">${m.footerLink}</a>${m.footerPost}</p>
  </div></body></html>`;
}
const lime = (s: string | number) => `<span style="color:#d7ff3f;font-weight:700">${s}</span>`;
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

// ---- data helpers ---------------------------------------------------------------------------
async function matchLine(db: any, matchId: number, lang: Lang) {
  const { data } = await db.from("v_board").select("*").eq("match_id", matchId).single();
  if (!data) return null;
  return { ...data, tie: `${data.home_team} v ${data.away_team}`, when: kickoff(data.utc_date, lang) };
}

async function render(db: any, n: Row): Promise<{ subject: string; html: string } | null> {
  const lang = langOf(n.profiles.language);
  const m = mailIn(lang);
  const name = n.profiles.display_name ?? m.there;
  // a call type in words, in this language
  const callName = (ct: string) => m.markets[ct] ?? ct;

  switch (n.type) {
    case "new_card": {
      const f = await matchLine(db, n.payload.match_id, lang);
      const { data: card } = await db.from("cards").select("mode, crew_id, crews(name), profiles:created_by(display_name)").eq("id", n.payload.card_id).single();
      if (!f || !card) return null;
      const { data: mk } = await db.from("markets").select("call_type, simple").eq("enabled", true).eq("sport", "soccer");
      const calls = (mk ?? []).filter((k: any) => card.mode === "complex" || k.simple).length;
      const where = card.crews?.name ? m.newCard.inCrew(esc(card.crews.name)) : m.newCard.openBoard;
      const kind = lime(card.mode === "complex" ? m.newCard.complex(calls) : m.newCard.simple(calls));
      return {
        subject: m.newCard.subject(f.tie),
        html: shell(lang, m, esc(f.tie),
          `${m.newCard.opened(esc(card.profiles?.display_name ?? m.someone), kind, where)}<br>${m.newCard.when(esc(f.competition_name), esc(f.when), m.tz)}`,
          { label: m.newCard.cta, href: `${SITE()}/match/${f.match_id}` }),
      };
    }
    case "deadline_reminder": {
      const f = await matchLine(db, n.payload.match_id, lang);
      if (!f) return null;
      const { data: entries } = await db.from("entries").select("id, card_id, cards(mode), calls(call_type)").eq("user_id", n.user_id).in("card_id", n.payload.card_ids ?? []);
      const { data: markets } = await db.from("markets").select("call_type, simple").eq("enabled", true);
      const blanks = new Set<string>();
      for (const e of entries ?? []) {
        const have = new Set((e.calls ?? []).map((c: any) => c.call_type));
        for (const k of markets ?? []) if ((e.cards?.mode === "complex" || k.simple) && !have.has(k.call_type)) blanks.add(callName(k.call_type));
      }
      const list = blanks.size ? m.deadline.blanks(lime([...blanks].join(", "))) : m.deadline.notStarted;
      return {
        subject: m.deadline.subject(f.tie),
        html: shell(lang, m, m.deadline.title, `${m.deadline.locks(esc(f.tie), esc(f.when), m.tz)}<br>${list}`,
          { label: m.deadline.cta, href: `${SITE()}/match/${f.match_id}` }),
      };
    }
    case "crew_activity": {
      const { data: crew } = await db.from("crews").select("name").eq("id", n.payload.crew_id).single();
      const { data: posts } = await db.from("crew_posts").select("body, created_at, profiles:user_id(display_name), calls(call_type, points_awarded)")
        .eq("crew_id", n.payload.crew_id).gte("created_at", n.payload.since).neq("user_id", n.user_id).order("created_at").limit(20);
      if (!crew || !posts?.length) return null;
      const items = posts.map((p: any) => {
        const who = esc(p.profiles?.display_name ?? m.someone);
        return p.calls
          ? `<li>${m.crew.receipt(who, esc(callName(p.calls.call_type)), lime("+" + num(p.calls.points_awarded, lang)))}</li>`
          : `<li><b>${who}:</b> ${esc(p.body)}</li>`;
      }).join("");
      return { subject: m.crew.subject(crew.name, posts.length), html: shell(lang, m, esc(crew.name), `<ul style="padding-left:18px">${items}</ul>`, { label: m.crew.cta, href: `${SITE()}/crews` }) };
    }
    case "result":
    case "correction": {
      const f = await matchLine(db, n.payload.match_id, lang);
      if (!f) return null;
      const { data: entry } = await db.from("entries").select("id, points, hits, card_id, cards(mode, crew_id, crews(name)), calls(call_type, result, stake, staked, points_awarded)").eq("user_id", n.user_id).eq("card_id", n.payload.card_id ?? "").maybeSingle();
      const { data: lb } = await db.rpc("leaderboard", { p_scope: "overall" });
      const pos = (lb ?? []).findIndex((r: any) => r.user_id === n.user_id) + 1;
      const hits = (entry?.calls ?? []).filter((c: any) => c.result === "hit")
        .map((c: any) => `${esc(callName(c.call_type))} ${lime("+" + num(c.points_awarded, lang))}`).join(", ") || m.result.nothingLanded;
      // points are a currency now: the card's number is net of the stakes that left the balance
      const staked = (entry?.calls ?? []).filter((c: any) => c.staked).reduce((t: number, c: any) => t + Number(c.stake ?? 0), 0);
      const net = entry ? (entry.points > 0 ? m.result.up(lime("+" + num(entry.points, lang))) : entry.points < 0 ? m.result.down(num(Math.abs(entry.points), lang)) : m.result.level) : "";
      const { data: prof } = await db.from("profiles").select("balance").eq("id", n.user_id).maybeSingle();
      const isFix = n.type === "correction";
      return {
        subject: m.result.subject(f.home_team, f.home_score, f.away_score, f.away_team, isFix),
        html: shell(lang, m, `${esc(f.home_team)} ${f.home_score} – ${f.away_score} ${esc(f.away_team)}`,
          (isFix ? m.result.corrected(num(n.payload.from, lang), lime(num(n.payload.to, lang))) : m.result.fullTime(esc(name))) +
          (entry ? m.result.yourCard(entry.cards?.crews?.name ? m.result.inCrew(esc(entry.cards.crews.name)) : "",
                                     num(staked, lang), entry.hits, entry.calls.length, hits, net) : "") +
          (prof ? m.result.hold(lime(m.result.points(num(prof.balance, lang)))) : "") +
          (pos ? m.result.overall(lime(m.result.ordinal(pos))) : ""),
          { label: m.result.cta, href: `${SITE()}/match/${f.match_id}` }),
      };
    }
    case "weekly_digest": {
      const { data: rows } = await db.from("v_board").select("*").eq("phase", "upcoming").gte("utc_date", new Date().toISOString()).lte("utc_date", new Date(Date.now() + 7 * 86400_000).toISOString()).order("utc_date").limit(15);
      const { data: crews } = await db.from("crew_members").select("crews(id, name, rival_crew_id)").eq("user_id", n.user_id);
      let crewLines = "";
      for (const c of crews ?? []) {
        const cr: any = c.crews;
        const { data: us } = await db.rpc("crew_score", { p_crew: cr.id });
        let line = `<li>${m.digest.crewLine(esc(cr.name), lime(num(us ?? 0, lang)))}`;
        if (cr.rival_crew_id) {
          const { data: them } = await db.rpc("crew_score", { p_crew: cr.rival_crew_id });
          line += m.digest.rival(lime(`${num(us ?? 0, lang)} – ${num(them ?? 0, lang)}`));
        }
        crewLines += line + "</li>";
      }
      const fixtures = (rows ?? []).map((r: any) =>
        `<li>${esc(r.home_team)} v ${esc(r.away_team)} · ${esc(r.competition_name)} · ${esc(dayOf(r.utc_date, lang))}${r.playing ? m.digest.playing(num(r.playing, lang)) : ""}</li>`).join("");
      return {
        subject: m.digest.subject,
        html: shell(lang, m, m.digest.title,
          `<b>${m.digest.fixtures}</b><ul style="padding-left:18px">${fixtures || `<li>${m.digest.quiet}</li>`}</ul>` +
          `<b>${m.digest.yourCrews}</b><ul style="padding-left:18px">${crewLines || `<li>${m.digest.noCrews}</li>`}</ul>`,
          { label: m.digest.cta, href: SITE() }),
      };
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
    .select("id, user_id, type, payload, profiles:user_id(email, display_name, language)")
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
