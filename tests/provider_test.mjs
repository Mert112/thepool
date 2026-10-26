// §provider The API-Football parsers, run against responses the provider actually sent.
//   node --test tests/provider_test.mjs
//
// tests/fixtures/api-football.json is a trimmed copy of four real responses: a finished Süper
// Lig match with its events and line-ups, the same match as a league with no line-up coverage
// sends it, a scheduled fixture, one fixture's odds, and three catalogue entries.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
process.env.THEPOOL_NO_MAIN = "1";
const { matchRow, parseEvents, parseLineups, parseOdds, normal, STATUS } = await import("../sync/api-football.mjs");

const F = JSON.parse(readFileSync(new URL("./fixtures/api-football.json", import.meta.url), "utf8"));

test("a finished match settles on the 90-minute score, not the running total", () => {
  const m = matchRow(F.finished, "TR1");
  assert.equal(m.status, "FINISHED");
  assert.equal(m.competition_code, "TR1");
  assert.equal(m.af_fixture_id, F.finished.fixture.id);
  // the provider separates score.fulltime (90 minutes) from goals (everything)
  assert.equal(m.home_score, F.finished.score.fulltime.home);
  assert.equal(m.away_score, F.finished.score.fulltime.away);
  assert.equal(m.ft_home, F.finished.goals.home);
  assert.equal(m.ft_away, F.finished.goals.away);
  assert.equal(m.duration, "REGULAR");
  assert.equal(m.minute, null);
});

test("extra time and penalties are display only", () => {
  const aet = structuredClone(F.finished);
  aet.fixture.status = { long: "Match Finished", short: "AET", elapsed: 120, extra: null };
  aet.score.fulltime = { home: 1, away: 1 };
  aet.score.extratime = { home: 2, away: 1 };
  aet.goals = { home: 3, away: 2 };
  const m = matchRow(aet, "TR1");
  assert.equal(m.duration, "EXTRA_TIME");
  assert.deepEqual([m.home_score, m.away_score], [1, 1], "calls settle on the score at 90");
  assert.deepEqual([m.ft_home, m.ft_away], [3, 2], "the final score is kept for the screen");

  const pens = structuredClone(aet);
  pens.fixture.status.short = "PEN";
  assert.equal(matchRow(pens, "TR1").duration, "PENALTY_SHOOTOUT");
  assert.deepEqual([matchRow(pens, "TR1").home_score, matchRow(pens, "TR1").away_score], [1, 1]);
});

test("a match in play carries the running score and the minute", () => {
  const live = structuredClone(F.finished);
  live.fixture.status = { long: "Second Half", short: "2H", elapsed: 67, extra: null };
  live.score.fulltime = { home: null, away: null };
  live.goals = { home: 1, away: 0 };
  const m = matchRow(live, "TR1");
  assert.equal(m.status, "IN_PLAY");
  assert.equal(m.minute, 67);
  assert.deepEqual([m.home_score, m.away_score], [1, 0]);
  assert.equal(m.ft_home, null, "nothing is final yet");
  assert.equal(m.duration, null);
});

test("half time is a pause, not a stop", () => {
  const ht = structuredClone(F.finished);
  ht.fixture.status = { long: "Halftime", short: "HT", elapsed: 45, extra: null };
  ht.score.fulltime = { home: null, away: null };
  const m = matchRow(ht, "TR1");
  assert.equal(m.status, "PAUSED");
  assert.equal(m.clock, "HT");
});

test("every status the provider sends maps to one the game knows", () => {
  const known = new Set(["SCHEDULED", "TIMED", "IN_PLAY", "PAUSED", "EXTRA_TIME", "PENALTY_SHOOTOUT",
                         "FINISHED", "POSTPONED", "SUSPENDED", "CANCELLED", "AWARDED"]);
  for (const [short, mapped] of Object.entries(STATUS)) {
    assert.ok(known.has(mapped), `${short} → ${mapped} is not a match_status`);
  }
  assert.equal(STATUS.PST, "POSTPONED");
  assert.equal(STATUS.CANC, "CANCELLED");
  assert.equal(STATUS.ABD, "CANCELLED");
  assert.equal(STATUS.WO, "AWARDED");
});

test("a scheduled fixture has no score at all", () => {
  const m = matchRow(F.scheduled, "TR1");
  assert.equal(m.status, "TIMED");
  assert.equal(m.home_score, null);
  assert.equal(m.away_score, null);
  assert.equal(m.duration, null);
});

test("goals and cards come through; substitutions and missed penalties do not", () => {
  const evs = parseEvents(F.finished);
  const src = F.finished.events;
  const wanted = src.filter((e) => e.type === "Goal" ? !/missed penalty/i.test(e.detail) : e.type === "Card");
  assert.equal(evs.length, wanted.length);
  assert.ok(evs.length > 0);
  for (const e of evs) assert.ok(["goal", "yellow", "red"].includes(e.type));
  assert.equal(evs.filter((e) => e.type === "goal").length, src.filter((e) => e.type === "Goal" && !/missed/i.test(e.detail)).length);
  assert.equal(src.some((e) => e.type === "subst"), true, "the fixture does contain substitutions");
  assert.equal(evs.some((e) => e.type === "subst"), false, "and none of them became an event");
});

