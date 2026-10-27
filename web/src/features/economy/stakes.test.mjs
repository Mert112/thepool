// §0028 A stake is any whole number of points you have free. The server enforces it in
// rpc_save_calls (tests/economy_test.sql); this checks the shortcuts and that its refusals reach
// the player in their language.
import test from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import { renderToString } from "react-dom/server";
import { load, NO_DB } from "../../lib/testkit.mjs";

const { STAKES, I18nProvider, useI18n, translateError } = await load(["features/economy/api", "lib/i18n"], {
  "lib/supabase": NO_DB,
  "features/ads/rewarded": "export const deviceFingerprint = async () => null;",
});

test("the quick buttons", () => {
  assert.deepEqual([...STAKES], [1, 5, 10, 25, 50]);
});

test("the server's stake refusals reach the player in their language", () => {
  let t;
  const Grab = () => { t = useI18n().t; return null; };
  renderToString(h(I18nProvider, null, h(Grab)));
  assert.equal(translateError("You can stake at most 40 on one call — that is what you have free.", t),
    "You can stake at most 40 on one call — that is what you have free.");
  assert.equal(translateError("A stake is a whole number of points — not 2.5", t), "A stake is a whole number of points — not 2.5.");
});
