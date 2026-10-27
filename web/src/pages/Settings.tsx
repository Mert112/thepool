// §5.8 / §7 Settings: display name, language, notification toggles (all off-switchable), and
// "My leagues" — the leagues you follow, each with a bell for the new-card mail
import { useEffect, useState } from "react";
import { getSettings, saveSettings, setDisplayName, type Settings as S } from "../features/profile/api";
import { useAuth, useLoad } from "../lib/auth";
import { useFollows } from "../features/board/follows";
import { useI18n } from "../lib/i18n";
import { ErrorBox, LangPicker, Spinner, Toggle } from "../components/ui";
import { LeaguesDialog } from "../features/board/LeaguesDialog";

const KEYS: Array<keyof S> = ["new_card", "deadline_reminder", "crew_activity", "result", "weekly_digest"];

export default function Settings() {
  const { session, profile, refreshProfile } = useAuth();
  const { t } = useI18n();
  const uid = session!.user.id;
  const [name, setName] = useState(profile?.display_name ?? "");
  const [s, setS] = useState<S | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [savedName, setSavedName] = useState(false);
  const [leagues, setLeagues] = useState(false);
  const follows = useFollows();
  const { data, error, loading } = useLoad(async () => ({ settings: await getSettings(uid) }), []);
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
          <h2 className="display">{t.settings.notifications}</h2>
          <div className="small muted" style={{ marginBottom: 8 }}>{t.settings.notificationsBlurb}</div>
          {KEYS.map((k) => {
            const [label, note] = t.settings.toggles[k as string];
            return (
              <div className="toggle" key={k}>
                <div><div style={{ fontWeight: 700 }}>{label}</div><div className="small muted">{note}</div></div>
                <Toggle on={!!s[k]} onChange={(v) => update({ [k]: v } as Partial<S>)} />
              </div>
            );
          })}
        </div>
        <div className="panel">
          <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 8 }}>
            <div className="eyebrow">{t.leagues.following}</div>
            <button className="btn" onClick={() => setLeagues(true)}>{t.leagues.more}</button>
          </div>
          <div className="small muted" style={{ marginBottom: 10 }}>{t.leagues.blurb} {t.settings.watchedBlurb}</div>
          <div className="row-of">
            {follows.following.map((c) => {
              const on = s.watched_competitions.includes(c.code);
              return (
                <button key={c.code} className={"chip" + (on ? " on" : "")} aria-pressed={on} title={on ? t.settings.watchOff : t.settings.watchOn} onClick={() => toggleComp(c.code)}>
                  {c.flag_url && <img src={c.flag_url} alt="" className="flag" />}{c.name} <span aria-hidden>{on ? "🔔" : "🔕"}</span>
                </button>
              );
            })}
          </div>
          <ErrorBox msg={follows.error} />
        </div>
      </div>
      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{t.settings.language}</div>
          <div className="small muted" style={{ marginBottom: 10 }}>{t.settings.languageBlurb}</div>
          <LangPicker full />
        </div>
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{t.settings.displayName}</div>
          <input className="input" value={name} onChange={(e) => { setName(e.target.value); setSavedName(false); }} />
          <div style={{ marginTop: 10 }}><button className="btn primary" disabled={name.trim().length < 2 || name === profile?.display_name} onClick={saveName}>{savedName ? t.common.saved : t.common.save}</button></div>
        </div>
        <div className="panel small muted">{t.settings.signedInAs(session!.user.email ?? "")}</div>
        <ErrorBox msg={err} />
      </div>
      {leagues && <LeaguesDialog onClose={() => setLeagues(false)} />}
    </div>
  );
}
