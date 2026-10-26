#!/usr/bin/env node
// The Pool — ESPN sync, football only (0017). systemd runs it every minute (deploy/thepool-sync.timer):
//   · every 30 minutes: fixtures for yesterday → a week out, every competition
//   · every minute: scoreboards for competitions with a match in play or about to start
//   · matches someone is playing: goals and cards, written before the match goes final
//   · squads for the fixtures on the board
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

const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chunks = (xs, n) => Array.from({ length: Math.ceil(xs.length / n) }, (_, i) => xs.slice(i * n, i * n + n));
const hash = (x) => createHash("sha1").update(JSON.stringify(x)).digest("hex");
const num = (x) => (x === undefined || x === null || x === "" || Number.isNaN(Number(x)) ? null : Number(x));
const must = ({ data, error }, what) => { if (error) throw new Error(`${what}: ${error.message}`); return data; };
// one row per key: a batch that names the same row twice is refused by ON CONFLICT (ESPN rosters can repeat a player)
const uniq = (rows, key = (r) => r.id) => [...new Map(rows.map((r) => [key(r), r])).values()];
const problems = [];
// a failure in one game's box score or one team's squad is logged and skipped; the pass (and settlement) carries on
async function isolate(what, fn) { try { return await fn(); } catch (e) { problems.push(`${what}: ${e.message}`); } }

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
function statusOf(st) {
  const t = st?.type ?? {}, name = t.name ?? "";
  if (/CANCEL/.test(name)) return "CANCELLED";
  if (/POSTPONED/.test(name)) return "POSTPONED";
  if (t.state === "pre") return "TIMED";
  if (t.state === "in") {
    if (/HALFTIME/.test(name)) return "PAUSED";
    if ((st.period ?? 0) >= 5) return "PENALTY_SHOOTOUT";
    if ((st.period ?? 0) >= 3) return "EXTRA_TIME";
    return /DELAY|SUSPEND/.test(name) ? "SUSPENDED" : "IN_PLAY";
  }
  if (t.completed || /FINAL|RETIRED|WALKOVER/.test(name)) return "FINISHED";
  return /SUSPEND|DELAY/.test(name) ? "SUSPENDED" : "POSTPONED";
}

// American odds → decimal price ("+255" → 3.55, "-185" → 1.54)
const dec = (a) => { const n = num(String(a ?? "").replace("+", "")); return !n ? null : Math.round((n > 0 ? 1 + n / 100 : 1 - 100 / n) * 100) / 100; };

// the board's prices (DraftKings via ESPN), stored as decimals; a missing side falls back to the standard -110
function oddsOf(c) {
  const o = c.odds?.[0]; if (!o) return {};
  const ml = o.moneyline ?? {}, ps = o.pointSpread ?? {}, tt = o.total ?? {};
  const out = {};
  const home = dec(ml.home?.close?.odds), away = dec(ml.away?.close?.odds), draw = dec(ml.draw?.close?.odds ?? o.drawOdds?.moneyLine);
  if (home) out.home = home; if (away) out.away = away; if (draw) out.draw = draw;
  const hl = num(String(ps.home?.close?.line ?? "").replace("+", ""));
  if (hl !== null) out.spread = { home_line: hl, home: dec(ps.home.close.odds) ?? 1.91, away: dec(ps.away?.close?.odds) ?? 1.91 };
  const tl = num(String(tt.over?.close?.line ?? "").replace(/^[ou]/, "")) ?? num(o.overUnder);
  if (tl !== null) out.total = { line: tl, over: dec(tt.over?.close?.odds) ?? 1.91, under: dec(tt.under?.close?.odds) ?? 1.91 };
  if (Object.keys(out).length) out.provider = o.provider?.name ?? null;
  return out;
}

// "45'+1'" → { minute: 45, injury: 1 }
function minuteOf(display) {
  const m = /^(\d+)'?(?:\s*\+\s*(\d+))?/.exec(String(display ?? "").trim());
  return m ? { minute: Number(m[1]), injury: m[2] ? Number(m[2]) : null } : null;
}

