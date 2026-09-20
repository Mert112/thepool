// §5.6 The crew list
import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { createCrew, crewScore, getCrew, getCrewCards, getCrewMembers, getMyCrews, joinCrew, leaderboard } from "../lib/api";
import { useAuth, useLoad } from "../lib/auth";
import { ord, plural } from "../lib/format";
import { Empty, ErrorBox, Modal, Spinner } from "../components/ui";

export default function Crews() {
  const nav = useNavigate();
  const { session } = useAuth();
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
        <div><h2 className="display" style={{ margin: 0 }}>Crews</h2><div className="muted small">The same people, week after week. Invite-only, by code.</div></div>
        <div className="row-of"><button className="btn" onClick={() => setDialog("join")}>Join with a code</button><button className="btn primary" onClick={() => setDialog("create")}>Make a crew</button></div>
      </div>
      {data!.length === 0 && <Empty>No crew yet. Make one and paste the code into the group chat — that is the whole product.</Empty>}
      <div className="grid cards">
        {data!.map((c) => (
          <div key={c.id} className="panel" style={{ display: "flex", flexDirection: "column", gap: 10, cursor: "pointer" }} onClick={() => nav(`/crews/${c.id}`)}>
            <div className="row-of" style={{ justifyContent: "space-between" }}>
              <h3 className="display" style={{ margin: 0 }}>{c.name}</h3>
              <span className={"tag" + (c.owner_id === uid ? " solid" : "")}>{c.owner_id === uid ? "Owner" : "Member"}</span>
            </div>
            {c.description && <div className="small muted">{c.description}</div>}
            <div className="small">{plural(c.members, "member")} · {c.mode} cards · {c.myPos ? `you are ${ord(c.myPos)} on ${c.myPts}` : "no settled cards yet"}</div>
            <div className="small muted">{c.cards.length ? `${c.cards.length} card${c.cards.length > 1 ? "s" : ""} open now` : "No cards open"}</div>
            <div className="tiny" style={{ fontWeight: 700, letterSpacing: "0.04em", textTransform: "uppercase", padding: "9px 12px", borderRadius: 9, background: "var(--ink)", color: c.rival ? (c.us >= c.them ? "var(--lime)" : "var(--magenta)") : "var(--mute)" }}>
              {c.rival ? `${c.name} ${c.us} – ${c.them} ${c.rival.name}` : "No rivalry set"}
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
  const [name, setName] = useState(""); const [note, setNote] = useState(""); const [mode, setMode] = useState<"simple" | "complex">("complex");
  const [err, setErr] = useState<string | null>(null);
  const go = async () => { try { onDone(await createCrew(name, note, mode)); } catch (e: any) { setErr(e.message); } };
  return (
    <Modal title="Make a crew" onClose={onClose}>
      <label className="field"><span>Name</span><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="Desk XI" autoFocus /></label>
      <label className="field"><span>One line about it</span><input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Champions League nights. Nobody has called a red all season." /></label>
      <div className="eyebrow" style={{ marginBottom: 8 }}>Default scoring for the crew's cards</div>
      <div className="row-of" style={{ marginBottom: 14 }}>
        <button className={"pill" + (mode === "simple" ? " on" : "")} onClick={() => setMode("simple")}>Simple</button>
        <button className={"pill" + (mode === "complex" ? " on" : "")} onClick={() => setMode("complex")}>Complex · 7 calls</button>
      </div>
      <ErrorBox msg={err} />
      <button className="btn big" disabled={name.trim().length < 2} onClick={go}>Open the crew</button>
    </Modal>
  );
}

export function JoinCrewDialog({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const [code, setCode] = useState(""); const [err, setErr] = useState<string | null>(null);
  const go = async () => { try { onDone(await joinCrew(code)); } catch (e: any) { setErr(e.message); } };
  return (
    <Modal title="Join a crew" onClose={onClose}>
      <label className="field"><span>Invite code</span><input className="input" value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="NB-4417" autoFocus /></label>
      <ErrorBox msg={err} />
      <button className="btn big" disabled={code.trim().length < 6} onClick={go}>Join</button>
    </Modal>
  );
}
