// §ads Consent, and the scripts that wait for it.
//
// Google's ad scripts set cookies and build a profile the moment they run. Under the GDPR and
// Turkey's KVKK that needs consent first, so nothing ad-related is on the page until somebody
// says yes: the AdSense tag in index.html is inert (`type="text/plain"`), the Publisher Tag is
// never fetched, and a reject is remembered so the question is not asked again.
//
// Essential storage — the sign-in session, the language, this answer — is not covered by the
// banner and is not switchable: without it the site does not work.

export type Consent = "accepted" | "rejected" | null;

const KEY = "pool.consent";

export function consent(): Consent {
  try {
    const v = localStorage.getItem(KEY);
    return v === "accepted" || v === "rejected" ? v : null;
  } catch { return null; }                       // private window: ask again, load nothing
}

export function setConsent(v: Exclude<Consent, null>) {
  try { localStorage.setItem(KEY, v); } catch { /* the page still honours it for this visit */ }
  if (v === "accepted") loadAdScripts();
  window.dispatchEvent(new CustomEvent("pool:consent", { detail: v }));
}

/** Turn every tag that has been waiting into a live script. Idempotent. */
export function loadAdScripts() {
  if (consent() !== "accepted") return;
  for (const el of Array.from(document.querySelectorAll<HTMLScriptElement>('script[type="text/plain"][data-consent="ads"]'))) {
    const live = document.createElement("script");
    for (const a of Array.from(el.attributes)) {
      if (a.name === "type" || a.name === "data-consent") continue;
      live.setAttribute(a.name, a.value);
    }
    live.async = true;
    el.replaceWith(live);
  }
}

/** Google Publisher Tag, for the rewarded slot. Fetched on demand, and only with consent. */
let gptLoading: Promise<boolean> | null = null;
export function loadGpt(): Promise<boolean> {
  if (consent() !== "accepted") return Promise.resolve(false);
  if ((window as any).googletag?.apiReady) return Promise.resolve(true);
  if (gptLoading) return gptLoading;
  gptLoading = new Promise<boolean>((resolve) => {
    const s = document.createElement("script");
    s.async = true;
    s.src = "https://securepubads.g.doubleclick.net/tag/js/gpt.js";
    s.crossOrigin = "anonymous";
    s.onload = () => resolve(true);
    s.onerror = () => { gptLoading = null; resolve(false); };
    document.head.appendChild(s);
  });
  return gptLoading;
}
