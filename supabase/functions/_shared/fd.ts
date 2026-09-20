// football-data.org v4 client. Free tier: 10 requests/minute, 12 competitions.
// Every call is paced so a single function run never trips the limit.

const BASE = "https://api.football-data.org/v4";
const MIN_GAP_MS = 6500; // ≈9 requests/minute
let lastCall = 0;

export const COMPETITIONS = ["PL", "CL", "PD", "BL1", "SA", "FL1", "DED", "PPL", "ELC", "BSA", "EC", "WC"];

export async function fd<T = any>(path: string): Promise<T> {
  const key = Deno.env.get("FOOTBALL_DATA_KEY");
  if (!key) throw new Error("FOOTBALL_DATA_KEY is not set");
  const wait = lastCall + MIN_GAP_MS - Date.now();
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  lastCall = Date.now();
  const res = await fetch(BASE + path, { headers: { "X-Auth-Token": key } });
  if (res.status === 429) {
    // burst protection: back off once and retry
    await new Promise((r) => setTimeout(r, 61_000));
    lastCall = Date.now();
    return fd<T>(path);
  }
  if (!res.ok) throw new Error(`football-data ${res.status} on ${path}: ${await res.text()}`);
  return res.json();
}

export type FdTeam = { id: number; name: string; shortName?: string; tla?: string; crest?: string };
export type FdMatch = {
  id: number;
  utcDate: string;
  status: string;
  minute?: number | null;
  matchday?: number | null;
  stage?: string;
  lastUpdated?: string;
  competition: { code: string; id: number };
  season?: { startDate?: string; endDate?: string };
  homeTeam: FdTeam;
  awayTeam: FdTeam;
  score: {
    winner?: string | null;
    duration?: string;
    fullTime: { home: number | null; away: number | null };
    halfTime?: { home: number | null; away: number | null };
    regularTime?: { home: number | null; away: number | null };
  };
  goals?: Array<{
    minute: number;
    injuryTime?: number | null;
    type?: string;
    team: { id: number };
    scorer: { id: number; name: string } | null;
    assist: { id: number; name: string } | null;
  }>;
  bookings?: Array<{
    minute: number;
    injuryTime?: number | null;
    team: { id: number };
    player: { id: number; name: string };
    card: string;
  }>;
};

export function seasonLabel(m: FdMatch): string | null {
  return m.season?.startDate ? m.season.startDate.slice(0, 4) : null;
}

// 90-minute state (§2.1): regularTime when the match went beyond it, otherwise fullTime.
export function ninetyMinuteScore(m: FdMatch): { home: number | null; away: number | null } {
  const r = m.score.regularTime;
  if (r && r.home != null && r.away != null) return { home: r.home, away: r.away };
  return { home: m.score.fullTime.home, away: m.score.fullTime.away };
}

export function matchRow(m: FdMatch) {
  const s90 = ninetyMinuteScore(m);
  return {
    id: m.id,
    competition_code: m.competition.code,
    season: seasonLabel(m),
    matchday: m.matchday ?? null,
    stage: m.stage ?? null,
    utc_date: m.utcDate,
    status: m.status,
    minute: m.minute ?? null,
    home_team_id: m.homeTeam?.id ?? null,
    away_team_id: m.awayTeam?.id ?? null,
    home_score: s90.home,
    away_score: s90.away,
    ft_home: m.score.fullTime.home,
    ft_away: m.score.fullTime.away,
    duration: m.score.duration ?? null,
    provider_updated: m.lastUpdated ?? null,
  };
}

export function teamRow(t: FdTeam) {
  return { id: t.id, name: t.name, short_name: t.shortName ?? null, tla: t.tla ?? null, crest_url: t.crest ?? null, updated_at: new Date().toISOString() };
}

export const IN_PLAY = ["IN_PLAY", "PAUSED", "EXTRA_TIME", "PENALTY_SHOOTOUT"];
export const FINISHED = ["FINISHED", "AWARDED"];
// sync-fixtures runs at :07 and :37; sync-live yields those minutes so the 10 req/min budget is never shared
export const FIXTURES_MINUTES = [7, 37];

export function ymd(d: Date): string {
  return d.toISOString().slice(0, 10);
}
