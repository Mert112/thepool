// §5.7 The album: competitions × call types, a cell fills the first time you land it
import { Fragment } from "react";
import { getCompetitions } from "../features/board/api";
import { getMarkets } from "../features/card/api";
import { getStickers } from "../features/profile/api";
import { useLoad } from "../lib/auth";
import { marketTitle } from "../features/card/calls";
import { useI18n } from "../lib/i18n";
import { Bar, ErrorBox, Spinner } from "../components/ui";

// the one-or-two letters in a cell: initials of the call, so they travel between languages
const SHORT: Record<string, string> = { winner: "W", draw: "D", motm: "MOTM", score: "SC", scorer: "G", assist: "A", yellow: "Y", red: "R",
  total: "O/U", spread: "HCP" };

export default function Album() {
  const { t, fmt } = useI18n();
  const { data, error, loading } = useLoad(async () => {
    const [comps, markets, stickers] = await Promise.all([getCompetitions(), getMarkets(), getStickers()]);
    return { comps, markets, stickers };
  }, []);
  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;
  const { comps, markets, stickers } = data!;
  const has = (code: string, ct: string) => stickers.some((s) => s.competition_code === code && s.call_type === ct);
  const total = comps.length * markets.length;
  const filled = stickers.filter((s) => comps.some((c) => c.code === s.competition_code) && markets.some((k) => k.call_type === s.call_type)).length;
  const near = comps.map((c) => ({ c, of: markets.length, n: markets.filter((k) => has(c.code, k.call_type)).length }))
    .filter((x) => x.n > 0 && x.n < x.of).sort((a, b) => b.n / b.of - a.n / a.of).slice(0, 4);

  return (
    <div className="grid two">
      <div className="panel">
        <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 14 }}>
          <div><h2 className="display" style={{ margin: 0 }}>{t.album.title}</h2><div className="muted small">{t.album.blurb}</div></div>
          <div style={{ textAlign: "right" }}><div className="num lime" style={{ fontSize: 40 }}>{total ? Math.round(filled / total * 100) : 0}%</div><div className="tiny muted">{t.album.of(filled, total)}</div></div>
        </div>
        <div className="scroll-x">
          <div className="album" style={{ gridTemplateColumns: `160px repeat(${markets.length}, minmax(44px, 1fr))`, minWidth: 160 + markets.length * 50 }}>
            <div></div>
            {markets.map((k) => <div key={k.call_type} className="tiny muted" style={{ textAlign: "center", fontWeight: 700 }} title={marketTitle(k, t)}>{SHORT[k.call_type]}</div>)}
            {comps.map((c) => (
              <Fragment key={c.code}>
                <div className="lbl">{c.name}</div>
                {markets.map((k) => <div key={k.call_type} className={"cell" + (has(c.code, k.call_type) ? " on" : "")}>{has(c.code, k.call_type) ? SHORT[k.call_type] : ""}</div>)}
              </Fragment>
            ))}
          </div>
        </div>
        <div className="tiny muted" style={{ marginTop: 8 }}>{markets.map((k) => `${SHORT[k.call_type]} ${marketTitle(k, t).toLocaleLowerCase(fmt.locale)}`).join(" · ")}</div>
      </div>
      <div className="stack">
        <div className="panel">
          <div className="eyebrow" style={{ marginBottom: 8 }}>{t.album.nearly}</div>
          {near.length === 0 && <div className="muted small">{t.album.nearlyEmpty}</div>}
          {near.map(({ c, n, of }) => <div key={c.code} style={{ padding: "8px 0" }}><div className="small" style={{ display: "flex", justifyContent: "space-between" }}><span>{c.name}</span><span className="lime">{n}/{of}</span></div><Bar pct={n / of * 100} /></div>)}
        </div>
        <div className="panel small muted">{t.album.footer}</div>
      </div>
    </div>
  );
}
