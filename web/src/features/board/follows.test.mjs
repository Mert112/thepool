// §provider "My leagues" is one list: following or unfollowing shows at once, everywhere.
//
// The bug this guards against: the board, Settings and the "More leagues" dialog each fetched
// their own copy of what you follow, so a league followed in the dialog was missing from the
// other lists until the dialog closed. Now follows.ts holds the one copy, and LeaguesDialog reads it.
import test from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import { renderToString } from "react-dom/server";
import { load, NO_DB, PORTAL } from "../../lib/testkit.mjs";

// the fake server: what the database would hold, and a code it refuses
const API = `
  export const server = { follows: ["TR1", "PL"] };
  const league = (code) => ({ code, name: "League " + code, country: null, type: "league", tier: 1, flag_url: null, emblem_url: null, default: false, sort_order: code === "TR1" ? 1 : 11 });
  export async function myCompetitions() { return { following: server.follows.map(league), countries: [{ country: "Turkey", flag_url: null, n: 3 }] }; }
  export async function competitionsIn() { return []; }
  export async function followCompetition(code) { if (code === "NOPE") throw new Error("no competition NOPE"); if (!server.follows.includes(code)) server.follows.push(code); }
  export async function unfollowCompetition(code) { server.follows = server.follows.filter((c) => c !== code); }
`;
const fakes = { "features/board/api": API, "lib/supabase": NO_DB, "react-dom": PORTAL };
// one bundle, so the dialog and the test share the one copy of the list
const { getFollows, subscribeFollows, reloadFollows, toggleFollow, forgetFollows, LeaguesDialog, I18nProvider } =
  await load(["features/board/follows", "features/board/LeaguesDialog", "lib/i18n"], fakes);
const codes = () => getFollows().following.map((c) => c.code);
const league = (code, sort_order = 500) => ({ code, name: "League " + code, country: "Turkey", type: "league", tier: 2, flag_url: null, emblem_url: null, default: false, sort_order });

test("the list loads what the server holds", async () => {
  await reloadFollows();
  assert.deepEqual(codes(), ["TR1", "PL"]);
  assert.equal(getFollows().loaded, true);
});

test("following puts the league in My leagues before the server has answered", async () => {
  let seen = 0;
  const off = subscribeFollows(() => { seen++; });
  const pending = toggleFollow(league("TR2", 2), true);
  assert.deepEqual(codes(), ["TR1", "TR2", "PL"], "at once, and in sort order");
  assert.ok(seen >= 1, "every screen reading the list was told");
  await pending;
  off();
});

test("unfollowing takes it out at once", async () => {
  const pending = toggleFollow(league("TR2", 2), false);
  assert.deepEqual(codes(), ["TR1", "PL"]);
  await pending;
});

test("following twice is still one entry", async () => {
  await toggleFollow(league("AF318"), true);
  await toggleFollow(league("AF318"), true);
  assert.equal(codes().filter((c) => c === "AF318").length, 1);
  await toggleFollow(league("AF318"), false);
});

test("a refused follow is rolled back and the error reaches the caller", async () => {
  await assert.rejects(toggleFollow(league("NOPE"), true), /no competition NOPE/);
  assert.deepEqual(codes(), ["TR1", "PL"]);
});

test("the dialog's My leagues is the shared list, and changes with it", async () => {
  const render = () => renderToString(h(I18nProvider, null, h(LeaguesDialog, { onClose() {} })));
  assert.match(render(), /My leagues/);
  assert.match(render(), /League TR1.*League PL/s, "what the list holds, in order");
  const pending = toggleFollow(league("TR2", 2), true);
  assert.match(render(), /League TR1.*League TR2.*League PL/s, "a follow shows on the next render, before the server answers");
  await pending;
  await toggleFollow(league("TR2", 2), false);
  assert.doesNotMatch(render(), /League TR2/, "and an unfollow takes it out");
});

test("signing out forgets the list", () => {
  forgetFollows();
  assert.deepEqual(codes(), []);
});
