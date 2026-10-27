import { useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { getBoard, type BoardRow } from "../features/board/api";
import { useLoad } from "../lib/auth";
import { useI18n } from "../lib/i18n";
import { ErrorBox, LangPicker } from "../components/ui";

export default function Login() {
  const { t } = useI18n();
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const { data: board } = useLoad(getBoard, []);
  const teaser = (board ?? []).filter((r) => r.phase !== "settled" && r.card_count > 0).slice(0, 5);

  const send = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setErr(null);
    const { error } = await supabase.auth.signInWithOtp({ email: email.trim(), options: { emailRedirectTo: window.location.origin } });
    setBusy(false);
    if (error) setErr(error.message); else setSent(true);
  };

  return (
    <div className="login">
      <div className="left">
        <div className="row-of" style={{ justifyContent: "space-between" }}>
          <div className="eyebrow">{t.login.eyebrow}</div>
          <LangPicker />
        </div>
        <h1 className="display" style={{ marginTop: 10 }}>The <span className="lime">Pool</span></h1>
        <p style={{ fontSize: 17, maxWidth: 460, color: "var(--text-2)" }}>{t.login.pitch}</p>
        {!sent ? (
          <form onSubmit={send} style={{ maxWidth: 420 }}>
            <label className="field"><span>{t.login.email}</span>
              <input className="input" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder={t.login.emailPlaceholder} />
            </label>
            <button className="btn big" disabled={busy || !email}>{t.login.send}</button>
            <ErrorBox msg={err} />
            <p className="small muted" style={{ marginTop: 14 }}>{t.login.noPassword}</p>
          </form>
        ) : (
          <div className="panel lit" style={{ maxWidth: 420 }}>
            <h3 className="display">{t.login.checkInbox}</h3>
            <p className="muted">{t.login.onItsWay} <b style={{ color: "var(--text)" }}>{email}</b>{t.login.openOnDevice}</p>
            <button className="btn ghost" onClick={() => setSent(false)}>{t.login.differentAddress}</button>
          </div>
        )}
      </div>
      <div className="right">
        <div className="eyebrow" style={{ marginBottom: 12 }}>{t.login.cardsOpen}</div>
        {teaser.length === 0 && <div className="muted small">{t.login.quiet}</div>}
        {teaser.map((r: BoardRow) => (
          <div className="teaser" key={r.match_id}>
            <span><span className="faint tiny" style={{ marginRight: 8 }}>{r.competition_code}</span>{r.home_team} {t.common.v} {r.away_team}</span>
            <span className="lime small">{r.playing ? t.login.playing(r.playing) : t.login.beTheFirst}</span>
          </div>
        ))}
        <hr className="hr" />
        <div className="small muted stack">
          <div><b style={{ color: "var(--text)" }}>{t.login.simpleCard}</b>{t.login.simpleCardIs}</div>
          <div><b style={{ color: "var(--text)" }}>{t.login.complexCard}</b>{t.login.complexCardIs}</div>
          <div><b style={{ color: "var(--text)" }}>{t.login.theStake}</b>{t.login.theStakeIs}</div>
          <div><b style={{ color: "var(--text)" }}>{t.login.theJackpot}</b>{t.login.theJackpotIs}</div>
        </div>
      </div>
    </div>
  );
}
