#!/usr/bin/env node
// The Pool — API-Football sync (api-sports.io v3). systemd runs it every minute.
//
//   · once a week   the league catalogue, so "More leagues" knows what exists
//   · once a day    fixtures for every followed competition, and squads for the teams playing
//                   (a league followed since then: on the next pass)
//   · every minute  the fixtures that are in play *and* have a card on them, in batches of
//                   twenty, with their events and line-ups — then settlement
//   · after the whistle  one results check for everything else that kicked off
//
// Every request is reserved from the database first (pool.api_take). The budget is a row in
// `config`, the counter is a row per UTC day in `api_usage`, and a pass that cannot afford a
// call does not make it. That is deliberate: a counter inside this script would reset every
// time systemd restarted it, and the provider's own limit is a hard stop at 7,500.
//
//   node api-football.mjs --dry         fetch and parse, write nothing
//   node api-football.mjs --catalogue   force the league catalogue pass
//   node api-football.mjs --fixtures    force the daily fixtures pass
//   node api-football.mjs --squads      force the daily squads pass
import { PostgrestClient } from "@supabase/postgrest-js";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const argv = new Set(process.argv.slice(2));
const DRY = argv.has("--dry");
const HERE = dirname(new URL(import.meta.url).pathname);
// THEPOOL_NO_MAIN is the tests importing the parsers: no .env, no key, no sync (a fresh clone has neither)
const TESTING = !!process.env.THEPOOL_NO_MAIN;
const readEnv = () => { try { return readFileSync(`${HERE}/.env`, "utf8"); } catch (e) { if (TESTING) return ""; throw e; } };
const env = Object.fromEntries(
  readEnv().split("\n").filter((l) => /^\w+=/.test(l))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
const db = new PostgrestClient(`${env.SUPABASE_URL}/rest/v1`, {
  schema: "pool", headers: { apikey: env.SUPABASE_SERVICE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}` },
});
const KEY = env.FOOTBALL_API_KEY;
if (!KEY && !TESTING) { console.error("FOOTBALL_API_KEY is not set in sync/.env"); process.exit(1); }
const STATE_FILE = env.STATE_FILE || "/var/lib/thepool-sync/state.json";

const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chunks = (xs, n) => Array.from({ length: Math.ceil(xs.length / n) }, (_, i) => xs.slice(i * n, i * n + n));
const num = (x) => (x === undefined || x === null || x === "" || Number.isNaN(Number(x)) ? null : Number(x));
const must = ({ data, error }, what) => { if (error) throw new Error(`${what}: ${error.message}`); return data; };
const uniq = (rows, key = (r) => r.id) => [...new Map(rows.map((r) => [key(r), r])).values()];
const problems = [];
async function isolate(what, fn) { try { return await fn(); } catch (e) { problems.push(`${what}: ${e.message}`); } }
const day = (d) => d.toISOString().slice(0, 10);
const addDays = (d, n) => new Date(d.getTime() + n * 86400e3);

// Team and player names are the provider's, but matching one provider's spelling to another's
// needs a looser key: case, accents, punctuation and the club-type noise all go.
const normal = (s) => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "")
  .toLowerCase().replace(/\b(fc|cf|sc|ac|afc|cd|ud|ss|as|if|sk|fk|bk|club|futbol|football)\b/g, "")
  .replace(/[^a-z0-9]+/g, " ").trim();

// ---------------------------------------------------------------------------
// The provider, on a budget
// ---------------------------------------------------------------------------
let spent = 0, refused = 0;

async function afford(n, kind) {
  if (DRY) return true;
  const ok = must(await db.rpc("api_take", { p_n: n, p_kind: kind }), "api_take");
  if (!ok) { refused += n; return false; }
  return true;
}

async function get(base, path, params = {}) {
  const url = new URL(`${base}/${path}`);
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch(url, { headers: { "x-apisports-key": KEY }, signal: AbortSignal.timeout(20000) });
      if (r.status === 429) { await sleep(2000 * (attempt + 1)); continue; }
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const j = await r.json();
      spent++;
      // the provider answers 200 with an `errors` object for a bad request or a spent quota
      const errs = j.errors;
      if (errs && (Array.isArray(errs) ? errs.length : Object.keys(errs).length)) {
        throw new Error(JSON.stringify(errs).slice(0, 200));
      }
      return j.response ?? [];
    } catch (e) {
      if (attempt === 2) { problems.push(`${path} ${JSON.stringify(params)}: ${e.message}`); return null; }
      await sleep(1200 * (attempt + 1));
    }
  }
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------
// API-Football's two dozen status codes, in the eleven the game knows about.
const STATUS = {
  TBD: "SCHEDULED", NS: "TIMED",
  "1H": "IN_PLAY", "2H": "IN_PLAY", LIVE: "IN_PLAY", HT: "PAUSED",
  ET: "EXTRA_TIME", BT: "EXTRA_TIME", P: "PENALTY_SHOOTOUT",
  FT: "FINISHED", AET: "FINISHED", PEN: "FINISHED",
  SUSP: "SUSPENDED", INT: "SUSPENDED",
  PST: "POSTPONED", CANC: "CANCELLED", ABD: "CANCELLED",
  AWD: "AWARDED", WO: "AWARDED",
};
const LIVE_SHORT = new Set(["1H", "2H", "HT", "ET", "BT", "P", "LIVE", "INT"]);
const FINAL_SHORT = new Set(["FT", "AET", "PEN", "AWD", "WO"]);

function teamRow(t, national) {
  return { af_id: t.id, name: t.name, crest_url: t.logo ?? null, sport: "soccer",
    national: !!national, updated_at: new Date().toISOString() };
}

// §2.1 The 90-minute rule. The provider separates the score at 90 (`score.fulltime`) from the
// score including extra time (`goals`), which is exactly the distinction the game settles on.
function matchRow(f, code) {
  const short = f.fixture.status.short;
  const status = STATUS[short] ?? "TIMED";
  const live = LIVE_SHORT.has(short), final = FINAL_SHORT.has(short);
  const goalsH = num(f.goals?.home), goalsA = num(f.goals?.away);
  const ftH = num(f.score?.fulltime?.home), ftA = num(f.score?.fulltime?.away);
  const et = f.score?.extratime?.home != null || short === "AET" || short === "PEN";
  const m = {
    af_fixture_id: f.fixture.id,
    competition_code: code,
    season: String(f.league?.season ?? new Date(f.fixture.date).getUTCFullYear()),
    utc_date: new Date(f.fixture.date).toISOString(),
    status, sport: "soccer",
    minute: live ? num(f.fixture.status.elapsed) : null,
    clock: short === "HT" ? "HT" : live ? `${f.fixture.status.elapsed ?? ""}'` : null,
    home_score: null, away_score: null, ft_home: null, ft_away: null, duration: null,
    event_name: f.league?.round ?? null,
    result_detail: {},
  };
  if (live) { m.home_score = goalsH; m.away_score = goalsA; }
  if (final) {
    // the 90-minute score settles everything; the running total is display only
    m.home_score = ftH ?? goalsH; m.away_score = ftA ?? goalsA;
    m.ft_home = goalsH; m.ft_away = goalsA;
    m.duration = short === "PEN" ? "PENALTY_SHOOTOUT" : et ? "EXTRA_TIME" : "REGULAR";
  }
  return m;
}

// One fixture's events, as the game stores them. The provider gives no event id, so the key is
// what the event *is*: re-reading a fixture produces the same keys, and an event VAR took away
// stops appearing and is deleted.
function parseEvents(f) {
  const out = [];
  for (const e of f.events ?? []) {
    const d = String(e.detail ?? ""), t = String(e.type ?? "");
    let type = null;
    if (t === "Goal") type = "goal";
    else if (t === "Card" && /yellow/i.test(d)) type = "yellow";
    else if (t === "Card" && /red/i.test(d)) type = "red";
    if (!type) continue;
    if (/missed penalty/i.test(d)) continue;                       // not a goal
    const own = /own goal/i.test(d);
    // a card shown before kick-off comes through as a negative minute
    const minute = Math.max(0, num(e.time?.elapsed) ?? 0);
    const injury = num(e.time?.extra);
    out.push({
      provider_key: [minute, injury ?? 0, type, own ? "og" : "", e.player?.id ?? "", e.team?.id ?? ""].join(":"),
      type, minute, injury_time: injury, af_team_id: e.team?.id ?? null,
      af_player_id: own ? null : num(e.player?.id), player_name: e.player?.name ?? null,
      af_assist_id: type === "goal" && !own ? num(e.assist?.id) : null,
      assist_name: type === "goal" && !own ? e.assist?.name ?? null : null,
      own_goal: own,
    });
  }
  return out;
}

// Who took part: the starting eleven plus anyone who came off the bench. This is also the
// witness that the provider answered at all — `matches.detail_at` is stamped by the write.
function parseLineups(f) {
  const subbedOn = new Set((f.events ?? []).filter((e) => e.type === "subst").map((e) => e.assist?.id).filter(Boolean));
  const out = [];
  for (const l of f.lineups ?? []) {
    for (const p of l.startXI ?? []) if (p.player?.id) out.push({ af_player_id: p.player.id, af_team_id: l.team?.id, name: p.player.name, position: p.player.pos ?? null, shirt: num(p.player.number) });
    for (const p of l.substitutes ?? []) if (p.player?.id && subbedOn.has(p.player.id)) out.push({ af_player_id: p.player.id, af_team_id: l.team?.id, name: p.player.name, position: p.player.pos ?? null, shirt: num(p.player.number) });
  }
  // some leagues have no line-ups but do report who played, in `players`
  if (!out.length) {
    for (const t of f.players ?? []) {
      for (const p of t.players ?? []) {
        const mins = num(p.statistics?.[0]?.games?.minutes);
        if (p.player?.id && mins) out.push({ af_player_id: p.player.id, af_team_id: t.team?.id, name: p.player.name, position: p.statistics?.[0]?.games?.position ?? null, shirt: num(p.statistics?.[0]?.games?.number) });
      }
    }
  }
  return uniq(out, (p) => p.af_player_id);
}

// The board's two priced markets: the goals line and the handicap, plus the three-way price.
// A quarter line (-1.25) splits a stake in real betting and has no meaning in a pot, so only
// whole and half lines are taken.
function parseOdds(entry) {
  const want = (name) => {
    for (const b of entry?.bookmakers ?? []) {
      const bet = (b.bets ?? []).find((x) => x.name === name);
      if (bet?.values?.length) return { book: b.name, values: bet.values };
    }
    return null;
  };
  const out = {};
  const mw = want("Match Winner");
  if (mw) {
    for (const v of mw.values) {
      const o = num(v.odd);
      if (!o) continue;
      if (/^home$/i.test(v.value)) out.home = o;
      else if (/^away$/i.test(v.value)) out.away = o;
      else if (/^draw$/i.test(v.value)) out.draw = o;
    }
    out.provider = mw.book;
  }
  const ou = want("Goals Over/Under");
  if (ou) {
    const lines = new Map();
    for (const v of ou.values) {
      const m = /^(Over|Under)\s+([\d.]+)$/i.exec(v.value); const o = num(v.odd);
      if (!m || !o) continue;
      const line = Number(m[2]);
      if (line * 2 % 1 !== 0) continue;                       // whole and half lines only
      const e = lines.get(line) ?? {}; e[m[1].toLowerCase()] = o; lines.set(line, e);
    }
    // the main line is the one the two sides price closest to each other
    const best = [...lines.entries()].filter(([, v]) => v.over && v.under)
      .sort((a, b) => Math.abs(a[1].over - a[1].under) - Math.abs(b[1].over - b[1].under))[0];
    if (best) out.total = { line: best[0], over: best[1].over, under: best[1].under };
  }
  const ah = want("Asian Handicap");
  if (ah) {
    const lines = new Map();
    for (const v of ah.values) {
      const m = /^(Home|Away)\s+([-+]?[\d.]+)$/i.exec(v.value); const o = num(v.odd);
      if (!m || !o) continue;
      const raw = Number(m[2]);
      if (raw * 2 % 1 !== 0) continue;
      const homeLine = /home/i.test(m[1]) ? raw : -raw;
      const e = lines.get(homeLine) ?? {}; e[m[1].toLowerCase()] = o; lines.set(homeLine, e);
    }
    const best = [...lines.entries()].filter(([, v]) => v.home && v.away)
      .sort((a, b) => Math.abs(a[1].home - a[1].away) - Math.abs(b[1].home - b[1].away))[0];
    if (best) out.spread = { home_line: best[0], home: best[1].home, away: best[1].away };
  }
  return out;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------
const now = () => new Date().toISOString();

// Teams come in by provider id. One that is already here under ESPN's key is recognised by its
// name within the competition and keeps its row — and therefore its settled matches.
async function upsertTeams(rows) {
  if (!rows.length) return new Map();
  const byAf = new Map();
  const have = must(await db.from("teams").select("id, af_id, name").in("af_id", rows.map((r) => r.af_id)), "teams by af_id");
  for (const t of have) byAf.set(t.af_id, t.id);
  const missing = rows.filter((r) => !byAf.has(r.af_id));
  if (missing.length) {
    // claim an existing row by name before making a new one
    const candidates = must(await db.from("teams").select("id, name, af_id").is("af_id", null), "unmapped teams");
    const byName = new Map();
    for (const t of candidates) { const k = normal(t.name); if (!byName.has(k)) byName.set(k, t.id); }
    const claims = [], fresh = [];
    for (const r of missing) {
      const id = byName.get(normal(r.name));
      if (id) { claims.push({ id, ...r }); byName.delete(normal(r.name)); } else fresh.push(r);
    }
    for (const part of chunks(claims, 200)) {
      for (const t of must(await db.from("teams").upsert(part, { onConflict: "id" }).select("id, af_id"), "team claims")) byAf.set(t.af_id, t.id);
    }
    for (const part of chunks(fresh, 200)) {
      for (const t of must(await db.from("teams").upsert(part, { onConflict: "af_id" }).select("id, af_id"), "new teams")) byAf.set(t.af_id, t.id);
    }
  }
  return byAf;
}

// Same idea for a fixture: one already here under ESPN's key is recognised by its competition,
// its two sides and its kick-off, and keeps its id — so every settled call still points at it.
async function upsertMatches(rows) {
  if (!rows.length) return new Map();
  const byFx = new Map();
  const have = must(await db.from("matches").select("id, af_fixture_id").in("af_fixture_id", rows.map((r) => r.af_fixture_id)), "matches by fixture");
  for (const m of have) byFx.set(m.af_fixture_id, m.id);
  const missing = rows.filter((r) => !byFx.has(r.af_fixture_id));
  if (missing.length) {
    const codes = [...new Set(missing.map((r) => r.competition_code))];
    const lo = missing.reduce((a, r) => (r.utc_date < a ? r.utc_date : a), missing[0].utc_date);
    const hi = missing.reduce((a, r) => (r.utc_date > a ? r.utc_date : a), missing[0].utc_date);
    const near = must(await db.from("matches").select("id, competition_code, utc_date, home_team_id, away_team_id")
      .is("af_fixture_id", null).in("competition_code", codes)
      .gte("utc_date", addDays(new Date(lo), -2).toISOString())
      .lte("utc_date", addDays(new Date(hi), 2).toISOString()), "unmapped matches");
    const claims = [], fresh = [];
    for (const r of missing) {
      const t = new Date(r.utc_date).getTime();
      const hit = near.find((o) => o.competition_code === r.competition_code
        && o.home_team_id === r.home_team_id && o.away_team_id === r.away_team_id
        && Math.abs(new Date(o.utc_date).getTime() - t) < 36 * 3600e3);
      if (hit) { claims.push({ id: hit.id, ...r }); near.splice(near.indexOf(hit), 1); } else fresh.push(r);
    }
    for (const part of chunks(claims, 150)) {
      for (const m of must(await db.from("matches").upsert(part, { onConflict: "id" }).select("id, af_fixture_id"), "match claims")) byFx.set(m.af_fixture_id, m.id);
    }
    for (const part of chunks(fresh, 150)) {
      for (const m of must(await db.from("matches").upsert(part, { onConflict: "af_fixture_id" }).select("id, af_fixture_id"), "new matches")) byFx.set(m.af_fixture_id, m.id);
    }
  }
  const updates = rows.filter((r) => byFx.has(r.af_fixture_id)).map((r) => ({ id: byFx.get(r.af_fixture_id), ...r }));
  for (const part of chunks(updates, 150)) must(await db.from("matches").upsert(part, { onConflict: "id" }), "matches");
  return byFx;
}

// Players likewise: an existing row with the same name in the same squad takes the provider id.
async function upsertPlayers(rows) {
  if (!rows.length) return new Map();
  const byAf = new Map();
  const have = must(await db.from("players").select("id, af_id").in("af_id", rows.map((r) => r.af_id)), "players by af_id");
  for (const p of have) byAf.set(p.af_id, p.id);
  const missing = rows.filter((r) => !byAf.has(r.af_id));
  if (!missing.length) return byAf;
  const teamIds = [...new Set(missing.map((r) => r.team_id).filter(Boolean))];
  const candidates = teamIds.length
    ? must(await db.from("players").select("id, name, team_id").is("af_id", null).in("team_id", teamIds), "unmapped players") : [];
  const byName = new Map();
  for (const p of candidates) { const k = `${p.team_id}:${normal(p.name)}`; if (!byName.has(k)) byName.set(k, p.id); }
  const claims = [], fresh = [];
  for (const r of missing) {
    const id = byName.get(`${r.team_id}:${normal(r.name)}`);
    if (id) { claims.push({ id, ...r }); byName.delete(`${r.team_id}:${normal(r.name)}`); } else fresh.push(r);
  }
  for (const part of chunks(uniq(claims), 300)) {
    for (const p of must(await db.from("players").upsert(part, { onConflict: "id" }).select("id, af_id"), "player claims")) byAf.set(p.af_id, p.id);
  }
  for (const part of chunks(uniq(fresh, (r) => r.af_id), 300)) {
    for (const p of must(await db.from("players").upsert(part, { onConflict: "af_id" }).select("id, af_id"), "new players")) byAf.set(p.af_id, p.id);
  }
  return byAf;
}

// ---------------------------------------------------------------------------
// The passes
// ---------------------------------------------------------------------------
function loadState() { try { return JSON.parse(readFileSync(STATE_FILE, "utf8")); } catch { return {}; } }
function saveState(s) { if (DRY) return; mkdirSync(dirname(STATE_FILE), { recursive: true }); writeFileSync(STATE_FILE, JSON.stringify(s)); }
const due = (iso, days) => !iso || Date.now() - new Date(iso).getTime() > days * 86400e3;

async function catalogue(base) {
  if (!(await afford(1, "leagues"))) return 0;
  const rows = await get(base, "leagues");
  if (!rows) return 0;
  if (DRY) { log(`catalogue: ${rows.length} leagues`); return rows.length; }
  let n = 0;
  for (const r of rows) {
    const season = (r.seasons ?? []).find((s) => s.current) ?? (r.seasons ?? []).at(-1);
    await isolate(`league ${r.league.id}`, async () => {
      must(await db.rpc("upsert_league", {
        p_id: r.league.id, p_name: r.league.name, p_type: r.league.type, p_logo: r.league.logo ?? null,
        p_country: r.country?.name ?? null, p_code: r.country?.code ?? null, p_flag: r.country?.flag ?? null,
        p_season: season?.year ?? null,
        p_events: season?.coverage?.fixtures?.events ?? null,
        p_odds: season?.coverage?.odds ?? null,
      }), "upsert_league");
      n++;
    });
  }
  return n;
}

// `only`: a set of league codes to fetch instead of all of them (a league just followed)
async function fixtures(base, cfg, only = null) {
  const leagues = must(await db.rpc("sync_leagues"), "sync_leagues").filter((l) => !only || only.has(l.code));
  const from = day(addDays(new Date(), -(cfg.window_days_back ?? 2)));
  const to = day(addDays(new Date(), cfg.window_days_forward ?? 8));
  let got = 0, written = 0;
  for (const l of leagues) {
    if (!(await afford(1, "fixtures"))) break;
    const rows = await get(base, "fixtures", { league: l.league_id, season: l.season, from, to });
    if (!rows?.length) continue;
    const keep = l.team_filter?.length
      ? rows.filter((f) => l.team_filter.includes(f.teams.home.id) || l.team_filter.includes(f.teams.away.id))
      : rows;
    got += keep.length;
    if (DRY || !keep.length) continue;
    const national = /world/i.test(l.code) || !!l.team_filter?.length;
    const teamIds = await upsertTeams(uniq(keep.flatMap((f) => [teamRow(f.teams.home, national), teamRow(f.teams.away, national)]), (t) => t.af_id));
    const ms = keep.map((f) => ({ ...matchRow(f, l.code), home_team_id: teamIds.get(f.teams.home.id), away_team_id: teamIds.get(f.teams.away.id) }))
      .filter((m) => m.home_team_id && m.away_team_id);
    await upsertMatches(ms);
    written += ms.length;
  }
  return { leagues: leagues.length, got, written, codes: leagues.map((l) => l.code) };
}

// One fixture detail carries the score, the events and the line-ups, and twenty of them fit in
// one request. This is the pass that makes a minute-by-minute live sync affordable.
async function details(base, cfg, list, kind) {
  if (!list.length) return 0;
  const size = cfg.fixture_batch ?? 20;
  let seen = 0;
  for (const part of chunks(list, size)) {
    if (!(await afford(1, kind))) break;
    const rows = await get(base, "fixtures", { ids: part.map((x) => x.fixture_id).join("-") });
    if (!rows?.length) continue;
    seen += rows.length;
    if (DRY) continue;
    const byFixture = new Map(part.map((x) => [x.fixture_id, x.match_id]));
    for (const f of rows) {
      await isolate(`detail ${f.fixture.id}`, async () => {
        const matchId = byFixture.get(f.fixture.id);
        if (!matchId) return;
        const code = must(await db.from("matches").select("competition_code").eq("id", matchId).single(), "match code").competition_code;
        const teamIds = await upsertTeams([teamRow(f.teams.home), teamRow(f.teams.away)]);

        // line-ups first: they are what makes a player call judgeable, and writing them stamps
        // matches.detail_at. A fixture whose detail never arrives leaves it null, and at full
        // time the player calls on it are voided rather than scored as misses.
        const lineup = parseLineups(f);
        let playerIds = new Map();
        if (lineup.length) {
          playerIds = await upsertPlayers(lineup.map((p) => ({
            af_id: p.af_player_id, name: p.name, position: p.position, shirt: p.shirt,
            team_id: teamIds.get(p.af_team_id) ?? null, sport: "soccer", updated_at: now(),
          })));
          const stats = lineup.map((p) => ({ match_id: matchId, player_id: playerIds.get(p.af_player_id), stat: "app", value: 1 }))
            .filter((s) => s.player_id);
          if (stats.length) must(await db.from("player_stats").upsert(uniq(stats, (s) => s.player_id), { onConflict: "match_id,player_id,stat" }), "player_stats");
        }

        const evs = parseEvents(f);
        // an event's player may not be in the line-up we hold (a late signing, a missing sheet)
        const unknown = evs.flatMap((e) => [[e.af_player_id, e.player_name], [e.af_assist_id, e.assist_name]])
          .filter(([id]) => id && !playerIds.has(id));
        if (unknown.length) {
          const more = await upsertPlayers(uniq(unknown.map(([id, name]) => ({ af_id: id, name: name ?? "Player", sport: "soccer", updated_at: now() })), (p) => p.af_id));
          for (const [k, v] of more) playerIds.set(k, v);
        }
        const rows2 = evs.map((e) => ({
          match_id: matchId, provider_key: e.provider_key, type: e.type, minute: e.minute, injury_time: e.injury_time,
          team_id: teamIds.get(e.af_team_id) ?? null,
          player_id: playerIds.get(e.af_player_id) ?? null, player_name: e.player_name,
          assist_player_id: playerIds.get(e.af_assist_id) ?? null, assist_name: e.assist_name,
          own_goal: e.own_goal,
        }));
        if (rows2.length) must(await db.from("match_events").upsert(uniq(rows2, (r) => r.provider_key), { onConflict: "match_id,provider_key" }), "match_events");
        // VAR took a goal away: it stops appearing in the feed, so it goes from here too
        let del = db.from("match_events").delete().eq("match_id", matchId);
        if (rows2.length) del = del.not("provider_key", "in", `(${rows2.map((r) => `"${r.provider_key}"`).join(",")})`);
        must(await del, "match_events cleanup");

        const m = matchRow(f, code);
        delete m.af_fixture_id;
        must(await db.from("matches").update({ ...m, provider_updated: now(),
          detail_at: (lineup.length || rows2.length) ? now() : undefined }).eq("id", matchId), "match detail");
      });
    }
  }
  return seen;
}

async function squads(base, cfg) {
  const teams = must(await db.rpc("sync_squads", { p_limit: cfg.squad_batch ?? 40 }), "sync_squads");
  let n = 0;
  for (const t of teams) {
    if (!(await afford(1, "squads"))) break;
    const rows = await get(base, "players/squads", { team: t.af_id });
    if (!rows?.length) continue;
    if (DRY) { n++; continue; }
    const players = (rows[0].players ?? []).filter((p) => p.id).map((p) => ({
      af_id: p.id, name: p.name, position: p.position ?? null, shirt: num(p.number),
      team_id: t.team_id, sport: "soccer", updated_at: now(),
    }));
    if (players.length) await upsertPlayers(players);
    must(await db.from("teams").update({ roster_checked_at: now() }).eq("id", t.team_id), "roster checked");
    n++;
  }
  return n;
}

async function odds(base, cfg) {
  const needs = must(await db.rpc("sync_odds_needs", { p_limit: cfg.odds_batch ?? 20 }), "sync_odds_needs");
  let n = 0;
  for (const o of needs) {
    if (!(await afford(1, "odds"))) break;
    const rows = await get(base, "odds", { fixture: o.fixture_id });
    if (DRY) { n++; continue; }
    const priced = rows?.length ? parseOdds(rows[0]) : {};
    // stamped either way: a fixture nobody has priced yet must not be asked about again a
    // minute later, or the odds pass eats the whole day's budget
    const patch = { odds_checked_at: now() };
    if (Object.keys(priced).length) { patch.odds = priced; patch.total_line = priced.total?.line ?? null; n++; }
    must(await db.from("matches").update(patch).eq("id", o.match_id), "odds");
  }
  return n;
}

// §7 Drain the email queue.
//
// `0006` had pg_cron do this through pg_net, which needs the service-role key stored in the
// database's vault. The key is already on this host, in sync/.env, so the queue is drained from
// here instead and the key never goes near the database. Guarded both ways: a mail failure
// cannot stop the match sync, and the sync cannot stop the mail.
//
// (To hand it back to Supabase instead, put `project_url` and `service_role_key` in the vault
// and schedule pool.call_edge_function('send-notifications') — the function is there and ready.
// Then drop this step, or the queue is drained twice a minute, which is only wasteful.)
async function drainMail() {
  // ask first: an empty queue is the normal case, and waking the function costs an invocation
  const { count, error } = await db.from("notifications").select("id", { count: "exact", head: true })
    .is("sent_at", null).is("error", null).lte("scheduled_for", now());
  if (error) throw new Error(error.message);
  if (!count) return 0;
  const r = await fetch(`${env.SUPABASE_URL}/functions/v1/send-notifications`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}` },
    body: "{}",
    signal: AbortSignal.timeout(55000),
  });
  if (!r.ok) throw new Error(`send-notifications ${r.status}: ${(await r.text()).slice(0, 200)}`);
  const j = await r.json();
  return j.sent ?? 0;
}

// ---------------------------------------------------------------------------
async function main() {
  const t0 = Date.now(), state = loadState();
  const cfg = DRY
    ? { base: "https://v3.football.api-sports.io", fixture_batch: 20, window_days_back: 2, window_days_forward: 8 }
    : must(await db.from("config").select("value").eq("key", "football_api").single(), "config").value;
  const base = cfg.base ?? "https://v3.football.api-sports.io";

  const doCatalogue = argv.has("--catalogue") || due(state.lastCatalogue, cfg.catalogue_every_days ?? 7);
  // (and once when the state predates `fixtureLeagues`, so it learns which leagues have been fetched)
  const doFixtures = argv.has("--fixtures") || due(state.lastFixtures, cfg.fixtures_every_days ?? 1) || !state.fixtureLeagues;
  const doSquads = argv.has("--squads") || due(state.lastSquads, cfg.squads_every_days ?? 1);

  let cat = 0, fx = null, sq = 0, od = 0;
  if (doCatalogue) { cat = await catalogue(base); if (cat) state.lastCatalogue = now(); }
  if (doFixtures) {
    fx = await fixtures(base, cfg);
    if (fx.got || DRY) { state.lastFixtures = now(); state.fixtureLeagues = fx.codes; }
  } else {
    // a league somebody just followed gets its fixtures on the next pass, not at tomorrow's
    // daily one — otherwise it is missing from the board for up to a day (one request each)
    const known = new Set(state.fixtureLeagues ?? []);
    const fresh = new Set(must(await db.rpc("sync_leagues"), "sync_leagues").map((l) => l.code).filter((c) => !known.has(c)));
    if (fresh.size) {
      fx = await fixtures(base, cfg, fresh);
      state.fixtureLeagues = [...known, ...fresh];
    }
  }

  // every minute: the fixtures in play that somebody is playing, then everything else that has
  // finished and not been settled — the second only costs a request when there is one to check
  const live = DRY ? [] : must(await db.rpc("sync_live_fixtures"), "sync_live_fixtures");
  const liveSeen = await details(base, cfg, live, "live");
  const checks = DRY ? [] : must(await db.rpc("sync_result_checks", { p_limit: cfg.result_batch ?? 40 }), "sync_result_checks");
  const checkSeen = await details(base, cfg, checks.filter((c) => !live.some((l) => l.fixture_id === c.fixture_id)), "results");

  if (doSquads) { sq = await squads(base, cfg); if (sq) state.lastSquads = now(); }
  od = await odds(base, cfg);

  let mailed = 0;
  if (!DRY) {
    must(await db.rpc("process_match_updates"), "settlement");
    // settlement is what fills the queue, so the drain runs straight after it
    mailed = (await isolate("mail", drainMail)) ?? 0;
    state.lastRun = now();
    saveState(state);
  }
  for (const p of problems) log("skipped", p);
  const left = DRY ? "-" : must(await db.rpc("api_left"), "api_left");
  log(`${cat ? `catalogue ${cat} · ` : ""}${fx ? `fixtures ${fx.written}/${fx.got} in ${fx.leagues} leagues · ` : ""}`
    + `live ${liveSeen}/${live.length} · results ${checkSeen} · squads ${sq} · odds ${od} · `
    + `${mailed ? `mailed ${mailed} · ` : ""}`
    + `${spent} requests${refused ? ` · ${refused} refused by the budget` : ""} · ${left} left today · ${Date.now() - t0}ms`);
}

export { matchRow, parseEvents, parseLineups, parseOdds, normal, STATUS };
// importing for a parser check (THEPOOL_NO_MAIN=1) must not run a sync
if (!TESTING) main().catch((e) => { log("sync failed:", e.message); process.exit(1); });
