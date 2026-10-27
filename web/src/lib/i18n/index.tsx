// §i18n One provider for the language, the words and the formatting.
//
//   const { t, fmt, lang, setLang } = useI18n();
//
// `t` is the dictionary itself, not a lookup by string, so every key is checked at build time
// and a typo cannot ship. `fmt` formats dates, times and numbers for the chosen language.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { LANGS, startingLanguage, isLang } from "./detect.js";
import type { Lang } from "./lang";
import { en, type Dict } from "./en";
import { tr } from "./tr";
import { bg } from "./bg";

export { LANGS };
export type { Lang, Dict };

const DICTS: Record<Lang, Dict> = { en, tr, bg };
const STORE_KEY = "pool.lang";

export const dictFor = (l: Lang): Dict => DICTS[l] ?? en;

const read = (): string | null => { try { return localStorage.getItem(STORE_KEY); } catch { return null; } };
const write = (l: Lang) => { try { localStorage.setItem(STORE_KEY, l); } catch { /* private window: the profile still remembers */ } };

// ---- formatting --------------------------------------------------------------------------------
export type Fmt = ReturnType<typeof makeFmt>;

export function makeFmt(d: Dict) {
  const L = d.locale;
  const time = new Intl.DateTimeFormat(L, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  const day = new Intl.DateTimeFormat(L, { weekday: "short", day: "numeric", month: "short" });
  const long = new Intl.DateTimeFormat(L, { weekday: "long", day: "numeric", month: "long" });
  const plain = new Intl.NumberFormat(L);
  const upTo2 = new Intl.NumberFormat(L, { maximumFractionDigits: 2 });
  const same = (a: Date, b: Date) => a.toDateString() === b.toDateString();

  const fmtDay = (iso: string) => {
    const dt = new Date(iso), now = new Date();
    const tomorrow = new Date(now); tomorrow.setDate(now.getDate() + 1);
    if (same(dt, now)) return d.when.today;
    if (same(dt, tomorrow)) return d.when.tomorrow;
    return day.format(dt);
  };

  return {
    locale: L,
    // a whole number, grouped for the language
    num: (x: number | null | undefined) => (x == null ? d.common.dash : plain.format(Number(x))),
    // points carry halves, so they are written to two places and trimmed: 100, 90.7, 2.31
    pts: (x: number | null | undefined) => (x == null ? d.common.dash : upTo2.format(Math.round(Number(x) * 100) / 100)),
    signedPts(x: number | null | undefined) { return x != null && Number(x) > 0 ? `+${this.pts(x)}` : this.pts(x); },
    ord: (i: number) => d.when.ordinal(i),
    time: (iso: string) => time.format(new Date(iso)),
    day: fmtDay,
    when: (iso: string) => `${fmtDay(iso)}, ${time.format(new Date(iso))}`,
    dateline: () => long.format(new Date()),
    // the live countdown to kick-off
    countdown: (iso: string, now: number) => {
      const ms = new Date(iso).getTime() - now;
      if (ms <= 0) return d.when.inPlay;
      const h = Math.floor(ms / 3600000), mn = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60;
      if (h >= 48) return d.when.dayHour(Math.floor(h / 24), h % 24);
      return h > 0 ? d.when.hourMin(h, String(mn).padStart(2, "0")) : d.when.minSec(mn, String(s).padStart(2, "0"));
    },
    ago: (iso: string) => {
      const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
      if (s < 60) return d.when.justNow;
      if (s < 3600) return d.when.minsAgo(Math.floor(s / 60));
      if (s < 86400) return d.when.hrsAgo(Math.floor(s / 3600));
      if (s < 172800) return d.when.yesterday;
      return d.when.daysAgo(Math.floor(s / 86400));
    },
  };
}

// ---- the server's refusals, in the player's language ---------------------------------------------
// The database raises in English. Known messages are swapped for the translation; a message we
// have not met still reaches the player, in English, rather than being swallowed.
export function translateError(msg: string | null | undefined, d: Dict): string | null {
  if (!msg) return msg ?? null;
  const raw = msg.trim();
  const exact = d.errors[raw];
  if (exact) return exact;
  let m: RegExpMatchArray | null;
  if ((m = raw.match(/^A stake is a whole number of points — not (.+)$/))) return d.errorPatterns.wholeStake(m[1]);
  if ((m = raw.match(/^You can stake at most (.+) on one call/))) return d.errorPatterns.stakeFree(m[1]);
  if ((m = raw.match(/^The most you can stake on this call right now is (.+) — half the pot plus 10\.$/))) return d.errorPatterns.stakeCap(m[1]);
  if ((m = raw.match(/^Not enough points: you hold (.+), this card stakes (.+), and (.+) is already promised to other open cards\./)))
    return d.errorPatterns.notEnough(m[1], m[2], m[3]);
  if ((m = raw.match(/^A PlayStation 5 takes 1,000,000 points\. You hold (.+)\.$/))) return d.errorPatterns.prizeShort(m[1]);
  if ((m = raw.match(/^call (.+) is not available$/))) return d.errorPatterns.callUnavailable(d.markets[m[1]]?.title ?? m[1]);
  if ((m = raw.match(/^call (.+) is not on a simple card$/))) return d.errorPatterns.notSimple(d.markets[m[1]]?.title ?? m[1]);
  if ((m = raw.match(/^duplicate call (.+)$/))) return d.errorPatterns.duplicate(d.markets[m[1]]?.title ?? m[1]);
  return raw;
}

// ---- the provider -------------------------------------------------------------------------------
type Ctx = {
  lang: Lang;
  t: Dict;
  fmt: Fmt;
  setLang: (l: Lang) => void;
  /** adopt the language saved on a profile, or save this browser's choice if it has none yet */
  syncProfile: (saved: string | null | undefined) => Lang | null;
};

const I18n = createContext<Ctx | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(() =>
    startingLanguage(null, read(), typeof navigator === "undefined" ? [] : navigator.languages ?? [navigator.language]));

  useEffect(() => { document.documentElement.lang = lang; }, [lang]);

  const setLang = useCallback((l: Lang) => { if (isLang(l)) { write(l); setLangState(l); } }, []);

  // The profile is the authority once it holds a choice; until then this browser's guess is, and
  // the caller writes it back so the emails match what the app is showing.
  const syncProfile = useCallback((saved: string | null | undefined): Lang | null => {
    if (isLang(saved)) { write(saved); setLangState(saved); return null; }
    const guess = startingLanguage(null, read(), typeof navigator === "undefined" ? [] : navigator.languages ?? [navigator.language]);
    setLangState(guess);
    return guess;   // nothing saved yet: tell the caller to persist this one
  }, []);

  const value = useMemo<Ctx>(() => {
    const t = dictFor(lang);
    return { lang, t, fmt: makeFmt(t), setLang, syncProfile };
  }, [lang, setLang, syncProfile]);

  return <I18n.Provider value={value}>{children}</I18n.Provider>;
}

export function useI18n(): Ctx {
  const c = useContext(I18n);
  if (!c) throw new Error("useI18n outside I18nProvider");
  return c;
}
