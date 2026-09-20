// Every minute. Cheap when nothing is on: it only calls the provider when a match is
// in play, about to kick off, or recently finished and not yet settled.
import { assertServiceCall, json, serviceClient } from "../_shared/db.ts";
import { COMPETITIONS, fd, FdMatch, FINISHED, FIXTURES_MINUTES, IN_PLAY, matchRow, ymd } from "../_shared/fd.ts";

const DETAIL_CAP = 4; // 1 list + 4 detail calls ≈ 30 s per run, well inside the minute
const cardType = (c: string) => c === "RED_CARD" ? "red" : c === "YELLOW_RED_CARD" ? "yellow_red" : "yellow";

Deno.serve(async (req) => {
  const denied = assertServiceCall(req);
  if (denied) return denied;
  const db = serviceClient();
  const now = new Date();

  try {
    // Yield the minutes sync-fixtures uses (shared provider budget)
    if (FIXTURES_MINUTES.includes(now.getUTCMinutes())) {
      await db.rpc("sync_card_status");
      return json({ ok: true, idle: true, reason: "fixtures minute" });
    }
    // Anything worth polling? Kick-off within 10 min, in play, or finished within the last 4 h
    // (settled ones are still watched for provider corrections during that window).
    const { data: active } = await db.from("matches").select("id, status, settled_at, provider_updated, utc_date")
      .gte("utc_date", new Date(now.getTime() - 4 * 3600_000).toISOString())
      .lte("utc_date", new Date(now.getTime() + 10 * 60_000).toISOString())
      .not("status", "in", "(POSTPONED,CANCELLED,SUSPENDED)");
    const live: any[] = active ?? [];
    if (!live.length) {
      await db.rpc("sync_card_status");
      return json({ ok: true, idle: true });
    }

    // 1. One list call covering today (UTC ±1 day for late kick-offs)
    const a = new Date(now); a.setUTCDate(a.getUTCDate() - 1);
    const b = new Date(now); b.setUTCDate(b.getUTCDate() + 1);
    const list = await fd<{ matches: FdMatch[] }>(`/matches?dateFrom=${ymd(a)}&dateTo=${ymd(b)}`);
    const known = new Map<number, any>(live.map((m) => [m.id, m]));
    const summaryRows = [];
    const needDetail: FdMatch[] = [];
    for (const m of list.matches) {
      if (!COMPETITIONS.includes(m.competition.code) || !m.homeTeam?.id || !m.awayTeam?.id) continue;
      summaryRows.push(matchRow(m));
      const ours = known.get(m.id);
      if (!ours) continue;
      const inPlay = IN_PLAY.includes(m.status);
      const finishedUnsettled = FINISHED.includes(m.status) && !ours.settled_at;
      const corrected = FINISHED.includes(m.status) && !!ours.settled_at && !!m.lastUpdated
        && (!ours.provider_updated || Date.parse(m.lastUpdated) > Date.parse(ours.provider_updated));
      if (inPlay || finishedUnsettled || corrected) needDetail.push(m);
    }
    if (summaryRows.length) {
      const { error } = await db.from("matches").upsert(summaryRows);
      if (error) throw error;
    }

    // 2. Detail (goals, bookings) for the matches that can move calls
    const detailed: number[] = [];
    for (const m of needDetail.slice(0, DETAIL_CAP)) {
      const d = await fd<FdMatch>(`/matches/${m.id}`);
      const goals = d.goals ?? [];
      const bookings = d.bookings ?? [];

      // players referenced by events must exist (FK); squads normally cover them
      const people = new Map<number, { id: number; name: string; team_id: number }>();
      for (const g of goals) {
        if (g.scorer) people.set(g.scorer.id, { id: g.scorer.id, name: g.scorer.name, team_id: g.team.id });
        if (g.assist) people.set(g.assist.id, { id: g.assist.id, name: g.assist.name, team_id: g.team.id });
      }
      for (const k of bookings) people.set(k.player.id, { id: k.player.id, name: k.player.name, team_id: k.team.id });
      if (people.size) {
        const { data: existing } = await db.from("players").select("id").in("id", [...people.keys()]);
        const have = new Set((existing ?? []).map((p: any) => p.id));
        const missing = [...people.values()].filter((p) => !have.has(p.id));
        if (missing.length) await db.from("players").upsert(missing.map((p) => ({ ...p, updated_at: new Date().toISOString() })));
      }

      const events = [
        ...goals.filter((g) => g.scorer).map((g) => ({
          match_id: d.id, type: "goal", minute: g.minute, injury_time: g.injuryTime ?? null,
          team_id: g.team.id, player_id: g.scorer!.id, player_name: g.scorer!.name,
          assist_player_id: g.assist?.id ?? null, assist_name: g.assist?.name ?? null,
          own_goal: g.type === "OWN",
          provider_key: `goal:${g.scorer!.id}:${g.minute}:${g.injuryTime ?? 0}`,
        })),
        ...bookings.map((k) => ({
          match_id: d.id, type: cardType(k.card), minute: k.minute, injury_time: k.injuryTime ?? null,
          team_id: k.team.id, player_id: k.player.id, player_name: k.player.name,
          assist_player_id: null, assist_name: null, own_goal: false,
          provider_key: `${cardType(k.card)}:${k.player.id}:${k.minute}:${k.injuryTime ?? 0}`,
        })),
      ];
      if (events.length) {
        const { error } = await db.from("match_events").upsert(events, { onConflict: "match_id,provider_key" });
        if (error) throw error;
      }
      // events the provider withdrew (VAR) disappear here too
      const keys = events.map((e) => e.provider_key);
      let del = db.from("match_events").delete().eq("match_id", d.id);
      if (keys.length) del = del.not("provider_key", "in", `(${keys.map((k) => `"${k}"`).join(",")})`);
      await del;

      const { error } = await db.from("matches").upsert(matchRow(d));
      if (error) throw error;
      detailed.push(d.id);
    }

    // 3. Lock / live / settle / re-settle
    const { error } = await db.rpc("process_match_updates");
    if (error) throw error;
    return json({ ok: true, listed: summaryRows.length, detailed, queued: Math.max(0, needDetail.length - DETAIL_CAP) });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: String(e) }, 500);
  }
});
