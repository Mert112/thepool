// §5.8 Profile: season points, overall rank, cards, hit rate, streak, points by competition,
// and the full prediction history — every card played, with each call and whether it hit or missed.
import { useState } from "react";
import { verifyPhone } from "./api";
import { useI18n } from "../../lib/i18n";
import { ErrorBox, Modal } from "../../components/ui";

// §0026 one SMS code, once, before the first claim. One number per account; the server says so.
export function PhoneDialog({ onClose, onVerified }: { onClose: () => void; onVerified: () => void }) {
  const { t } = useI18n();
  const [number, setNumber] = useState("");
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const go = async () => {
    setBusy(true); setErr(null);
    try {
      if (!sent) { await verifyPhone({ action: "start", phone: number }); setSent(true); }
      else { await verifyPhone({ action: "check", phone: number, code }); onVerified(); }
    } catch (e: any) { setErr(e.message ?? String(e)); }
    setBusy(false);
  };
  return (
    <Modal title={t.phone.title} onClose={onClose}>
      <p className="small muted" style={{ marginTop: 0 }}>{t.phone.blurb}</p>
      <input className="input" type="tel" autoComplete="tel" placeholder="+90 555 123 4567" value={number} disabled={sent}
             onChange={(e) => setNumber(e.target.value)} />
      {sent && <input className="input" style={{ marginTop: 10 }} inputMode="numeric" autoComplete="one-time-code"
                      placeholder={t.phone.code} value={code} onChange={(e) => setCode(e.target.value)} />}
      {sent && <div className="tiny muted" style={{ marginTop: 6 }}>{t.phone.sentTo(number)} <button className="btn" onClick={() => { setSent(false); setCode(""); }}>{t.phone.change}</button></div>}
      <ErrorBox msg={err} />
      <div style={{ marginTop: 12 }}>
        <button className="btn big primary" disabled={busy || (sent ? code.trim().length < 4 : number.trim().length < 8)} onClick={go}>
          {sent ? t.phone.verify : t.phone.send}
        </button>
      </div>
    </Modal>
  );
}
