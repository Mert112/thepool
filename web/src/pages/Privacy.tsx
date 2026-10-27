// §ads /privacy — what is held, why, and how to turn the advertising off.
import { useState } from "react";
import { consent, setConsent } from "../features/ads/consent";
import { useI18n } from "../lib/i18n";

export default function Privacy() {
  const { t } = useI18n();
  const [answer, setAnswer] = useState(() => consent());
  const state = answer === "accepted" ? t.privacy.stateAccepted
    : answer === "rejected" ? t.privacy.stateRejected : t.privacy.stateUnset;

  return (
    <div className="prose">
      <h1 className="display">{t.privacy.title}</h1>
      <p className="tiny muted">{t.privacy.updated}</p>
      {t.privacy.sections.map(([heading, body]) => (
        <section key={heading}>
          <h2 className="display">{heading}</h2>
          <p>{body}</p>
          {/* the opt-out sits in the section that explains what it is for */}
          {heading === t.privacy.sections[4][0] && (
            <p>
              <a className="lime" href={t.privacy.adsOptOutUrl} target="_blank" rel="noreferrer noopener">
                {t.privacy.adsOptOut} →
              </a>
            </p>
          )}
        </section>
      ))}
      <section>
        <p className="small muted">{t.privacy.consentNow(state)}</p>
        <div className="row-of">
          <button className="btn" onClick={() => { setConsent("rejected"); setAnswer("rejected"); }}>{t.consent.reject}</button>
          <button className="btn primary" onClick={() => { setConsent("accepted"); setAnswer("accepted"); }}>{t.consent.accept}</button>
        </div>
        <p className="tiny muted">{t.privacy.change}</p>
      </section>
    </div>
  );
}
