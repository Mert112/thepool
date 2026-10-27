// §i18n The default-language rule.
//   node --test tests/lang_test.mjs     (tests/run.sh runs it alongside the SQL suites)
//
// The rule in one line: the first language in the browser's preference order that The Pool
// speaks, otherwise English — and a choice already saved on the profile beats all of it.
import test from "node:test";
import assert from "node:assert/strict";
import { pickLanguage, startingLanguage, isLang, LANGS, FALLBACK } from "../web/src/lib/i18n/detect.js";

test("the three languages, and English as the fallback", () => {
  assert.deepEqual(LANGS, ["en", "tr", "bg"]);
  assert.equal(FALLBACK, "en");
  for (const l of LANGS) assert.ok(isLang(l));
  for (const junk of ["de", "EN-GB", "", null, undefined, 7, {}]) assert.equal(isLang(junk), false);
});

test("a browser asking for one of the three gets it", () => {
  assert.equal(pickLanguage(["en"]), "en");
  assert.equal(pickLanguage(["tr"]), "tr");
  assert.equal(pickLanguage(["bg"]), "bg");
});

test("the region is ignored: tr-CY is Turkish, en-US is English", () => {
  assert.equal(pickLanguage(["tr-TR"]), "tr");
  assert.equal(pickLanguage(["tr-CY"]), "tr");
  assert.equal(pickLanguage(["en-US"]), "en");
  assert.equal(pickLanguage(["bg-BG"]), "bg");
  assert.equal(pickLanguage(["BG"]), "bg");          // case does not matter
  assert.equal(pickLanguage(["tr_TR"]), "tr");       // nor does the separator
  assert.equal(pickLanguage([" bg-BG "]), "bg");     // nor stray whitespace
});

test("anything else is English", () => {
  assert.equal(pickLanguage(["de-DE"]), "en");
  assert.equal(pickLanguage(["fr", "es", "it"]), "en");
  assert.equal(pickLanguage([]), "en");
  assert.equal(pickLanguage(null), "en");
  assert.equal(pickLanguage(undefined), "en");
  assert.equal(pickLanguage([null, 42, {}, "zz"]), "en");
});

test("preference order wins, not the position in our own list", () => {
  assert.equal(pickLanguage(["bg", "tr", "en"]), "bg");
  assert.equal(pickLanguage(["tr", "bg"]), "tr");
  // a language we do not speak is skipped, not treated as a miss
  assert.equal(pickLanguage(["de", "ru", "tr", "en"]), "tr");
  assert.equal(pickLanguage(["de", "ru", "fr"]), "en");
});

test("a Turkish browser lands in Turkish without touching a thing", () => {
  assert.equal(startingLanguage(null, null, ["tr-TR", "en-US"]), "tr");
});

test("a saved profile beats the browser, and this browser's choice beats a cold start", () => {
  // chosen on the profile: that is what the app speaks, whatever the browser prefers
  assert.equal(startingLanguage("bg", "tr", ["en-GB"]), "bg");
  assert.equal(startingLanguage("en", null, ["tr-TR"]), "en");
  // nothing on the profile yet, but this browser has switched before
  assert.equal(startingLanguage(null, "bg", ["tr-TR"]), "bg");
  // nothing anywhere: the browser decides
  assert.equal(startingLanguage(null, null, ["bg-BG"]), "bg");
  assert.equal(startingLanguage(null, null, ["de-DE"]), "en");
  // junk in either store is ignored rather than trusted
  assert.equal(startingLanguage("de", null, ["tr-TR"]), "tr");
  assert.equal(startingLanguage(null, "zz", ["tr-TR"]), "tr");
});
