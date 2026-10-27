// §0027 The stake rule, as the page applies it: whole points, up to what is free, and no more
// than half of what the others have in the call's pot plus ten. tests/economy_test.sql checks the
// same numbers against rpc_save_calls, so page and server cannot drift apart unnoticed.
import test from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import { renderToString } from "react-dom/server";
import { load, NO_DB } from "../../lib/testkit.mjs";

const { stakeLimit, STAKES, I18nProvider, useI18n, translateError } =
  await load(["features/economy/api", "lib/i18n"], { "lib/supabase": NO_DB, "features/ads/rewarded": "export const deviceFingerprint = async () => null;" });

test("an empty pot takes ten at most", () => {
  assert.deepEqual(stakeLimit(0, 0, 100), { cap: 10, max: 10 });
});

test("half of the others' stakes, rounded down, plus ten", () => {
  assert.equal(stakeLimit(10, 0, 100).cap, 15, "Ana's 10 lets Ben stake 15");
  assert.equal(stakeLimit(25, 10, 100).cap, 17, "Ben's 15 lets Ana go to 17");
  assert.equal(stakeLimit(25, 0, 100).cap, 22, "a newcomer measures the whole pot");
});

test("never more than is free, and never below zero", () => {
  assert.equal(stakeLimit(1000, 0, 40).max, 40);
  assert.equal(stakeLimit(1000, 0, 12.8).max, 12, "whole points only");
  assert.equal(stakeLimit(0, 0, -5).max, 0);
});

test("a stake already saved is never pushed out by the cap", () => {
  // Ana saved 50 when the pot was big; the others left, so the pot is only her own 50 now
  assert.deepEqual(stakeLimit(50, 50, 100), { cap: 50, max: 50 });
});

test("the quick buttons", () => {
  assert.deepEqual([...STAKES], [1, 5, 10, 25, 50]);
});

test("the server's stake refusals reach the player in their language", () => {
  let t;
  const Grab = () => { t = useI18n().t; return null; };
  renderToString(h(I18nProvider, null, h(Grab)));
  assert.equal(translateError("The most you can stake on this call right now is 15 — half the pot plus 10.", t),
    "The most you can stake on this call right now is 15 — half the pot plus 10.");
  assert.equal(translateError("You can stake at most 2 on one call — that is what you have free.", t),
    "You can stake at most 2 on one call — that is what you have free.");
  assert.equal(translateError("A stake is a whole number of points — not 2.5", t), "A stake is a whole number of points — not 2.5.");
});