// ---------------------------------------------------------------------------
// Scoreboard → { teams, match } per fixture
// ---------------------------------------------------------------------------
function teamRow(ns, t) {
  return { espn_key: `${ns}:${t.id}`, name: t.displayName ?? t.name, short_name: t.shortDisplayName ?? t.shortName ?? null, tla: t.abbreviation ?? null, crest_url: t.logo ?? t.flag?.href ?? null, sport: "soccer" };
}

function base(comp, c, ev, st) {
  return {
    espn_key: `${comp.espn_path}:${c.id}`, competition_code: comp.code, sport: "soccer",
    season: String(ev.season?.year ?? new Date(c.date ?? ev.date).getUTCFullYear()),
    utc_date: new Date(c.date ?? c.startDate ?? ev.date).toISOString(),
    status: statusOf(st), minute: null, clock: null,
    home_score: null, away_score: null, ft_home: null, ft_away: null, duration: null,
    line: null, event_name: null, result_detail: {}, prices: {},
  };
}

function parseMatch(comp, ev, c) {
  const st = c.status ?? ev.status;
  const cs = c.competitors ?? [];
  const h = cs.find((x) => x.homeAway === "home") ?? cs[0], a = cs.find((x) => x.homeAway === "away") ?? cs[1];
  if (!h?.team?.id || !a?.team?.id) return null;
  const m = base(comp, c, ev, st);
  const started = st?.type?.state !== "pre";
  m.line = num(c.odds?.[0]?.overUnder);
  m.prices = oddsOf(c);
  m.event_name = c.notes?.[0]?.headline ?? null;
  if (started) { m.home_score = num(h.score); m.away_score = num(a.score); }

  const period = st?.period ?? 0;
  if (st?.type?.state === "in") { m.minute = minuteOf(st.displayClock)?.minute ?? null; m.clock = /HALFTIME/.test(st.type.name) ? "HT" : st.displayClock ?? st.type.shortDetail ?? null; }
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
  return { teams: [teamRow(comp.team_ns, h.team), teamRow(comp.team_ns, a.team)], home: `${comp.team_ns}:${h.team.id}`, away: `${comp.team_ns}:${a.team.id}`, espnTeam: { [h.team.id]: `${comp.team_ns}:${h.team.id}`, [a.team.id]: `${comp.team_ns}:${a.team.id}` }, match: m };
}

