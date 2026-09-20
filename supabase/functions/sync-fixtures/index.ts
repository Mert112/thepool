// Twice an hour: competitions/seasons, fixtures for the next two weeks (plus the last three days),
// and squads for teams with an upcoming fixture. Budget: ≤ 9 provider calls per run.
import { assertServiceCall, json, serviceClient } from "../_shared/db.ts";
import { COMPETITIONS, fd, FdMatch, matchRow, teamRow, ymd } from "../_shared/fd.ts";

const SQUAD_REFRESH_DAYS = 7;
const SQUADS_PER_RUN = 2; // 3 list calls + 2 squads ≈ 5 provider calls per run, twice an hour

Deno.serve(async (req) => {
  const denied = assertServiceCall(req);
  if (denied) return denied;
  const db = serviceClient();
  const log: Record<string, unknown> = {};

  try {
    // 1. Competitions: one call
    const comps = await fd<{ competitions: Array<{ id: number; code: string; name: string; emblem?: string; currentSeason?: { startDate: string; endDate: string } }> }>(
      "/competitions?plan=TIER_ONE",
    );
    for (const c of comps.competitions) {
      if (!COMPETITIONS.includes(c.code)) continue;
      await db.from("competitions").update({
        fd_id: c.id,
        emblem_url: c.emblem ?? null,
        season: c.currentSeason?.startDate?.slice(0, 4) ?? null,
        season_start: c.currentSeason?.startDate ?? null,
        season_end: c.currentSeason?.endDate ?? null,
      }).eq("code", c.code);
    }
    log.competitions = comps.competitions.length;

    // 2. Fixtures: two 10-day windows (the endpoint caps a window at 10 days)
    const today = new Date();
    const windows = [[-3, 6], [7, 16]];
    let nMatches = 0;
    const teams = new Map<number, ReturnType<typeof teamRow>>();
    for (const [from, to] of windows) {
      const a = new Date(today); a.setUTCDate(a.getUTCDate() + from);
      const b = new Date(today); b.setUTCDate(b.getUTCDate() + to);
      const data = await fd<{ matches: FdMatch[] }>(`/matches?dateFrom=${ymd(a)}&dateTo=${ymd(b)}`);
      const rows = [];
      for (const m of data.matches) {
        if (!COMPETITIONS.includes(m.competition.code)) continue;
        if (!m.homeTeam?.id || !m.awayTeam?.id) continue; // unresolved cup ties
        teams.set(m.homeTeam.id, teamRow(m.homeTeam));
        teams.set(m.awayTeam.id, teamRow(m.awayTeam));
        rows.push(matchRow(m));
      }
      if (teams.size) {
        const { error } = await db.from("teams").upsert([...teams.values()]);
        if (error) throw error;
      }
      if (rows.length) {
        const { error } = await db.from("matches").upsert(rows);
        if (error) throw error;
        nMatches += rows.length;
      }
    }
    log.matches = nMatches;

    // 3. Squads: teams with a fixture in the next 14 days whose squad is stale
    const horizon = new Date(today); horizon.setUTCDate(horizon.getUTCDate() + 14);
    const { data: upcoming } = await db.from("matches")
      .select("home_team_id, away_team_id")
      .gte("utc_date", today.toISOString()).lte("utc_date", horizon.toISOString());
    const candidateIds = [...new Set((upcoming ?? []).flatMap((m: any) => [m.home_team_id, m.away_team_id]).filter(Boolean))] as number[];
    const staleBefore = new Date(today.getTime() - SQUAD_REFRESH_DAYS * 86400_000).toISOString();
    const { data: fresh } = await db.from("players").select("team_id").in("team_id", candidateIds).gt("updated_at", staleBefore);
    const freshIds = new Set((fresh ?? []).map((p: any) => p.team_id));
    const stale = candidateIds.filter((id) => !freshIds.has(id)).slice(0, SQUADS_PER_RUN);

    let nPlayers = 0;
    for (const teamId of stale) {
      const t = await fd<{ id: number; name: string; shortName?: string; tla?: string; crest?: string; squad?: Array<{ id: number; name: string; position?: string; shirtNumber?: number }> }>(`/teams/${teamId}`);
      await db.from("teams").upsert(teamRow(t));
      const players = (t.squad ?? []).map((p) => ({ id: p.id, team_id: t.id, name: p.name, position: p.position ?? null, shirt: p.shirtNumber ?? null, updated_at: new Date().toISOString() }));
      if (players.length) {
        const { error } = await db.from("players").upsert(players);
        if (error) throw error;
        // players who left the club: detach rather than delete (calls may reference them)
        await db.from("players").update({ team_id: null }).eq("team_id", t.id).not("id", "in", `(${players.map((p) => p.id).join(",")})`);
        nPlayers += players.length;
      }
    }
    log.squads = { refreshed: stale.length, players: nPlayers, pending: candidateIds.length - freshIds.size - stale.length };

    // keep card states honest even if the live job is idle
    await db.rpc("sync_card_status");
    return json({ ok: true, ...log });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: String(e), ...log }, 500);
  }
});
