// §5.8 / §7 Settings: display name, notification toggles (all off-switchable), watched competitions
import { useEffect, useState } from "react";
import { getCompetitions, getSettings, saveSettings, setDisplayName, type Settings as S } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { ErrorBox, Spinner, Toggle } from "../components/ui";

const TOGGLES: Array<[keyof S, string, string]> = [
  ["new_card", "A new card opens", "Someone opens a card in a competition you watch, or in one of your crews."],
  ["deadline_reminder", "Deadline reminder", "One hour before kick-off, if your card is unfinished."],
  ["crew_activity", "Crew activity", "Someone in your crew posts a receipt or calls you out. At most one mail an hour."],
  ["result", "Result mail at full time", "Standings and your card the moment the match settles."],
  ["weekly_digest", "Friday crew card", "The week ahead and where your crew stands."],
];

export default function Settings() {
  const { session, profile, refreshProfile } = useAuth();
  const uid = session!.user.id;
  const [name, setName] = useState(profile?.display_name ?? "");
  const [s, setS] = useState<S | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [savedName, setSavedName] = useState(false);
  const { data, error, loading } = useLoad(async () => ({ settings: await getSettings(uid), comps: await getCompetitions() }), []);
  useEffect(() => { if (data) setS(data.settings); }, [data]);
  useEffect(() => { setName(profile?.display_name ?? ""); }, [profile?.display_name]);
  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  if (!s) return null;

  const update = async (patch: Partial<S>) => {
    const next = { ...s, ...patch }; setS(next);
    try { await saveSettings(uid, patch); } catch (e: any) { setErr(e.message); }
  };
  const toggleComp = (code: string) => {
    const w = s.watched_competitions.includes(code) ? s.watched_competitions.filter((c) => c !== code) : [...s.watched_competitions, code];
    update({ watched_competitions: w });
  };
  const saveName = async () => { try { await setDisplayName(name); await refreshProfile(); setSavedName(true); } catch (e: any) { setErr(e.message); } };

  return (
    <div className="grid two">
      <div className="stack">
        <div className="panel">
          <h2 className="display">Notifications</h2>
          <div className="small muted" style={{ marginBottom: 8 }}>Email only. Every type is switchable, and all of them off is fine. The sign-in link itself is not a notification.</div>
          {TOGGLES.map(([k, label, note]) => (
            <div className="toggle" key={k}>
              <div><div style={{ fontWeight: 700 }}>{label}</div><div className="small muted">{note}</div></div>
              <Toggle on={!!s[k]} onChange={(v) => update({ [k]: v } as Partial<S>)} />
            </div>
          ))}
        </div>
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>Watched competitions</div>
          <div className="small muted" style={{ marginBottom: 10 }}>New public cards in these competitions trigger the "new card" mail. Crew cards always do.</div>
          <div className="row-of">
            {data!.comps.map((c) => <button key={c.code} className={"chip" + (s.watched_competitions.includes(c.code) ? " on" : "")} onClick={() => toggleComp(c.code)}>{c.name}</button>)}
          </div>
        </div>
      </div>
      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>Display name</div>
          <input className="input" value={name} onChange={(e) => { setName(e.target.value); setSavedName(false); }} />
          <div style={{ marginTop: 10 }}><button className="btn primary" disabled={name.trim().length < 2 || name === profile?.display_name} onClick={saveName}>{savedName ? "Saved ✓" : "Save"}</button></div>
        </div>
        <div className="panel small muted">Signed in as {session!.user.email}. There is no password anywhere in the system — sign in again with a fresh link whenever you need to.</div>
        <ErrorBox msg={err} />
      </div>
    </div>
  );
}
