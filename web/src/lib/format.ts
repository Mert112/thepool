// Dates, times, numbers and ordinals are the language's business, so they live with it:
// `useI18n().fmt` (src/i18n/index.tsx). Only this is language-free.
export const initials = (name: string | null | undefined) =>
  (name ?? "?").split(" ").map((x) => x[0]).join("").slice(0, 2).toUpperCase();

// less than two hours to kick-off: the deadline turns magenta
export const soon = (iso: string, now: number) => { const ms = new Date(iso).getTime() - now; return ms > 0 && ms < 2 * 3600000; };
