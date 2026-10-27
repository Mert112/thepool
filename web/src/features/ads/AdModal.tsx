import { useEffect, useState } from "react";
import { ErrorBox, Modal } from "../../components/ui";
import { adNonce, getConfig, getFlag, watchAd } from "./api";
import { consent } from "./consent";
import { showRewarded } from "./rewarded";
import { useI18n } from "../../lib/i18n";

const AD_SECONDS = 25;   // §0026 matches config.ads.stub_seconds: no wait between ads, so this is the whole gap
const AD_REWARD = 0.2;

// §4 / §ads "Get points".
//
// Two paths, one flag. With `gam_rewarded` off this is the twenty-five-second countdown that has
// stood in since `0019`, kept for testing. With it on, the real thing: a nonce from the server
// first, then Google Ad Manager's rewarded slot, and the credit only once Google says the ad
// was watched to the end. No ad, no consent, no fill — nothing is credited, and the page says
// so rather than pretending.
export function AdModal({ onClose, onCredited, reward = AD_REWARD }: { onClose: () => void; onCredited: (balance: number) => void; reward?: number }) {
  const { t, fmt } = useI18n();
  const [left, setLeft] = useState(AD_SECONDS);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [done, setDone] = useState<{ credited: number; left_today: number } | null>(null);
  const [gam, setGam] = useState<{ on: boolean; path: string } | null>(null);

  useEffect(() => {
    Promise.all([getFlag("gam_rewarded"), getConfig<{ ad_unit_path?: string }>("ads")])
      .then(([on, cfg]) => setGam({ on, path: cfg?.ad_unit_path ?? "" }))
      .catch(() => setGam({ on: false, path: "" }));
  }, []);

  // the stub's countdown; the real slot has its own
  useEffect(() => {
    if (done || gam?.on) return;
    const tm = setInterval(() => setLeft((n) => (n > 0 ? n - 1 : 0)), 1000);
    return () => clearInterval(tm);
  }, [done, gam?.on]);

  const credit = async (nonce?: string) => {
    const r = await watchAd(nonce);
    setDone({ credited: r.credited, left_today: r.left_today });
    onCredited(r.balance);
  };

  // the stub
  const collect = async () => {
    setBusy(true); setErr(null);
    try { await credit(); } catch (e: any) { setErr(e.message ?? String(e)); }
    setBusy(false);
  };

  // the real slot: nonce → ad → credit, and nothing is credited unless Google granted it
  const play = async () => {
    setBusy(true); setErr(null); setNote(null);
    if (consent() !== "accepted") { setNote(t.ads.needConsent); setBusy(false); return; }
    try {
      const { nonce } = await adNonce();
      const result = await showRewarded(gam!.path);
      if (result === "granted") await credit(nonce);
      else if (result === "unavailable") setNote(`${t.ads.noAd} ${t.ads.tryAgain}`);
      else setNote(t.ads.watchToEnd);
    } catch (e: any) { setErr(e.message ?? String(e)); }
    setBusy(false);
  };

  return (
    <Modal title={t.ad.title} onClose={onClose}>
      {done ? (
        <div>
          <div className="banner ok" role="status"><b>{t.ad.credited(done.credited)}</b> {done.left_today > 0 ? t.ad.more(done.left_today) : t.ad.allDone}</div>
          <div className="row-of">
            <button className="btn big" onClick={onClose}>{t.common.done}</button>
            {done.left_today > 0 && <button className="btn" onClick={() => { setDone(null); setLeft(AD_SECONDS); setNote(null); }}>{t.ad.another}</button>}
          </div>
        </div>
      ) : gam?.on ? (
        <div>
          <div className="ad-stub">
            <div className="eyebrow">{t.ad.label}</div>
            <div className="small muted">{t.ads.watchToEnd}</div>
          </div>
          {note && <div className="banner warn" role="status"><div>{note}</div></div>}
          <ErrorBox msg={err} />
          <button className="btn big" disabled={busy} onClick={play}>
            {busy ? t.ads.loading : t.ad.collect(reward)}
          </button>
        </div>
      ) : (
        <div>
          <div className="ad-stub">
            <div className="eyebrow">{t.ad.label}</div>
            <div className="num lime ad-count">{fmt.num(left)}</div>
            <div className="small muted">{left > 0 ? t.ad.watchOn : t.ad.watchDone}</div>
            <div className="ad-progress"><i style={{ width: `${((AD_SECONDS - left) / AD_SECONDS) * 100}%` }} /></div>
          </div>
          <p className="tiny muted">{t.ad.stub}</p>
          <ErrorBox msg={err} />
          <button className="btn big" disabled={left > 0 || busy} onClick={collect}>
            {busy ? t.ad.collecting : left > 0 ? t.ad.collectIn(reward, left) : t.ad.collect(reward)}
          </button>
        </div>
      )}
    </Modal>
  );
}
