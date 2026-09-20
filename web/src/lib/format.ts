export const initials = (name: string | null | undefined) =>
  (name ?? "?").split(" ").map((x) => x[0]).join("").slice(0, 2).toUpperCase();

export const ord = (n: number) => {
  const s = ["th", "st", "nd", "rd"], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
};

export const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;

const D = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function fmtTime(iso: string) {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}
export function fmtDay(iso: string) {
  const d = new Date(iso), now = new Date();
  const same = (a: Date, b: Date) => a.toDateString() === b.toDateString();
  const tomorrow = new Date(now); tomorrow.setDate(now.getDate() + 1);
  if (same(d, now)) return "Today";
  if (same(d, tomorrow)) return "Tomorrow";
  return `${D[d.getDay()]} ${d.getDate()} ${MO[d.getMonth()]}`;
}
export function fmtWhen(iso: string) { return `${fmtDay(iso)}, ${fmtTime(iso)}`; }

// live countdown text; "In play" once kickoff passes
export function countdown(iso: string, now: number) {
  const ms = new Date(iso).getTime() - now;
  if (ms <= 0) return "In play";
  const h = Math.floor(ms / 3600000), mn = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60;
  if (h >= 48) return `${Math.floor(h / 24)}d ${h % 24}h`;
  return h > 0 ? `${h}h ${String(mn).padStart(2, "0")}m` : `${mn}m ${String(s).padStart(2, "0")}s`;
}
export const soon = (iso: string, now: number) => { const ms = new Date(iso).getTime() - now; return ms > 0 && ms < 2 * 3600000; };

export function ago(iso: string) {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min`;
  if (s < 86400) return `${Math.floor(s / 3600)} hr`;
  if (s < 172800) return "yesterday";
  return `${Math.floor(s / 86400)} days`;
}

export const dateline = () => new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" });
