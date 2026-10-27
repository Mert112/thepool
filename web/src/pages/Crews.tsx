// §5.6 The crew list
import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { createCrew, crewScore, getCrew, getCrewCards, getCrewMembers, getMyCrews, joinCrew } from "../features/crews/api";
import { leaderboard } from "../features/economy/api";
import { useAuth, useLoad } from "../lib/auth";
import { useI18n } from "../lib/i18n";
import { Empty, ErrorBox, Modal, Spinner } from "../components/ui";

export default function Crews() {
  const nav = useNavigate();
  const { session } = useAuth();
  const { t, fmt } = useI18n();
  const uid = session!.user.id;
  const [dialog, setDialog] = useState<"create" | "join" | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const crews = await getMyCrews();
    return Promise.all(crews.map(async (c) => {
      const [table, cards, us, members] = await Promise.all([leaderboard("crew", c.id), getCrewCards(c.id), crewScore(c.id), getCrewMembers(c.id)]);
      const rival = c.rival_crew_id ? await getCrew(c.rival_crew_id) : null;
      const them = c.rival_crew_id ? await crewScore(c.rival_crew_id) : 0;
      const myIdx = table.findIndex((r) => r.user_id === uid);
      return { ...c, table, cards, us, them, rival, members: members.length, myPos: myIdx >= 0 ? myIdx + 1 : null, myPts: myIdx >= 0 ? table[myIdx].points : 0 };
    }));
  }, []);
  if (loading && !data) return <Spinner />;
  if (error) return <ErrorBox msg={error} />;

  return (
    <div>
      <div className="row-of" style={{ justifyContent: "space-between", marginBottom: 18 }}>
        <div><h2 className="display" style={{ margin: 0 }}>{t.crews.title}</h2><div className="muted small">{t.crews.blurb}</div></div>
        <div className="row-of"><button className="btn" onClick={() => setDialog("join")}>{t.crews.joinWithCode}</button><button className="btn primary" onClick={() => setDialog("create")}>{t.crews.makeOne}</button></div>
      </div>
      {data!.length === 0 && <Empty>{t.crews.empty}</Empty>}
      <div className="grid cards">
        {data!.map((c) => (
          <div key={c.id} className="panel" style={{ display: "flex", flexDirection: "column", gap: 10, cursor: "pointer" }} onClick={() => nav(`/crews/${c.id}`)}>
            <div className="row-of" style={{ justifyContent: "space-between" }}>
              <h3 className="display" style={{ margin: 0 }}>{c.name}</h3>
              <span className={"tag" + (c.owner_id === uid ? " solid" : "")}>{c.owner_id === uid ? t.crews.owner : t.crews.member}</span>
            </div>
            {c.description && <div className="small muted">{c.description}</div>}
            <div className="small">{t.crews.members(c.members)} · {t.crews.mode[c.mode]} · {c.myPos ? t.crews.youAre(fmt.ord(c.myPos), fmt.pts(c.myPts)) : t.crews.noSettled}</div>
            <div className="small muted">{c.cards.length ? t.crews.cardsOpen(c.cards.length) : t.crews.noCardsOpen}</div>
            <div className="tiny" style={{ fontWeight: 700, letterSpacing: "0.04em", textTransform: "uppercase", padding: "9px 12px", borderRadius: 9, background: "var(--ink)", color: c.rival ? (c.us >= c.them ? "var(--lime)" : "var(--magenta)") : "var(--mute)" }}>
              {c.rival ? `${c.name} ${fmt.pts(c.us)} – ${fmt.pts(c.them)} ${c.rival.name}` : t.crews.noRivalry}
            </div>
          </div>
        ))}
      </div>
      {dialog === "create" && <CreateCrewDialog onClose={() => setDialog(null)} onDone={(id) => { setDialog(null); reload(); nav(`/crews/${id}`); }} />}
      {dialog === "join" && <JoinCrewDialog onClose={() => setDialog(null)} onDone={(id) => { setDialog(null); reload(); nav(`/crews/${id}`); }} />}
    </div>
  );
}

export function CreateCrewDialog({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const { t } = useI18n();
  const [name, setName] = useState(""); const [note, setNote] = useState(""); const [mode, setMode] = useState<"simple" | "complex">("complex");
  const [err, setErr] = useState<string | null>(null);
  const go = async () => { try { onDone(await createCrew(name, note, mode)); } catch (e: any) { setErr(e.message); } };
  return (
    <Modal title={t.crews.createTitle} onClose={onClose}>
      <label className="field"><span>{t.crews.nameLabel}</span><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder={t.crews.namePlaceholder} autoFocus /></label>
      <label className="field"><span>{t.crews.noteLabel}</span><input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder={t.crews.notePlaceholder} /></label>
      <div className="eyebrow" style={{ marginBottom: 8 }}>{t.crews.defaultScoring}</div>
      <div className="row-of" style={{ marginBottom: 14 }}>
        <button className={"pill" + (mode === "simple" ? " on" : "")} onClick={() => setMode("simple")}>{t.crews.simple}</button>
        <button className={"pill" + (mode === "complex" ? " on" : "")} onClick={() => setMode("complex")}>{t.crews.complex(7)}</button>
      </div>
      <ErrorBox msg={err} />
      <button className="btn big" disabled={name.trim().length < 2} onClick={go}>{t.crews.createGo}</button>
    </Modal>
  );
}

export function JoinCrewDialog({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const { t } = useI18n();
  const [code, setCode] = useState(""); const [err, setErr] = useState<string | null>(null);
  const go = async () => { try { onDone(await joinCrew(code)); } catch (e: any) { setErr(e.message); } };
  return (
    <Modal title={t.crews.joinTitle} onClose={onClose}>
      <label className="field"><span>{t.crews.codeLabel}</span><input className="input" value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder={t.crews.codePlaceholder} autoFocus /></label>
      <ErrorBox msg={err} />
      <button className="btn big" disabled={code.trim().length < 6} onClick={go}>{t.crews.joinGo}</button>
    </Modal>
  );
}
