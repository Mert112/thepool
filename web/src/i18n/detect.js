// §i18n The default-language rule, on its own so it can be tested without a browser.
//
// The Pool speaks three languages. Which one a first-time visitor gets is decided here and
// nowhere else: the browser's own preference order wins if any of it is one of the three,
// otherwise English. Region subtags are ignored — tr-CY is Turkish, en-US is English.

/** @typedef {"en" | "tr" | "bg"} Lang */

/** Every language the app ships, in the order the switcher shows them. */
export const LANGS = /** @type {Lang[]} */ (["en", "tr", "bg"]);

/** The fallback when the browser asks for nothing we speak. */
export const FALLBACK = /** @type {Lang} */ ("en");

/** @param {unknown} v @returns {v is Lang} */
export function isLang(v) {
  return typeof v === "string" && LANGS.includes(/** @type {Lang} */ (v));
}

/**
 * The first language in the browser's preference order that we speak, else English.
 * Accepts anything navigator.languages can hold: "tr", "TR-cy", " bg-BG ", junk, nothing.
 * @param {readonly unknown[] | null | undefined} preferred navigator.languages, most wanted first
 * @returns {Lang}
 */
export function pickLanguage(preferred) {
  for (const raw of preferred ?? []) {
    if (typeof raw !== "string") continue;
    const base = raw.trim().toLowerCase().split(/[-_]/)[0];
    if (isLang(base)) return base;
  }
  return FALLBACK;
}

/**
 * What the app should start in: a choice already saved on the profile beats a choice saved in
 * this browser, and that beats the browser's own preference order.
 * @param {unknown} profileLang saved on profiles.language, or null when never chosen
 * @param {unknown} storedLang what this browser last switched to, or null
 * @param {readonly unknown[] | null | undefined} preferred navigator.languages
 * @returns {Lang}
 */
export function startingLanguage(profileLang, storedLang, preferred) {
  if (isLang(profileLang)) return profileLang;
  if (isLang(storedLang)) return storedLang;
  return pickLanguage(preferred);
}