test("a goal keeps its assist; an own goal credits nobody", () => {
  const scored = F.finished.events.find((e) => e.type === "Goal" && e.assist?.id);
  const evs = parseEvents(F.finished);
  const got = evs.find((e) => e.type === "goal" && e.af_player_id === scored.player.id);
  assert.equal(got.af_assist_id, scored.assist.id);
  assert.equal(got.own_goal, false);

  const og = structuredClone(F.finished);
  og.events = [{ time: { elapsed: 30, extra: null }, team: { id: 1 }, player: { id: 99, name: "X" },
                 assist: { id: 98, name: "Y" }, type: "Goal", detail: "Own Goal" }];
  const [one] = parseEvents(og);
  assert.equal(one.own_goal, true);
  assert.equal(one.af_player_id, null, "an own goal is not a goalscorer call landing");
  assert.equal(one.af_assist_id, null, "and nobody assisted it");
});

test("a card shown before kick-off counts as minute zero, not minus five", () => {
  const pre = structuredClone(F.finished);
  pre.events = [{ time: { elapsed: -5, extra: null }, team: { id: 1 }, player: { id: 7, name: "Z" },
                  assist: { id: null }, type: "Card", detail: "Yellow Card" }];
  const [e] = parseEvents(pre);
  assert.equal(e.minute, 0);
  assert.equal(e.type, "yellow");
});

test("stoppage time is kept apart from the minute", () => {
  const st = structuredClone(F.finished);
  st.events = [{ time: { elapsed: 90, extra: 4 }, team: { id: 1 }, player: { id: 7, name: "Z" },
                 assist: { id: null }, type: "Card", detail: "Red Card" }];
  const [e] = parseEvents(st);
  assert.equal(e.minute, 90);
  assert.equal(e.injury_time, 4);
});

test("an event key is what the event is, so re-reading a fixture does not duplicate it", () => {
  const a = parseEvents(F.finished).map((e) => e.provider_key);
  const b = parseEvents(structuredClone(F.finished)).map((e) => e.provider_key);
  assert.deepEqual(a, b);
  assert.equal(new Set(a).size, a.length, "and no two events share a key");
});

test("the line-ups are the starting eleven plus whoever came on", () => {
  const lu = parseLineups(F.finished);
  const starters = F.finished.lineups.reduce((n, l) => n + l.startXI.length, 0);
  const cameOn = new Set(F.finished.events.filter((e) => e.type === "subst").map((e) => e.assist?.id).filter(Boolean));
  assert.equal(lu.length, starters + [...cameOn].length);
  assert.ok(lu.every((p) => p.af_player_id && p.af_team_id));
  const bench = F.finished.lineups[0].substitutes.map((p) => p.player.id).filter((id) => !cameOn.has(id));
  for (const id of bench) assert.ok(!lu.some((p) => p.af_player_id === id), "an unused substitute did not play");
});

test("a league with no line-ups falls back to who was on the pitch", () => {
  const lu = parseLineups(F.no_lineups);
  assert.ok(lu.length > 0, "the minutes played are enough to say who took part");
  assert.ok(lu.every((p) => p.af_player_id));
});

test("no line-ups and no minutes means no witness at all", () => {
  const blank = structuredClone(F.finished);
  blank.lineups = []; blank.players = [];
  assert.deepEqual(parseLineups(blank), [], "which is what leaves matches.detail_at null, and voids the player calls");
});

test("the odds give a three-way price, a goals line and a handicap", () => {
  const o = parseOdds(F.odds);
  assert.ok(o.home > 1 && o.away > 1 && o.draw > 1);
  assert.ok(o.provider, "and say which book they came from");
  assert.ok(o.total.line > 0 && o.total.over > 1 && o.total.under > 1);
  assert.ok(o.spread.home > 1 && o.spread.away > 1);
});

test("a quarter line is refused: a pot cannot split a stake in half", () => {
  const o = parseOdds(F.odds);
  assert.equal(o.total.line * 2 % 1, 0, `${o.total.line} is not a whole or half line`);
  assert.equal(o.spread.home_line * 2 % 1, 0, `${o.spread.home_line} is not a whole or half line`);
});

test("the main line is the one the two sides price closest together", () => {
  const made = { bookmakers: [{ name: "Book", bets: [{ name: "Goals Over/Under", values: [
    { value: "Over 1.5", odd: "1.20" }, { value: "Under 1.5", odd: "4.50" },
    { value: "Over 2.5", odd: "1.95" }, { value: "Under 2.5", odd: "1.85" },
    { value: "Over 3.5", odd: "3.80" }, { value: "Under 3.5", odd: "1.26" },
  ] }] }] };
  assert.equal(parseOdds(made).total.line, 2.5);
});

test("odds nobody posted are simply absent", () => {
  assert.deepEqual(parseOdds({ bookmakers: [] }), {});
  assert.deepEqual(parseOdds(null), {});
});

test("names are matched across providers without being changed", () => {
  assert.equal(normal("Fenerbahçe"), normal("Fenerbahce"));
  assert.equal(normal("FC Barcelona"), normal("Barcelona"));
  assert.equal(normal("Beşiktaş JK"), normal("Besiktas JK"));
  assert.equal(normal("Internazionale"), "internazionale");
  assert.notEqual(normal("Manchester United"), normal("Manchester City"));
  assert.notEqual(normal("Real Madrid"), normal("Real Sociedad"));
});

test("the catalogue carries what a league is and where", () => {
  const [superLig, cup, nations] = F.leagues;
  assert.equal(superLig.league.type, "League");
  assert.equal(superLig.country.name, "Turkey");
  assert.equal(cup.league.type, "Cup");
  assert.equal(nations.country.name, "World");
  for (const l of F.leagues) {
    assert.ok(l.seasons[0].year >= 2024);
    assert.equal(typeof l.seasons[0].coverage.fixtures.events, "boolean",
      "coverage.events is what tells us a competition can settle a player call");
  }
});
