// §ads Google Ad Manager's rewarded slot, through the Publisher Tag.
//
// The shape GPT gives us:
//   defineOutOfPageSlot(path, OutOfPageFormat.REWARDED) → a slot, or null if the format is
//   unavailable; then `rewardedSlotReady` hands over a `makeRewardedVisible()` to call, and
//   either `rewardedSlotGranted` (watched to the end) or `rewardedSlotClosed` (gave up).
//
// Nothing here decides whether anybody is paid. The reward comes from the server against a
// nonce it minted before this ran (0025), because `rewardedSlotGranted` carries `{type,
// amount}` and nothing that proves it happened.
import { loadGpt } from "./consent";

export type RewardedResult = "granted" | "closed" | "unavailable";

declare global {
  interface Window { googletag?: any }
}

const TIMEOUT_MS = 12000;

/**
 * Show one rewarded ad. Resolves "granted" only when Google says it was watched; "unavailable"
 * when there is no ad, no consent, or the tag never loaded — and the caller credits nothing.
 */
export async function showRewarded(adUnitPath: string): Promise<RewardedResult> {
  if (!adUnitPath) return "unavailable";
  if (!(await loadGpt())) return "unavailable";
  const googletag = window.googletag;
  if (!googletag) return "unavailable";

  return new Promise<RewardedResult>((resolve) => {
    let settled = false;
    let slot: any = null;
    const done = (r: RewardedResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        googletag.cmd.push(() => {
          if (onReady) googletag.pubads().removeEventListener("rewardedSlotReady", onReady);
          if (onGranted) googletag.pubads().removeEventListener("rewardedSlotGranted", onGranted);
          if (onClosed) googletag.pubads().removeEventListener("rewardedSlotClosed", onClosed);
          if (slot) googletag.destroySlots([slot]);
        });
      } catch { /* the answer still stands */ }
      resolve(r);
    };
    // no fill is the ordinary case, and it must not leave the player staring at a spinner
    const timer = setTimeout(() => done("unavailable"), TIMEOUT_MS);

    let onReady: any, onGranted: any, onClosed: any;
    try {
      googletag.cmd = googletag.cmd || [];
      googletag.cmd.push(() => {
        slot = googletag.defineOutOfPageSlot(adUnitPath, googletag.enums.OutOfPageFormat.REWARDED);
        if (!slot) { done("unavailable"); return; }
        slot.addService(googletag.pubads());

        onReady = (e: any) => { if (e.slot === slot) { clearTimeout(timer); e.makeRewardedVisible(); } };
        onGranted = (e: any) => { if (e.slot === slot) done("granted"); };
        onClosed = (e: any) => { if (e.slot === slot) done("closed"); };

        googletag.pubads().addEventListener("rewardedSlotReady", onReady);
        googletag.pubads().addEventListener("rewardedSlotGranted", onGranted);
        googletag.pubads().addEventListener("rewardedSlotClosed", onClosed);

        googletag.enableServices();
        googletag.display(slot);
      });
    } catch { done("unavailable"); }
  });
}
