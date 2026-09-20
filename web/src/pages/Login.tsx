import { useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { getBoard, type BoardRow } from "../lib/api";
import { useLoad } from "../lib/auth";
import { ErrorBox } from "../components/ui";

export default function Login() {
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
        <div className="eyebrow">Free to play · costly to be wrong</div>
        <h1 className="display" style={{ marginTop: 10 }}>The <span className="lime">Pool</span></h1>
        <p style={{ fontSize: 17, maxWidth: 460, color: "var(--text-2)" }}>
          Call what will happen in a match. Score points for being right. Argue about it with the same crew every week. Nothing is staked but the argument.
        </p>
        {!sent ? (
          <form onSubmit={send} style={{ maxWidth: 420 }}>
            <label className="field"><span>Email</span>
              <input className="input" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" />
            </label>
            <button className="btn big" disabled={busy || !email}>Send me a sign-in link</button>
            <ErrorBox msg={err} />
            <p className="small muted" style={{ marginTop: 14 }}>No password, ever. The link is good for 15 minutes.</p>
          </form>
        ) : (
          <div className="panel lit" style={{ maxWidth: 420 }}>
            <h3 className="display">Check your inbox</h3>
            <p className="muted">A one-time link is on its way to <b style={{ color: "var(--text)" }}>{email}</b>. Open it on this device and you land signed in.</p>
            <button className="btn ghost" onClick={() => setSent(false)}>Use a different address</button>
          </div>
        )}
      </div>
      <div className="right">
        <div className="eyebrow" style={{ marginBottom: 12 }}>Cards open right now</div>
        {teaser.length === 0 && <div className="muted small">The board is quiet. Fixtures land here as soon as they are on.</div>}
        {teaser.map((r: BoardRow) => (
          <div className="teaser" key={r.match_id}>
            <span><span className="faint tiny" style={{ marginRight: 8 }}>{r.competition_code}</span>{r.home_team} v {r.away_team}</span>
            <span className="lime small">{r.playing ? `${r.playing} playing` : "be the first"}</span>
          </div>
        ))}
        <hr className="hr" />
        <div className="small muted stack">
          <div><b style={{ color: "var(--text)" }}>Simple card</b> — the winner and the draw. Two calls, one minute.</div>
          <div><b style={{ color: "var(--text)" }}>Complex card</b> — adds the scoreline, a scorer, an assist, a yellow and a red. 44 points max. Five minutes.</div>
          <div><b style={{ color: "var(--text)" }}>The boost</b> — one per matchday, doubles a call if it lands, costs nothing if it misses.</div>
        </div>
      </div>
    </div>
  );
}
