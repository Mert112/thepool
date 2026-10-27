// §5.6 "Opening a card": pick the audience, pick the scoring
import { useState } from "react";
import { type BoardRow } from "../board/api";
import { getMarkets, openCard, type Market } from "./api";
import { getMyCrews } from "../crews/api";
import { useLoad } from "../../lib/auth";
import { marketTitle, offered } from "./calls";
import { useI18n, type Dict } from "../../lib/i18n";
import { ErrorBox, Modal } from "../../components/ui";

const listOf = (ks: Market[], t: Dict) => t.list(ks.map((k) => marketTitle(k, t)));

export function CreateCardDialog({ row, onClose, onDone, defaultCrew }: { row: BoardRow; onClose: () => void; onDone: (cardId: string) => void; defaultCrew?: string | null }) {
  const { t, fmt } = useI18n();
  const [mode, setMode] = useState<"simple" | "complex">("complex");
  const [audience, setAudience] = useState<string | null>(defaultCrew ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const { data, error: loadErr } = useLoad(async () => {
    const [crews, markets] = await Promise.all([getMyCrews(), getMarkets()]);
    return { crews, markets: markets.filter((k) => offered(k, row)) };
  }, [row.match_id]);
  const on = (m: "simple" | "complex") => (data?.markets ?? []).filter((k) => m === "complex" || k.simple);
  const create = async () => {
    setBusy(true); setErr(null);
    try { onDone(await openCard(row.match_id, mode, audience)); } catch (e: any) { setErr(e.message); setBusy(false); }
  };
  const simpleKs = on("simple"), extraKs = on("complex").filter((k) => !k.simple);
  return (
    <Modal title={t.createCard.title} onClose={onClose}>
      <div className="eyebrow">{row.competition_name} · {fmt.day(row.utc_date)} {fmt.time(row.utc_date)}</div>
      <h3 className="display" style={{ margin: "6px 0 16px" }}>{row.home_team} {t.common.v} {row.away_team}</h3>
      <div className="eyebrow" style={{ marginBottom: 8 }}>{t.createCard.scoring}</div>
      {(["simple", "complex"] as const).map((m) => (
        <button key={m} className={"choice" + (mode === m ? " on" : "")} onClick={() => setMode(m)}>
          <b>{m === "simple" ? t.createCard.simple(on("simple").length) : t.createCard.complex(on("complex").length)}</b>
          <small>{m === "simple" ? t.createCard.simpleIs(listOf(simpleKs, t)) : t.createCard.complexAdds(listOf(extraKs, t))}</small>
        </button>
      ))}
      <div className="tiny muted" style={{ marginTop: 10 }}>{t.createCard.pots}</div>
      <div className="eyebrow" style={{ margin: "14px 0 8px" }}>{t.createCard.audience}</div>
      <button className={"choice" + (audience === null ? " on" : "")} onClick={() => setAudience(null)}><b>{t.createCard.everyone}</b><small>{t.createCard.everyoneNote}</small></button>
      {(data?.crews ?? []).map((c) => (
        <button key={c.id} className={"choice" + (audience === c.id ? " on" : "")} onClick={() => { setAudience(c.id); setMode(c.mode); }}><b>{c.name}</b><small>{t.createCard.crewNote}</small></button>
      ))}
      <ErrorBox msg={err ?? loadErr} />
      <div style={{ marginTop: 14 }}><button className="btn big" disabled={busy || !data} onClick={create}>{t.createCard.go}</button></div>
    </Modal>
  );
}
