// §0026 The stub ad is twenty-five seconds, and the dialog never decides what an ad is worth.
import test from "node:test";
import assert from "node:assert/strict";
import { createElement as h } from "react";
import { renderToString } from "react-dom/server";
import { load, NO_DB, PORTAL } from "../../lib/testkit.mjs";

const ADS = `export const getFlag = async () => false; export const getConfig = async () => null;
  export const adNonce = async () => { throw new Error("no nonce in this test"); };
  export const watchAd = async () => { throw new Error("no credit in this test"); };`;
const { AdModal, I18nProvider } = await load(["features/ads/AdModal", "lib/i18n"],
  { "features/ads/api": ADS, "lib/supabase": NO_DB, "react-dom": PORTAL });

test("the stub counts down from twenty-five, and the button waits for it", () => {
  const html = renderToString(h(I18nProvider, null, h(AdModal, { onClose() {}, onCredited() {} })));
  assert.match(html, /ad-count[^>]*>25</, "the countdown starts at 25");
  assert.match(html, /<button[^>]*disabled[^>]*>[^<]*25/, "and the collect button is disabled until it ends");
});
