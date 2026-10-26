// §provider "More leagues": the whole of API-Football's catalogue, a country at a time.
//
// Twelve club competitions plus Türkiye's and Bulgaria's national-team matches are followed by a
// new account, and those are what the board shows. The other twelve hundred are here. Following
// one is also what tells the sync to start spending requests on it (0024), so this is a cost
// decision as much as a preference — which is why nothing is followed by accident.
import { useState } from "react";
import { competitionsIn, followCompetition, myCompetitions, unfollowCompetition, type LeagueRow } from "../lib/api";
import { useLoad } from "../lib/auth";
import { useI18n } from "../i18n";
import { ErrorBox, Modal, Spinner } from "./ui";

export function LeaguesDialog({ onClose }: { onClose: () => void }) {
  const { t } = useI18n();
  const [country, setCountry] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const { data: mine, error: mineErr } = useLoad(() => myCompetitions(), [tick]);
  const { data: rows, loading } = useLoad(async () => (country ? competitionsIn(country) : []), [country, tick]);

  const toggle = async (c: LeagueRow) => {
    setBusy(c.code); setErr(null);
    try {
      if (c.following) await unfollowCompetition(c.code); else await followCompetition(c.code);
      setTick((n) => n + 1);
    } catch (e: any) { setErr(e.message ?? String(e)); }
    setBusy(null);
  };

  const kind = (c: { type: string | null; tier: number | null }) =>
    [c.type === "cup" ? t.leagues.cup : c.type === "league" ? t.leagues.league : null,
     c.tier ? t.leagues.tier(c.tier) : null].filter(Boolean).join(" · ");

  return (
    <Modal title={t.leagues.title} onClose={onClose}>
      <p className="small muted" style={{ marginTop: 0 }}>{t.leagues.blurb}</p>

      <div className="eyebrow" style={{ margin: "14px 0 8px" }}>{t.leagues.following}</div>
      <div className="row-of">
        {(mine?.following ?? []).map((c) => (
          <button key={c.code} className="chip on" disabled={busy === c.code}
                  title={c.default ? t.leagues.isDefault : undefined}
                  onClick={() => toggle({ ...c, following: true } as LeagueRow)}>
            {c.flag_url && <img src={c.flag_url} alt="" className="flag" />}{c.name}
          </button>
        ))}
      </div>

      <div className="eyebrow" style={{ margin: "18px 0 8px" }}>{t.leagues.byCountry}</div>
      <select className="select" value={country ?? ""} onChange={(e) => setCountry(e.target.value || null)}>
        <option value="">{t.leagues.pick}</option>
        {(mine?.countries ?? []).map((c) => <option key={c.country} value={c.country}>{c.country} · {t.leagues.count(c.n)}</option>)}
      </select>

      {loading && country && <Spinner />}
      {country && !loading && (rows ?? []).length === 0 && <div className="muted small" style={{ marginTop: 10 }}>{t.leagues.none}</div>}
      <div className="league-list">
        {(rows ?? []).map((c) => (
          <div className="league-row" key={c.code}>
            <div>
              <b>{c.name}</b>
              <div className="tiny muted">{kind(c)}</div>
            </div>
            <button className={"btn" + (c.following ? "" : " primary")} disabled={busy === c.code} onClick={() => toggle(c)}>
              {c.following ? t.leagues.unfollow : t.leagues.follow}
            </button>
          </div>
        ))}
      </div>
      <ErrorBox msg={err ?? mineErr} />
    </Modal>
  );
}
