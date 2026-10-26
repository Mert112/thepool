// §ads /about — what the game is, in the language you are reading it in.
import { useI18n } from "../i18n";

export default function About() {
  const { t } = useI18n();
  return (
    <div className="prose">
      <h1 className="display">{t.about.title}</h1>
      {t.about.sections.map(([heading, body]) => (
        <section key={heading}>
          <h2 className="display">{heading}</h2>
          <p>{body}</p>
        </section>
      ))}
    </div>
  );
}
