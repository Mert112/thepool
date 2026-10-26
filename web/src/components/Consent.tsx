// §ads The cookie banner, and the footer that links to what it is about.
//
// Nothing ad-related loads until this is answered, and a reject is remembered. The banner is a
// bar at the foot of the page rather than a modal: it must not stand between somebody and a
// card that is about to lock.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { consent, loadAdScripts, setConsent } from "../lib/consent";
import { useI18n } from "../i18n";

export function ConsentBar() {
  const { t } = useI18n();
  const [answer, setAnswer] = useState(() => consent());

  useEffect(() => {
    loadAdScripts();                       // a previous visit may already have said yes
    const on = (e: Event) => setAnswer((e as CustomEvent).detail);
    window.addEventListener("pool:consent", on);
    return () => window.removeEventListener("pool:consent", on);
  }, []);

  if (answer) return null;
  return (
    <div className="consent" role="dialog" aria-label={t.consent.title}>
      <div>
        <b>{t.consent.title}</b> <span className="small">{t.consent.body}</span>{" "}
        <Link to="/privacy" className="lime small">{t.consent.more}</Link>
      </div>
      <div className="row-of">
        <button className="btn ghost" onClick={() => { setConsent("rejected"); setAnswer("rejected"); }}>{t.consent.reject}</button>
        <button className="btn primary" onClick={() => { setConsent("accepted"); setAnswer("accepted"); }}>{t.consent.accept}</button>
      </div>
    </div>
  );
}

export function Footer() {
  const { t } = useI18n();
  return (
    <div className="footer">
      <span className="tiny muted">{t.footer.line}</span>
      <span className="row-of">
        <Link to="/about" className="tiny muted">{t.footer.about}</Link>
        <Link to="/privacy" className="tiny muted">{t.footer.privacy}</Link>
      </span>
    </div>
  );
}
