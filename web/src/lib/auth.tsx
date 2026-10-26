import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";
import { getProfile, setLanguage, type Profile } from "./api";
import { useI18n } from "../i18n";

type Auth = { session: Session | null; profile: Profile | null; loading: boolean; refreshProfile: () => Promise<void> };
const Ctx = createContext<Auth>({ session: null, profile: null, loading: true, refreshProfile: async () => {} });

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const { syncProfile } = useI18n();

  // §i18n a profile that has already chosen a language decides what the app speaks; one that
  // never has takes the browser's answer, and we write it back so the mails match the screen.
  const adopt = (p: Profile | null) => {
    setProfile(p);
    if (!p) return;
    const guessed = syncProfile(p.language);
    if (guessed) setLanguage(guessed).catch(() => {});
  };

  const refreshProfile = async () => {
    const { data } = await supabase.auth.getSession();
    const uid = data.session?.user.id;
    adopt(uid ? await getProfile(uid) : null);
  };

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session);
      if (data.session) adopt(await getProfile(data.session.user.id));
      setLoading(false);
    });
    // never await Supabase calls inside this callback (it runs under the auth lock)
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
      if (!s) { setProfile(null); return; }
      setTimeout(() => { getProfile(s.user.id).then(adopt).catch(() => {}); }, 0);
    });
    return () => sub.subscription.unsubscribe();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return <Ctx.Provider value={{ session, profile, loading, refreshProfile }}>{children}</Ctx.Provider>;
}

export const useAuth = () => useContext(Ctx);

// one shared ticking clock for countdowns
export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), intervalMs); return () => clearInterval(t); }, [intervalMs]);
  return now;
}

// small async loader hook
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[]): { data: T | null; error: string | null; reload: () => void; loading: boolean } {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    setLoading(true);
    fn().then((d) => { if (alive) { setData(d); setError(null); } })
      .catch((e) => { if (alive) setError(e.message ?? String(e)); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { data, error, loading, reload: () => setTick((t) => t + 1) };
}
