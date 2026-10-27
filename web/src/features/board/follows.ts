// §provider "My leagues": the one copy of which competitions this account follows.
//
// The board, Settings and the "More leagues" dialog all read this, so a follow or unfollow shows
// everywhere the moment it is tapped. (Each used to fetch its own copy and refresh it on its own
// schedule, so the lists disagreed until the dialog was closed.) The change is applied here
// first and sent second; if the server refuses it, the list is reloaded from the server.
import { useEffect, useSyncExternalStore } from "react";
import { followCompetition, myCompetitions, unfollowCompetition, type CountryRow, type Following } from "./api";

type State = { following: Following[]; countries: CountryRow[]; loaded: boolean; error: string | null };
let state: State = { following: [], countries: [], loaded: false, error: null };
let loading: Promise<void> | null = null;
const listeners = new Set<() => void>();
const set = (patch: Partial<State>) => { state = { ...state, ...patch }; listeners.forEach((l) => l()); };

export function reloadFollows(): Promise<void> {
  loading = myCompetitions()
    .then((r) => set({ following: r.following, countries: r.countries, loaded: true, error: null }))
    .catch((e) => set({ loaded: true, error: e.message ?? String(e) }));
  return loading;
}

/** Follow or unfollow. `c` is the league as the caller has it, so it can join the list at once. */
export async function toggleFollow(c: Following, follow: boolean): Promise<void> {
  const before = state.following;
  const rest = before.filter((x) => x.code !== c.code);
  set({ following: follow ? [...rest, c].sort((a, b) => (a.sort_order ?? 500) - (b.sort_order ?? 500) || a.name.localeCompare(b.name)) : rest, error: null });
  try {
    await (follow ? followCompetition(c.code) : unfollowCompetition(c.code));
  } catch (e: any) {
    set({ following: before });
    await reloadFollows();
    throw e;
  }
}

export const getFollows = () => state;
export function subscribeFollows(l: () => void) { listeners.add(l); return () => { listeners.delete(l); }; }

export function useFollows() {
  const s = useSyncExternalStore(subscribeFollows, getFollows, getFollows);
  useEffect(() => { if (!loading) reloadFollows(); }, []);
  return s;
}

/** For signing out: the next account must not see this one's leagues. */
export function forgetFollows() { loading = null; set({ following: [], countries: [], loaded: false, error: null }); }
