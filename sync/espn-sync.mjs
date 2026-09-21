#!/usr/bin/env node
// The Pool — ESPN sync. systemd runs it every minute (deploy/thepool-sync.timer):
//   · every 30 minutes: fixtures for yesterday → a week out, every competition
//   · every minute: scoreboards for competitions with a game in play or about to start
//   · games someone is playing: box scores / goals and cards, written before the game goes final
//   · squads for the next 36 hours of team-sport fixtures
//   · then settlement (pool.process_match_updates)
// `node espn-sync.mjs --dry` fetches and parses without writing anything.
import { PostgrestClient } from "@supabase/postgrest-js";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const DRY = process.argv.includes("--dry");
const FULL = process.argv.includes("--full");
const HERE = dirname(new URL(import.meta.url).pathname);
const env = Object.fromEntries(
  readFileSync(`${HERE}/.env`, "utf8").split("\n").filter((l) => /^\w+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
// the database API only: no auth session or realtime needed for a server job
const db = new PostgrestClient(`${env.SUPABASE_URL}/rest/v1`, {
  schema: "pool", headers: { apikey: env.SUPABASE_SERVICE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}` },
});
const STATE_FILE = env.STATE_FILE || "/var/lib/thepool-sync/state.json";
const ESPN = "https://site.api.espn.com/apis/site/v2/sports";
const FULL_EVERY_MS = 30 * 60e3;
const LIVE = new Set(["IN_PLAY", "PAUSED", "EXTRA_TIME", "PENALTY_SHOOTOUT"]);
const TEAM_SPORTS = new Set(["soccer", "basketball", "american_football", "baseball", "hockey"]);

const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chunks = (xs, n) => Array.from({ length: Math.ceil(xs.length / n) }, (_, i) => xs.slice(i * n, i * n + n));
const hash = (x) => createHash("sha1").update(JSON.stringify(x)).digest("hex");
const num = (x) => (x === undefined || x === null || x === "" || Number.isNaN(Number(x)) ? null : Number(x));
const must = ({ data, error }, what) => { if (error) throw new Error(`${what}: ${error.message}`); return data; };

// ESPN groups a day's games by US Eastern date
const etDate = (d) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).format(d).replaceAll("-", "");
const addDays = (d, n) => new Date(d.getTime() + n * 86400e3);

async function espn(path, params = "") {
  const url = `${ESPN}/${path}${params ? `?${params}` : ""}`;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(15000) });
      if (r.status === 400 || r.status === 404) return null;
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return await r.json();
    } catch (e) {
      if (attempt === 1) { log("espn failed", url, e.message); return null; }
      await sleep(1500);
    }
  }
}

async function mapLimit(items, n, fn) {
  const out = []; let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => { while (i < items.length) { const k = i++; out[k] = await fn(items[k]); } }));
  return out;
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------
function statusOf(st, sport) {
  const t = st?.type ?? {}, name = t.name ?? "";
  if (/CANCEL/.test(name)) return "CANCELLED";
  if (/POSTPONED/.test(name)) return "POSTPONED";
  if (t.state === "pre") return "TIMED";
  if (t.state === "in") {
    if (/HALFTIME/.test(name)) return "PAUSED";
    if (sport === "soccer" && (st.period ?? 0) >= 5) return "PENALTY_SHOOTOUT";
    if (sport === "soccer" && (st.period ?? 0) >= 3) return "EXTRA_TIME";
    return /DELAY|SUSPEND/.test(name) ? "SUSPENDED" : "IN_PLAY";
  }
  if (t.completed || /FINAL|RETIRED|WALKOVER/.test(name)) return "FINISHED";
  return /SUSPEND|DELAY/.test(name) ? "SUSPENDED" : "POSTPONED";
}

// "45'+1'" → { minute: 45, injury: 1 }
function minuteOf(display) {
  const m = /^(\d+)'?(?:\s*\+\s*(\d+))?/.exec(String(display ?? "").trim());
  return m ? { minute: Number(m[1]), injury: m[2] ? Number(m[2]) : null } : null;
}

// ---------------------------------------------------------------------------
// Scoreboard → { teams, match } per game, tennis match or fight
// ---------------------------------------------------------------------------
function teamRow(ns, sport, t) {
  return { espn_key: `${ns}:${t.id}`, name: t.displayName ?? t.name, short_name: t.shortDisplayName ?? t.shortName ?? null, tla: t.abbreviation ?? null, crest_url: t.logo ?? t.flag?.href ?? null, sport };
}

function base(comp, c, ev, st) {
  return {
    espn_key: `${comp.espn_path}:${c.id}`, competition_code: comp.code, sport: comp.sport,
    season: String(ev.season?.year ?? new Date(c.date ?? ev.date).getUTCFullYear()),
    utc_date: new Date(c.date ?? c.startDate ?? ev.date).toISOString(),
    status: statusOf(st, comp.sport), minute: null, clock: null,
    home_score: null, away_score: null, ft_home: null, ft_away: null, duration: null,
    home_periods: null, away_periods: null, line: null, best_of: null, event_name: null, result_detail: {},
  };
}

function parseTeamGame(comp, ev, c) {
  const st = c.status ?? ev.status;
  const cs = c.competitors ?? [];
  const h = cs.find((x) => x.homeAway === "home") ?? cs[0], a = cs.find((x) => x.homeAway === "away") ?? cs[1];
  if (!h?.team?.id || !a?.team?.id) return null;
  const m = base(comp, c, ev, st);
  const started = st?.type?.state !== "pre";
  const periods = (x) => (x.linescores?.length ? x.linescores.map((l) => num(l.value) ?? 0) : null);
  m.home_periods = periods(h); m.away_periods = periods(a);
  m.line = num(c.odds?.[0]?.overUnder);
  m.event_name = c.notes?.[0]?.headline ?? null;
  if (started) { m.home_score = num(h.score); m.away_score = num(a.score); }
  if (st?.type?.state === "in") m.clock = st.type.shortDetail ?? st.displayClock ?? null;

  if (comp.sport === "soccer") {
    const period = st?.period ?? 0;
    if (st?.type?.state === "in") { m.minute = minuteOf(st.displayClock)?.minute ?? null; m.clock = /HALFTIME/.test(st.type.name) ? "HT" : st.displayClock ?? m.clock; }
    // §2.1 football settles on the 90-minute state: after extra time, count only goals up to 90+stoppage
    if (started) {
      m.ft_home = m.home_score; m.ft_away = m.away_score;
      m.duration = period >= 5 || /PEN/.test(st.type.name) ? "PENALTY_SHOOTOUT" : period >= 3 || /AET/.test(st.type.name) ? "EXTRA_TIME" : "REGULAR";
      if (m.duration !== "REGULAR") {
        const goals = (c.details ?? []).filter((d) => d.scoringPlay && !/shootout/i.test(d.type?.text ?? "") && (minuteOf(d.clock?.displayValue)?.minute ?? 999) <= 90);
        m.home_score = goals.filter((g) => String(g.team?.id) === String(h.team.id)).length;
        m.away_score = goals.filter((g) => String(g.team?.id) === String(a.team.id)).length;
      }
    }
  }
  return { teams: [teamRow(comp.team_ns, comp.sport, h.team), teamRow(comp.team_ns, comp.sport, a.team)], home: `${comp.team_ns}:${h.team.id}`, away: `${comp.team_ns}:${a.team.id}`, espnTeam: { [h.team.id]: `${comp.team_ns}:${h.team.id}`, [a.team.id]: `${comp.team_ns}:${a.team.id}` }, match: m };
}

// tennis players and fighters are one-person sides; ESPN's athlete id is the identity
function personSides(c) {
  const cs = [...(c.competitors ?? [])].sort((x, y) => (x.homeAway === "home" ? 0 : x.homeAway === "away" ? 1 : 2) - (y.homeAway === "home" ? 0 : y.homeAway === "away" ? 1 : 2) || (x.order ?? 0) - (y.order ?? 0));
  if (cs.length !== 2) return null;
  const side = (x) => { const p = x.athlete ?? {}; const id = p.id ?? x.id; const name = p.displayName ?? p.fullName; return id && name && !/^TBD$/i.test(name) ? { id, displayName: name, shortName: p.shortName, flag: p.flag } : null; };
  const h = side(cs[0]), a = side(cs[1]);
  return h && a ? { h, a, hc: cs[0], ac: cs[1] } : null;
}

function parseTennis(comp, ev, c, grouping) {
  const s = personSides(c); if (!s) return null;
  const st = c.status, m = base(comp, c, ev, st), name = st?.type?.name ?? "";
  // ESPN's format field says 5 for every ATP event; only men's Grand Slam main draws are best of five
  const slam = /australian open|roland garros|french open|wimbledon|us open/i.test(ev.name ?? "");
  m.best_of = comp.code === "ATP" && slam && !/qualif/i.test(c.round?.displayName ?? "") ? 5 : 3;
  m.event_name = [ev.name, c.round?.displayName].filter(Boolean).join(" · ");
  const games = (x) => (x.linescores ?? []).map((l) => num(l.value) ?? 0);
  m.home_periods = games(s.hc); m.away_periods = games(s.ac);
  const finished = m.status === "FINISHED";
  // sets won: every set once it is over; during play the last set is still going
  const n = Math.max(m.home_periods.length, m.away_periods.length) - (finished ? 0 : 1);
  let hs = 0, as = 0;
  for (let i = 0; i < n; i++) { const x = m.home_periods[i] ?? 0, y = m.away_periods[i] ?? 0; if (x > y) hs++; else if (y > x) as++; }
  if (st?.type?.state !== "pre") { m.home_score = hs; m.away_score = as; }
  if (st?.type?.state === "in") m.clock = `Set ${Math.max(m.home_periods.length, m.away_periods.length, 1)}`;   // ESPN says just "2nd"
  if (finished) {
    const winner = s.hc.winner ? "home" : s.ac.winner ? "away" : "none";
    const retired = /RETIRED|WALKOVER|ABANDON|DEFAULT/.test(name) || /\bret\.|retired|walkover|w\/o/i.test(c.notes?.map((x) => x.text).join(" ") ?? "");
    m.result_detail = { winner, ...(retired ? { retired: true } : {}) };
  }
  return { teams: [personRow(comp, s.h), personRow(comp, s.a)], home: `${comp.team_ns}:${s.h.id}`, away: `${comp.team_ns}:${s.a.id}`, espnTeam: {}, match: m };
}

function parseFight(comp, ev, c) {
  const s = personSides(c); if (!s) return null;
  const st = c.status, m = base(comp, c, ev, st);
  m.best_of = num(c.format?.regulation?.periods) ?? 3;
  m.event_name = [ev.name, c.type?.abbreviation].filter(Boolean).join(" · ");
  if (st?.type?.state === "in") m.clock = `R${st.period ?? 1} ${st.displayClock ?? ""}`.trim();
  if (m.status === "FINISHED") {
    const winner = s.hc.winner ? "home" : s.ac.winner ? "away" : "none";
    const how = (c.details ?? []).map((d) => d.type?.text ?? "").find((t) => /winner/i.test(t)) ?? "";
    const method = winner === "none" ? null : /decision/i.test(how) ? "Decision" : /sub/i.test(how) ? "Submission" : /ko|knock/i.test(how) ? "KO/TKO" : null;
    m.result_detail = { winner, ...(method ? { method, round: String(st.period ?? "") } : {}) };
    m.home_score = winner === "home" ? 1 : 0; m.away_score = winner === "away" ? 1 : 0;
  }
  return { teams: [personRow(comp, s.h), personRow(comp, s.a)], home: `${comp.team_ns}:${s.h.id}`, away: `${comp.team_ns}:${s.a.id}`, espnTeam: {}, match: m };
}

function personRow(comp, p) {
  return { espn_key: `${comp.team_ns}:${p.id}`, name: p.displayName, short_name: p.shortName ?? null, tla: null, crest_url: p.flag?.href ?? null, sport: comp.sport };
}

function parseScoreboard(comp, sb) {
  const out = [];
  for (const ev of sb?.events ?? []) {
    if (comp.sport === "tennis") {
      for (const g of ev.groupings ?? []) {
        if (!/singles/i.test(`${g.grouping?.slug ?? ""} ${g.grouping?.displayName ?? ""}`)) continue;
        for (const c of g.competitions ?? []) { const r = parseTennis(comp, ev, c, g); if (r) out.push(r); }
      }
    } else if (comp.sport === "mma") {
      for (const c of ev.competitions ?? []) { const r = parseFight(comp, ev, c); if (r) out.push(r); }
    } else {
      for (const c of ev.competitions ?? []) { const r = parseTeamGame(comp, ev, c); if (r) out.push(r); }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Summary → player stats (US sports) or goals/cards (football)
// ---------------------------------------------------------------------------
const STAT = { basketball: ["pts", ["PTS"], null], american_football: ["td", ["TD"], /^(rushing|receiving)$/], baseball: ["hr", ["HR"], /^batting$/], hockey: ["g", ["G"], null] };

function parseBox(sport, s, teamKey) {
  const [stat, labels, groups] = STAT[sport];
  const players = new Map(), values = new Map();
  for (const side of s?.boxscore?.players ?? []) {
    const tk = teamKey(side.team?.id);
    for (const g of side.statistics ?? []) {
      if (groups && !groups.test(g.name ?? "")) continue;
      const idx = (g.labels ?? g.names ?? []).findIndex((l) => labels.includes(l));
      if (idx < 0) continue;
      for (const a of g.athletes ?? []) {
        const id = num(a.athlete?.id); if (!id || !a.stats?.length) continue;
        players.set(id, { id, name: a.athlete.displayName, position: a.athlete.position?.abbreviation ?? null, team_key: tk });
        values.set(id, (values.get(id) ?? 0) + (num(a.stats[idx]) ?? 0));
      }
    }
  }
  return { players: [...players.values()], stats: [...values].map(([player_id, value]) => ({ player_id, stat, value })) };
}

function parseSoccerEvents(s, teamKey) {
  const players = new Map(), events = [];
  const person = (p, tk) => { const id = num(p?.athlete?.id); if (id && !players.has(id)) players.set(id, { id, name: p.athlete.displayName, position: null, team_key: tk }); return id; };
  for (const k of s?.keyEvents ?? []) {
    const text = k.type?.text ?? "", tk = teamKey(k.team?.id);
    const type = k.scoringPlay ? "goal" : /yellow/i.test(text) ? "yellow" : /red/i.test(text) ? "red" : null;
    if (!type || /shootout/i.test(text)) continue;
    const t = minuteOf(k.clock?.displayValue); if (!t) continue;
    const own = /own goal/i.test(text);
    const [p0, p1] = k.participants ?? [];
    const scorer = person(p0, own ? null : tk);
    const assist = type === "goal" && !own ? person(p1, tk) : null;
    events.push({ provider_key: String(k.id), type, minute: t.minute, injury_time: t.injury, team_key: tk, player_id: scorer, player_name: p0?.athlete?.displayName ?? null,
      assist_player_id: assist, assist_name: assist ? p1.athlete.displayName : null, own_goal: own });
  }
  return { players: [...players.values()], events };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function loadState() { try { return JSON.parse(readFileSync(STATE_FILE, "utf8")); } catch { return {}; } }
function saveState(s) { mkdirSync(dirname(STATE_FILE), { recursive: true }); writeFileSync(STATE_FILE, JSON.stringify(s)); }

async function main() {
  const t0 = Date.now(), now = new Date(), state = loadState();
  const full = FULL || !state.lastFull || now - new Date(state.lastFull) > FULL_EVERY_MS;
  // --dry can read the competition list from a file (DRY_COMPS) before the migration is live
  const comps = DRY && process.env.DRY_COMPS ? JSON.parse(readFileSync(process.env.DRY_COMPS, "utf8")) : must(await db.from("competitions").select("code, sport, espn_path, espn_params, team_ns").eq("active", true).not("espn_path", "is", null), "competitions");
  const byCode = Object.fromEntries(comps.map((c) => [c.code, c]));

  // 1. which scoreboards to read
  const jobs = [];
  const range = (a, b) => `dates=${etDate(addDays(now, a))}-${etDate(addDays(now, b))}`;
  if (full) {
    for (const c of comps) {
      if (c.sport === "tennis" || c.sport === "mma") jobs.push({ comp: c, q: range(-1, 14) });
      else for (let d = -1; d <= 7; d++) jobs.push({ comp: c, q: `dates=${etDate(addDays(now, d))}` });
    }
  } else {
    const hot = must(await db.from("matches").select("competition_code, utc_date").not("espn_key", "is", null)
      .gte("utc_date", addDays(now, -0.5).toISOString()).lte("utc_date", new Date(now.getTime() + 20 * 60e3).toISOString())
      .in("status", ["SCHEDULED", "TIMED", "IN_PLAY", "PAUSED", "EXTRA_TIME", "PENALTY_SHOOTOUT", "SUSPENDED"]), "hot matches");
    const want = new Map();
    for (const m of hot) { if (!byCode[m.competition_code]) continue; if (!want.has(m.competition_code)) want.set(m.competition_code, new Set()); want.get(m.competition_code).add(etDate(new Date(m.utc_date))); }
    for (const [code, days] of want) {
      const c = byCode[code];
      if (c.sport === "tennis" || c.sport === "mma") jobs.push({ comp: c, q: range(-1, 1) });
      else for (const d of days) jobs.push({ comp: c, q: `dates=${d}` });
    }
  }

  const boards = await mapLimit(jobs, 6, async (j) => ({ comp: j.comp, sb: await espn(`${j.comp.espn_path}/scoreboard`, [j.q, j.comp.espn_params, "limit=500"].filter(Boolean).join("&")) }));
  const games = new Map();
  // tournament feeds (tennis, fight nights) carry the whole week; older results are not board material
  const oldest = addDays(now, -3).toISOString();
  for (const { comp, sb } of boards) for (const g of parseScoreboard(comp, sb)) if (g.match.utc_date >= oldest) games.set(g.match.espn_key, { ...g, comp });
  const list = [...games.values()];

  if (DRY) {
    const bySport = {};
    for (const g of list) { const k = g.comp.code; bySport[k] ??= {}; bySport[k][g.match.status] = (bySport[k][g.match.status] ?? 0) + 1; }
    console.log(full ? "FULL pass" : "LIVE pass", `${jobs.length} scoreboards, ${list.length} games`); console.table(bySport);
    for (const code of Object.keys(bySport)) {
      const g = list.find((x) => x.comp.code === code && x.match.status === "FINISHED") ?? list.find((x) => x.comp.code === code);
      const m = g.match; console.log(code.padEnd(6), m.utc_date.slice(0, 16), `${g.teams[0].name} v ${g.teams[1].name}`, m.status, m.home_score ?? "-", m.away_score ?? "-", m.clock ?? "", m.line != null ? `line ${m.line}` : "", m.best_of ? `bo${m.best_of}` : "", JSON.stringify(m.result_detail), m.event_name ?? "");
    }
    return;
  }

  // 2. teams
  const teamRows = [...new Map(list.flatMap((g) => g.teams).map((t) => [t.espn_key, t])).values()];
  const teamId = new Map();
  for (const part of chunks(teamRows, 300)) {
    for (const t of must(await db.from("teams").upsert(part.map((t) => ({ ...t, updated_at: now.toISOString() })), { onConflict: "espn_key" }).select("id, espn_key"), "teams")) teamId.set(t.espn_key, t.id);
  }

  // 3. what we already hold, and who is being played
  const existing = new Map();
  for (const part of chunks(list.map((g) => g.match.espn_key), 150)) {
    for (const r of must(await db.from("matches").select("id, espn_key, provider_hash, provider_updated, total_line").in("espn_key", part), "existing")) existing.set(r.espn_key, r);
  }
  const tracked = new Map(must(await db.rpc("sync_tracked_matches"), "tracked").map((r) => [r.espn_key, r]));

  // 4. box scores / events for played games in play or finishing, before their final status lands
  let summaries = 0;
  await mapLimit(list.filter((g) => tracked.has(g.match.espn_key) && TEAM_SPORTS.has(g.comp.sport) && (LIVE.has(g.match.status) || g.match.status === "FINISHED")), 4, async (g) => {
    const id = tracked.get(g.match.espn_key).id, espnId = g.match.espn_key.split(":").pop();
    const s = await espn(`${g.comp.espn_path}/summary`, `event=${espnId}`);
    const teamKey = (eid) => g.espnTeam[eid] ?? null;
    if (!s) { g.hold = true; return; }
    const parsed = g.comp.sport === "soccer" ? parseSoccerEvents(s, teamKey) : parseBox(g.comp.sport, s, teamKey);
    if (g.match.status === "FINISHED" && g.comp.sport !== "soccer" && parsed.stats.length === 0) { g.hold = true; return; }  // box score not up yet
    const prow = (p) => ({ id: p.id, name: p.name, position: p.position, team_id: teamId.get(p.team_key) ?? null, sport: g.comp.sport, updated_at: now.toISOString() });
    if (parsed.players.length) must(await db.from("players").upsert(parsed.players.map(prow), { onConflict: "id", ignoreDuplicates: g.comp.sport === "soccer" }), "players");
    if (parsed.stats) {
      if (parsed.stats.length) must(await db.from("player_stats").upsert(parsed.stats.map((x) => ({ match_id: id, ...x })), { onConflict: "match_id,player_id,stat" }), "player_stats");
      g.digest = parsed.stats.map((x) => `${x.player_id}:${x.value}`).sort();
    } else {
      const rows = parsed.events.map(({ team_key, ...e }) => ({ match_id: id, ...e, team_id: teamId.get(team_key) ?? null }));
      if (rows.length) must(await db.from("match_events").upsert(rows, { onConflict: "match_id,provider_key" }), "match_events");
      // a goal the provider withdrew (VAR) disappears from the feed: drop it here too
      const keep = rows.map((r) => r.provider_key);
      let del = db.from("match_events").delete().eq("match_id", id);
      if (keep.length) del = del.not("provider_key", "in", `(${keep.map((k) => `"${k}"`).join(",")})`);
      must(await del, "match_events cleanup");
      g.digest = rows.map((r) => `${r.provider_key}:${r.type}:${r.minute}:${r.player_id}:${r.assist_player_id}`).sort();
    }
    summaries++;
  });

  // 5. matches
  const rows = [];
  for (const g of list) {
    const m = { ...g.match }, old = existing.get(m.espn_key);
    if (!teamId.get(g.home) || !teamId.get(g.away)) continue;
    if (g.hold && m.status === "FINISHED") { m.status = "IN_PLAY"; m.clock = "Final · confirming"; }  // settle once the stats are in
    const pre = m.status === "TIMED" || m.status === "SCHEDULED" || m.status === "POSTPONED";
    const total_line = pre ? m.line ?? old?.total_line ?? null : old?.total_line ?? null;  // the line freezes at the start
    delete m.line;
    const fingerprint = hash([m.status, m.home_score, m.away_score, m.result_detail, g.digest ?? null]);
    rows.push({ ...m, total_line, home_team_id: teamId.get(g.home), away_team_id: teamId.get(g.away), provider_hash: fingerprint,
      provider_updated: old && old.provider_hash === fingerprint ? old.provider_updated : now.toISOString() });
  }
  for (const part of chunks(rows, 200)) must(await db.from("matches").upsert(part, { onConflict: "espn_key" }), "matches");

  // 6. squads for upcoming team-sport fixtures
  let squads = 0;
  const needs = must(await db.rpc("sync_roster_needs", { p_limit: full ? 40 : 12 }), "roster needs");
  await mapLimit(needs, 4, async (n) => {
    const r = await espn(`${n.espn_path}/teams/${n.espn_key.split(":").pop()}/roster`);
    const flat = Array.isArray(r?.athletes?.[0]?.items) ? r.athletes.flatMap((g) => g.items ?? []) : r?.athletes ?? [];
    const players = flat.filter((a) => num(a.id)).map((a) => ({ id: num(a.id), team_id: n.team_id, name: a.displayName ?? a.fullName, position: a.position?.abbreviation ?? null,
      shirt: num(a.jersey), sport: byCode[Object.keys(byCode).find((k) => byCode[k].espn_path === n.espn_path)]?.sport ?? null, updated_at: now.toISOString() }));
    for (const part of chunks(players, 300)) must(await db.from("players").upsert(part, { onConflict: "id" }), "roster");
    must(await db.from("teams").update({ roster_checked_at: now.toISOString() }).eq("id", n.team_id), "roster checked");
    squads += players.length ? 1 : 0;
  });

  // 7. lock, go live, settle
  must(await db.rpc("process_match_updates"), "settlement");

  if (full) state.lastFull = now.toISOString();
  state.lastRun = now.toISOString();
  saveState(state);
  log(`${full ? "full" : "live"} · ${jobs.length} scoreboards · ${rows.length} games · ${list.filter((g) => LIVE.has(g.match.status)).length} live · ${summaries} box scores · ${squads} squads · ${Date.now() - t0}ms`);
}

main().catch((e) => { log("sync failed:", e.message); process.exit(1); });