function parseScoreboard(comp, sb) {
  const out = [];
  for (const ev of sb?.events ?? []) {
    for (const c of ev.competitions ?? []) { const r = parseMatch(comp, ev, c); if (r) out.push(r); }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Summary → goals and cards, and who took part
// ---------------------------------------------------------------------------
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
  // took part: started, or came off the bench
  const stats = [];
  for (const r of s?.rosters ?? []) {
    const tk = teamKey(r.team?.id);
    for (const p of r.roster ?? []) {
      if (!(p.starter || p.subbedIn === true || p.subbedIn?.didSub)) continue;
      const id = person(p, tk); if (id) stats.push({ player_id: id, stat: "app", value: 1 });
    }
  }
  return { players: [...players.values()], events, stats };
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
  const comps = DRY && process.env.DRY_COMPS ? JSON.parse(readFileSync(process.env.DRY_COMPS, "utf8")) : must(await db.from("competitions").select("code, espn_path, espn_params, team_ns").eq("active", true).not("espn_path", "is", null), "competitions");
  const byCode = Object.fromEntries(comps.map((c) => [c.code, c]));

  // 1. which scoreboards to read
  const jobs = [];
  if (full) {
    for (const c of comps) for (let d = -1; d <= 7; d++) jobs.push({ comp: c, q: `dates=${etDate(addDays(now, d))}` });
  } else {
    const hot = must(await db.from("matches").select("competition_code, utc_date").not("espn_key", "is", null)
      .gte("utc_date", addDays(now, -0.5).toISOString()).lte("utc_date", new Date(now.getTime() + 20 * 60e3).toISOString())
      .in("status", ["SCHEDULED", "TIMED", "IN_PLAY", "PAUSED", "EXTRA_TIME", "PENALTY_SHOOTOUT", "SUSPENDED"]), "hot matches");
    const want = new Map();
    for (const m of hot) { if (!byCode[m.competition_code]) continue; if (!want.has(m.competition_code)) want.set(m.competition_code, new Set()); want.get(m.competition_code).add(etDate(new Date(m.utc_date))); }
    for (const [code, days] of want) for (const d of days) jobs.push({ comp: byCode[code], q: `dates=${d}` });
  }

  const boards = await mapLimit(jobs, 6, async (j) => ({ comp: j.comp, sb: await espn(`${j.comp.espn_path}/scoreboard`, [j.q, j.comp.espn_params, "limit=500"].filter(Boolean).join("&")) }));
  const games = new Map();
  // a feed can carry several days; older results are not board material
  const oldest = addDays(now, -3).toISOString();
  for (const { comp, sb } of boards) for (const g of parseScoreboard(comp, sb)) if (g.match.utc_date >= oldest) games.set(g.match.espn_key, { ...g, comp });
  const list = [...games.values()];

  if (DRY) {
    const bySport = {};
    for (const g of list) { const k = g.comp.code; bySport[k] ??= {}; bySport[k][g.match.status] = (bySport[k][g.match.status] ?? 0) + 1; }
    console.log(full ? "FULL pass" : "LIVE pass", `${jobs.length} scoreboards, ${list.length} games`); console.table(bySport);
    for (const code of Object.keys(bySport)) {
      const g = list.find((x) => x.comp.code === code && x.match.status === "FINISHED") ?? list.find((x) => x.comp.code === code);
      const m = g.match; console.log(code.padEnd(6), m.utc_date.slice(0, 16), `${g.teams[0].name} v ${g.teams[1].name}`, m.status, m.home_score ?? "-", m.away_score ?? "-", m.clock ?? "", m.line != null ? `line ${m.line}` : "", m.event_name ?? "");
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
    for (const r of must(await db.from("matches").select("id, espn_key, provider_hash, provider_updated, total_line, odds").in("espn_key", part), "existing")) existing.set(r.espn_key, r);
  }
  const tracked = new Map(must(await db.rpc("sync_tracked_matches"), "tracked").map((r) => [r.espn_key, r]));

  // 4. goals, cards and line-ups for played matches in play or finishing, before their final status lands
  let summaries = 0;
  await mapLimit(list.filter((g) => tracked.has(g.match.espn_key) && (LIVE.has(g.match.status) || g.match.status === "FINISHED")), 4, (g) => isolate(`summary ${g.match.espn_key}`, async () => {
    g.hold = true;   // until this match's events are safely written, it cannot go final
    const id = tracked.get(g.match.espn_key).id, espnId = g.match.espn_key.split(":").pop();
    const s = await espn(`${g.comp.espn_path}/summary`, `event=${espnId}`);
    const teamKey = (eid) => g.espnTeam[eid] ?? null;
    if (!s) return;
    const parsed = parseSoccerEvents(s, teamKey);
    const prow = (p) => ({ id: p.id, name: p.name, position: p.position, team_id: teamId.get(p.team_key) ?? null, sport: "soccer", updated_at: now.toISOString() });
    if (parsed.players.length) must(await db.from("players").upsert(uniq(parsed.players).map(prow), { onConflict: "id", ignoreDuplicates: true }), "players");
    if (parsed.stats.length) must(await db.from("player_stats").upsert(uniq(parsed.stats.map((x) => ({ match_id: id, ...x })), (x) => `${x.player_id}:${x.stat}`), { onConflict: "match_id,player_id,stat" }), "player_stats");
    g.digest = parsed.stats.map((x) => `${x.player_id}:${x.stat}:${x.value}`).sort();
    const rows = parsed.events.map(({ team_key, ...e }) => ({ match_id: id, ...e, team_id: teamId.get(team_key) ?? null }));
    if (rows.length) must(await db.from("match_events").upsert(uniq(rows, (r) => r.provider_key), { onConflict: "match_id,provider_key" }), "match_events");
    // a goal the provider withdrew (VAR) disappears from the feed: drop it here too
    const keep = rows.map((r) => r.provider_key);
    let del = db.from("match_events").delete().eq("match_id", id);
    if (keep.length) del = del.not("provider_key", "in", `(${keep.map((k) => `"${k}"`).join(",")})`);
    must(await del, "match_events cleanup");
    g.digest.push(...rows.map((r) => `${r.provider_key}:${r.type}:${r.minute}:${r.player_id}:${r.assist_player_id}`).sort());
    g.hold = false;
    summaries++;
  }));

  // 5. matches
  const rows = [];
  for (const g of list) {
    const m = { ...g.match }, old = existing.get(m.espn_key);
    if (!teamId.get(g.home) || !teamId.get(g.away)) continue;
    if (g.hold && m.status === "FINISHED") { m.status = "IN_PLAY"; m.clock = "Final · confirming"; }  // settle once the stats are in
    const pre = m.status === "TIMED" || m.status === "SCHEDULED" || m.status === "POSTPONED";
    const total_line = pre ? m.line ?? old?.total_line ?? null : old?.total_line ?? null;  // the line freezes at the start
    const odds = pre && Object.keys(m.prices).length ? m.prices : old?.odds ?? {};          // and so do the prices
    delete m.line; delete m.prices;
    const fingerprint = hash([m.status, m.home_score, m.away_score, m.result_detail, g.digest ?? null]);
    rows.push({ ...m, total_line, odds, home_team_id: teamId.get(g.home), away_team_id: teamId.get(g.away), provider_hash: fingerprint,
      provider_updated: old && old.provider_hash === fingerprint ? old.provider_updated : now.toISOString() });
  }
  for (const part of chunks(rows, 200)) must(await db.from("matches").upsert(part, { onConflict: "espn_key" }), "matches");

  // 6. squads for the fixtures on the board
  let squads = 0;
  const needs = must(await db.rpc("sync_roster_needs", { p_limit: full ? 40 : 12 }), "roster needs");
  await mapLimit(needs, 4, (n) => isolate(`squad ${n.espn_key}`, async () => {
    const r = await espn(`${n.espn_path}/teams/${n.espn_key.split(":").pop()}/roster`);
    const flat = Array.isArray(r?.athletes?.[0]?.items) ? r.athletes.flatMap((g) => g.items ?? []) : r?.athletes ?? [];
    const players = flat.filter((a) => num(a.id)).map((a) => ({ id: num(a.id), team_id: n.team_id, name: a.displayName ?? a.fullName, position: a.position?.abbreviation ?? null,
      shirt: num(a.jersey), sport: "soccer", updated_at: now.toISOString() }));
    for (const part of chunks(uniq(players), 300)) must(await db.from("players").upsert(part, { onConflict: "id" }), "roster");
    must(await db.from("teams").update({ roster_checked_at: now.toISOString() }).eq("id", n.team_id), "roster checked");
    squads += players.length ? 1 : 0;
  }));

  // 7. lock, go live, settle
  must(await db.rpc("process_match_updates"), "settlement");

  if (full) state.lastFull = now.toISOString();
  state.lastRun = now.toISOString();
  saveState(state);
  for (const p of problems) log("skipped", p);
  log(`${full ? "full" : "live"} · ${jobs.length} scoreboards · ${rows.length} matches · ${list.filter((g) => LIVE.has(g.match.status)).length} live · ${summaries} summaries · ${squads} squads · ${Date.now() - t0}ms`);
}

export { parseSoccerEvents, parseScoreboard, oddsOf };
// importing for a parser check (THEPOOL_NO_MAIN=1) must not run a sync
if (!process.env.THEPOOL_NO_MAIN) main().catch((e) => { log("sync failed:", e.message); process.exit(1); });
