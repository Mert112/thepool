# Changelog

## 2026-10-27 — players to pick before the match, and a pot that counts your bet

Migration `0030_players_before_kickoff.sql`, the sync script and the web app. Live.

### Players before kick-off

**What was wrong:** squads were fetched **forty teams a day**, oldest-checked first. The board
carries 299 teams; 154 had never been fetched, and four of the five matches in the next three
hours had no players to pick for a goalscorer, an assist or a card. Line-ups were only asked for
once a match was in play.

**Fixed:**
- `sync_squads()` orders teams by their next kick-off, soonest first, and the sync asks for
  twenty every minute (each team still at most once a day). The backlog clears in about eight
  minutes; after that it is roughly 300 requests a day against the 7,000 budget. A team the
  provider has no squad for is marked checked, so it is not asked for every minute.
- **Line-ups before kick-off:** every fixture in the next ninety minutes is asked for — twenty to
  a request, at most every five minutes — until its line-ups are posted, and those players join the
  squads. Nothing settlement reads (`player_stats`) is written by this pass.
- Both steps are isolated in the script, so a failure there cannot hold up settlement.

Within two minutes of going live the next matches had 16–39 players a side.

### The pot on the card counts the bet on screen

The card page showed "0 in the pot" until a bet was saved: the pot, the price on each option and
"about N back if it lands" came from saved bets only. They are now worked out live from what the
others have saved, the pick and amount on screen, and the jackpot — with the server's own formula.

---

## 2026-10-27 — a card opens when the first bet is in

Migration `0029_card_opens_with_bets.sql` and the web app. Live.

Pressing "Open it" used to put the card on the board, in the match page, in the crew room and in
everyone's "a new card opens" mail straight away — before its creator had made a single call. In
production four open cards had no bets at all and were showing as open.

- `cards.opened_at` is stamped by the **first call saved** on the card (a trigger on `calls`, so a
  save that withdraws everything does not count, and a refused save rolls it back).
- Until then the card is listed for **its creator only**: `v_board` and `match_card_count` count
  opened cards, and the match page and crew room ask for cards that are opened or created by you.
- The **new-card mail** goes out when the card opens, not when the row is created.
- `rpc_open_card()` still hands back the same card to anyone who asks for one on that match, so a
  second player pressing "Open it" bets on the same card rather than making a duplicate — and if
  they bet first, that is what opens it.
- Existing cards with players were marked open as of their creation (14); the four empty open cards
  are now hidden until someone bets on them.

`game_test.sql` gained the rule end to end (hidden, not counted, not mailed, not opened by an empty
save, one card per match, opened and listed by the first bet). Its mail count went from 1 to 3: the
two earlier crew cards were created before Tobias joined the crew but opened after, so he now hears
about them — which is the point. All suites pass; production's fingerprints match.

---

## 2026-10-27 — stake what you hold, no handicap, the leagues bar, and cards others can see

Migration `0028_stake_what_you_hold.sql`, the sync script and the web app. All live.

### Stakes: any number you have the points for

The free-amount field from `0027` was there, but the cap that came with it — half of what the
others had in the pot, plus 10 — meant **10 at most on any card nobody had played yet**, so typing
40 turned the field red and greyed out 25 and 50. It looked like nothing had changed. **The cap is
gone** (`stake_cap()` dropped): a stake is any whole number of points from 1 up to what you have
free (balance less what other open cards promise), checked in `rpc_save_calls`. The amount field
now comes first, outlined, with "you have N free" beside it; the quick buttons follow.

### The handicap is off

`markets.enabled = false` for `spread`. Nothing open held a handicap call; the four settled ones
keep their history, and settlement still knows how to judge them, so `football_test.sql` and
`i18n_test.sql` switch it back on inside their own rolled-back transactions. The help text in all
three languages no longer lists it.

### The leagues bar above the matches

**What was wrong:** the sync fetched fixtures for followed leagues **once a day**, so a league
nobody had followed before had no games until the next day's pass — and the bar only showed
leagues that had games, from a board list loaded once and never reloaded. Following a league
therefore changed nothing above the matches.

**Fixed:**
- `sync/api-football.mjs` remembers which leagues its last fixtures pass covered and, every minute,
  fetches any league followed since (one request each). Its first run after the change did a full
  pass: 21 leagues, 194 fixtures, 27 requests. Angola, Estonia and Eswatini's leagues now have
  games; Yemen's has none in the next eight days.
- The bar shows **every league you follow**, in the "My leagues" order; one with no games yet is
  dimmed and says why. Unfollowing removes it at once, and a selected league that is unfollowed
  falls back to "All".
- The board reloads when your follows change.

### A new card is open to everyone straight away

The database made a new card visible at once, but the board loaded once and never refreshed, so
other players saw "Open it" until they reloaded the page — and clicking it showed the create dialog
for a card that already existed. The board now refreshes every 30 seconds while the tab is open and
whenever you come back to it, and "Open it" checks for an existing card first and takes you to it.

### Verified

All suites pass (the cap tests became a no-cap test: Cem stakes his whole 100 on an empty pot).
Production's function and market fingerprints match the local build after `0028`.

---

## 2026-10-27 — a refactor for reading: features, one query helper, strict types, CI

No behaviour change and no schema change. Deployed; production's twelve fingerprints are
identical before and after.

### Lines of code

| | before | after |
|---|---:|---:|
| `web/src` app code | 5,400 | 5,286 |
| `web/src` component tests + their helper | — | 184 |
| `supabase/functions` | 832 | 516 |
| `sync` | 569 | 569 |
| `tests` | 2,638 | 2,545 |
| **all code and tests** | **9,439** | **9,100** |
| lint, CI and hook config (new) | — | 55 |

The data layer alone went from 395 lines to 234. `web/src` as a whole is 70 lines up only because
the follow test moved there from `tests/` and two component tests were added.

### What moved, and why

- **`web/src` is `pages/`, `components/` (shared UI only), `features/<board|card|crews|economy|ads|profile>/`
  and `lib/` (supabase, i18n, format, auth).** Each feature folder holds its `api.ts` and the
  components and tests that belong to it, and nothing else — no empty `hooks/` folders, because
  none of the features has a hook of its own yet.
- **`lib/api.ts` (395 lines) became six `features/*/api.ts` files.** Every query now goes through
  `must()` in `lib/supabase.ts`, which returns the data or throws the database's message — the
  same thing the old `const { data, error } = …; if (error) fail(error); return data as …` did in
  four lines, fifty times over. Each feature's API file is the one place that names its tables and
  functions, so a screen leads to its query in two hops.
- **Dialogs live with their feature:** `AdModal` (out of `components/ui.tsx`), `CreateCardDialog`
  (out of `pages/Board.tsx`), `PhoneDialog` (out of `pages/Profile.tsx`), `LeaguesDialog`.
- **The stake rule is written once** (`stakeLimit` in `features/economy/api.ts`) and the stake
  field uses it, instead of computing the cap inline.
- **`features/ads/Consent.tsx` is `ConsentBar.tsx`**, because `Consent.tsx` and `consent.ts` in the
  same folder collide on case-insensitive filesystems (Windows, macOS).
- **Dead code:** the retired football-data.org edge functions `sync-fixtures` and `sync-live` and
  their `_shared/fd.ts` (317 lines) are deleted from the repo. They are still deployed in Supabase,
  uncalled, as they have been since `0024`; delete them in the dashboard when convenient. A scan
  for exports nothing imports found none, and the one near-duplicate helper (`pickText` in
  `LiveCard`) differs on purpose (its empty-state text), so it stays.

### Strict TypeScript, ESLint, Prettier, the hook

- `tsconfig.json` is `strict` with `noUnusedLocals` / `noUnusedParameters`; it cost one unused import.
- ESLint (`npm run lint`): recommended JS + TypeScript rules and the React hooks rules. One warning
  remains, a deliberate dependency list in `LiveCard`.
- **Prettier is configured (`npm run format -- <files>`) but not enforced.** Formatting the code
  base grows `web/src` from 5,286 lines to 9,014 at 140 columns — and still to 8,183 at 240 —
  because the house style writes one JSX element per line. That contradicts "lines go down", so
  the pre-commit hook lints and does not format. To enforce Prettier: `cd web && npx prettier --write .`
  once, and add `npx prettier --check $changed` to `.githooks/pre-commit`.
- `.githooks/pre-commit` runs ESLint on staged web files. One-time setup per clone:
  `git config core.hooksPath .githooks` (done on the server).

### Tests

- **`npm test`** (in `web/`) runs `node --test src/` — Node's own runner, no new framework.
  `lib/testkit.mjs` bundles the app's real modules with esbuild (already there through Vite),
  swaps the database for fakes, and renders with `react-dom/server`. Three files, 14 tests:
  follow/unfollow and the "My leagues" dialog rendering the shared list as it changes; the stake
  limit and its translated refusals; the 25-second stub ad.
- `tests/run.sh` now runs them too, after the SQL and `.mjs` suites. All pass.
- **`.github/workflows/test.yml`** runs `tests/run.sh` against a Postgres 17 service, then the type
  check and lint, on every push and pull request. It has not run on GitHub yet: nothing was pushed.

### Backend

`supabase/functions/` is one entry per job — `send-notifications` (email, from the sync host) and
`phone-verify` (SMS code, from the browser) — with `_shared/db.ts` and `_shared/i18n.ts`. The sync
job is `sync/api-football.mjs`. No generated database types were added for the functions: they make
four calls between them, and the generated file would be larger than both functions together.
The edge functions were not redeployed; only a comment in `_shared/db.ts` changed.

### Docs

`ARCHITECTURE.md` (the diagram, the invariants, where each concern lives, provider → settlement →
ledger), `MIGRATIONS.md` (the index; migrations stay immutable), and a Quickstart at the top of the
README, whose opening paragraph still described the fixed multipliers and 1,000-point start of
`0019` and now describes the pot.

---

## 2026-10-27 — fraud scoring instead of a wait, free stakes, a phone before the prize, and one "My leagues"

Migrations `0026_ad_fraud_scoring.sql` and `0027_free_stakes.sql`, a new edge function
`phone-verify`, and the web app. All deployed.

### Ads: no wait between them, a score instead

**The sixty-second spacing is gone.** It made every honest player wait and stopped nobody with
ten accounts. (An earlier request in the same batch asked to cut it to 25 seconds; the later one
removed it entirely, so that is what shipped. The 25-second stub and the unchanged nonce rules and
daily cap were kept from the first.)

- **The stub ad is 25 seconds** (`AD_SECONDS`, and `config.ads.stub_seconds`), and "Another" starts
  the next one straight away.
- **Every credit records** the device fingerprint the page sends (a SHA-256 of stable browser
  traits — never stored in the browser), and the IP (`cf-connecting-ip`, else `x-real-ip`, else
  the first `x-forwarded-for`) and user-agent from PostgREST's request headers. The page cannot
  set the last two. A malformed fingerprint is dropped, not refused.
- **`ad_fraud_scores()`** flags an account that shares a fingerprint *or* an IP with **3 or more
  other accounts**, or whose credits **average under 20 seconds apart** within a day. Thresholds
  live in a non-public `config.ad_fraud` row.
- **Flagged accounts still play and earn.** Their prize claims show `⚠ <reasons>` in the new
  **`pool.admin_prize_claims`** view; `pool.admin_ad_fraud` lists every scored account. There was
  no admin view before (claims were handled by hand in the dashboard), so these are database
  views, readable only by the dashboard and the service role.
- The nonce rules and the ten-a-day cap are unchanged. `rpc_watch_ad` now takes
  `(p_nonce, p_fingerprint)`; both are optional, so the old page kept working during the deploy.

### A phone, once, before the first claim

`rpc_claim_prize()` refuses with *"Verify your phone number before your first claim."* until the
account has a row in `phone_verifications` — **one number per account, one account per number**
(primary key on the account, unique on the number). The `phone-verify` edge function sends and
checks the code through **Twilio Verify**; the database decides who may be sent one (at most five
a day per account, three per number) and records the result. Profile opens the dialog when the
claim button is pressed, then files the claim.

**It is behind `app_flags.phone_verification`, which is off.** I could not confirm the Twilio
secrets are set, and turning the flag on without them would block every claim. To switch on:
set `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` and `TWILIO_VERIFY_SERVICE_SID` as edge-function
secrets, then `update pool.app_flags set enabled = true where key = 'phone_verification';`.

The privacy page (three languages) now says what the fraud checks record and why, and names Twilio.

### Free stakes, with a cap so nobody swamps a pot

- **Any whole number from 1** up to the playable balance (balance less other open cards). The
  quick buttons are **1, 5, 10, 25, 50**; `2` left the `stakes` table, which is now only the
  shortcut list, and the foreign key from `calls.stake` was replaced by `check (stake >= 1)`. No
  call in production had ever used 2.
- **The cap: half of what the other players have in that call's pot, plus 10.** An empty pot takes
  10 at most; after someone stakes 10 the next player can put in 15. Keeping or lowering a stake
  you already saved is always allowed, so a shrinking pot cannot lock you out of your own card.
- **Checked on the server** in `rpc_save_calls`: non-numbers, fractions, zero, more than is free
  and over the cap each have their own message, translated in all three languages. The page
  shows the same limit — quick buttons above it are disabled, and the field says "max N here"
  when the cap is below the balance — so the server refusal is rarely seen.
- **Existing tests changed numbers**, because the old scenarios broke the new cap (Ben's 25 after
  Ana's 10). The economy test now plays Ben at 15, and the pot, purse, prices, rake and balances
  were recalculated by hand; Dee's drained-balance case was rewritten for the per-call limit.

### The board's league filter

**What was wrong:** which leagues you follow was fetched three times — by the board, by Settings
and by the "More leagues" dialog — and each copy refreshed on its own trigger (the board and
Settings only when the dialog closed). Settings also showed the follows twice, once as
"Competitions" and once as "Watched competitions" — in Turkish *Takip ettiklerin* and *Takip
edilen turnuvalar*, both reading as "the ones you follow" — and clicking the second list
toggled the new-card mail rather than following anything, while the board's chips came from a
fourth source, the global `active` competitions.

**Fixed:** `web/src/lib/follows.ts` holds the one copy. Following or unfollowing updates it at
once (before the server answers), then tells the server; a refusal rolls it back. The board's
chips, the dialog and Settings all read it. Settings has one **"My leagues"** list (*Liglerim*,
*Моите лиги*), each league with a bell for the new-card mail. A selected board chip whose league
is unfollowed falls back to "All" instead of an empty board.

The bug report folder `/root/bug-league/` did not exist and nothing was pasted, so this was
diagnosed from the code rather than the console errors and screenshots.

### Tests

`bash tests/run.sh`: all suites pass. New: `tests/follows_test.mjs` (follow/unfollow through the
shared list, with a fake server). `tests/ads_test.sql` gained back-to-back ads, what each credit
records, the three flags, the admin warning and the phone gate; `economy`, `game` and `jackpot`
were updated for free stakes and the cap.

### Verified in production

- Before: no call ever staked 2, no prize claims, 6 ad credits — so nothing in the data was hit.
- Every new table, view and function checked for `anon`/`authenticated` access: only
  `rpc_ad_nonce` and `rpc_watch_ad` are callable by players; the rest are closed.
- **Twelve of twelve fingerprints match** the local build, with `call_edge_function` left out of
  the three function hashes — it comes from `0006_cron.sql`, which the local build skips.
- `phone-verify` answers 401 without a sign-in. The new web bundle is live on thepool.today.
- **Not yet seen:** a real ad credit carrying an IP. The gateway header names are the documented
  ones, but the first new row in `ad_views` is the proof — check its `ip` column.

---

## 2026-10-26 — the scheduler, and a backlog retired

`0006_cron.sql` applied at last, three jobs of its six. The 51 notifications that had been
sitting in the queue since September are marked sent without being emailed.

### The backlog

51 rows — 28 results, 12 crew-activity, 10 new-card, 1 correction — queued between 21 September
and 10 October while nothing drained the queue. They are now `sent_at = now()` with
`error = 'retired unsent 2026-10-26: …'`. The error line matters: `sent_at` alone would read as
51 mails that went out, and in a month nobody would remember that they did not. **This was done
before the drain was switched on**, or the first tick would have emailed all of them.

### What of `0006` is live

| Job | Schedule | Applied |
|---|---|---|
| `lock-cards` | every minute | **yes** |
| `deadline-reminders` | every 5 minutes | **yes** |
| `weekly-digest` | Fridays 09:00 UTC | **yes** |
| `sync-fixtures` | twice an hour | **no — retired provider** |
| `sync-live` | every minute | **no — retired provider** |
| `send-notifications` | every minute | **no — drained from the sync host instead** |

**`sync-fixtures` and `sync-live` are not timers that should be running.** They are the
football-data.org edge functions, replaced by ESPN and then by `sync/api-football.mjs` under
`thepool-sync.timer` in `0024`. They have never been scheduled — there was no pg_cron to
schedule them with — and scheduling them now would point a second, retired provider at the same
`matches` rows every minute, writing football-data ids over API-Football ones. They stay
deployed but uncalled. The two lines are commented out in `0006` with the reason against them,
so the file no longer promises something that must not happen.

**The email drain** needs the service-role key, and `call_edge_function()` reads it from the
database's vault — which would mean putting the key in the database. It is already on the sync
host, so `drainMail()` runs at the end of each sync pass instead: same once-a-minute cadence,
key never leaves the host. It asks the queue first and only wakes the function when something is
due, and it is wrapped so a mail failure cannot stop the match sync or the other way round. The
vault route is still there if it is wanted — two secrets and one uncommented line, documented in
`0006`.

### Verified

`pg_cron` 1.6.4 and `pg_net` 0.19.5 installed. `lock-cards` has fired and succeeded. The
notification function answers `{"ok":true,"sent":0}` to the sync host's key and **403** to a
caller without it. The queue is empty, so nothing has been sent — which is the correct outcome
for a backlog that was deliberately retired.

---

## 2026-10-26 — real ads, and asking first

Migration `0025_rewarded_ads.sql`, the AdSense tag, `/privacy` and `/about` in three languages,
and a cookie banner that holds everything back until it is answered.

### The nonce, and why it is ours

Google Publisher Tag's rewarded format **does not hand the page a token**. The
`rewardedSlotGranted` event carries `{type, amount}` and nothing that proves it happened. (Ad
Manager's server-side verification exists, but it calls a URL of ours out of band and cannot
answer "credit this player now".) Taking a string from the client and trusting it would be
security theatre, so the nonce is minted by the server instead:

1. the player taps **Get points**
2. `rpc_ad_nonce()` checks the flag, the daily cap and the sixty-second spacing, and issues a
   single-use nonce that expires in ten minutes
3. the page loads the rewarded slot and waits for `rewardedSlotGranted`
4. `rpc_watch_ad(nonce)` credits **0.2 points** — once, for that nonce, inside the caps

`rpc_watch_ad` is a POST, and a POST can be repeated: that is the whole reason this exists.
`tests/ads_test.sql` covers it — a replayed nonce, somebody else's nonce, an invented nonce, an
expired nonce, a nonce taken out while there was room and spent after the day filled up, the
sixty-second spacing (including the older-nonce way round it), ten a day, and the flag.

The reward moved from 0.5 to **0.2**, and is read from `config.ads` rather than hard-coded in
two places as it was. Ten ads a day is now two points, not five.

### Ads load after consent, not before

- **`web/public/ads.txt`** → `google.com, pub-7965185908085623, DIRECT, f08c47fec0942fa0`,
  live at https://thepool.today/ads.txt.
- **The AdSense tag** is in the `<head>` of `web/index.html` exactly as issued, with one change:
  `type="text/plain"`. That stops the browser executing it. `src/lib/consent.ts` turns it into a
  live script the moment somebody accepts, and never before. The two instructions — "add this
  tag" and "load it only after consent" — cannot both be met by a tag that runs on load; this
  keeps the tag verbatim and the consent real. Reject and it stays inert for good.
- **The Publisher Tag** (`gpt.js`, for the rewarded slot) is fetched on demand and only with
  consent. `showRewarded()` resolves `unavailable` without it, and nothing is credited.
- **The banner** is a bar at the foot of the page, not a modal: it must not stand between
  somebody and a card that is about to lock. Essential storage — the session, the language, this
  answer — is not covered by it and is not switchable.

### /privacy and /about

Both in English, Turkish and Bulgarian, linked from a footer on every page and reachable
**signed out** — a cookie banner that links to a page behind a login is not a cookie banner. The
privacy page names Google AdSense and Ad Manager, says plainly that cookies are used to serve,
measure and personalise ads, links to **Google's ad settings** for the opt-out, and carries the
accept/reject buttons again so the answer can be changed after the banner is gone.

### Still to do before an ad can serve

`config.ads` ships with **`network_code` and `ad_unit_path` empty** and the `gam_rewarded` flag
**off**, so the thirty-second stub is still what plays. Fill those two in from Ad Manager →
Inventory → Ad units, switch the flag on, and the real slot takes over with no deploy:

```sql
update pool.config set value = value || jsonb_build_object(
  'network_code', '<your code>', 'ad_unit_path', '/<your code>/<unit>') where key = 'ads';
update pool.app_flags set enabled = true where key = 'gam_rewarded';
```

With the flag on, the stub stops paying: `rpc_watch_ad(null)` is refused, so the placeholder
cannot be used as a way to be credited without an ad. A test asserts that.

### Verified in production

Twelve of twelve fingerprints match. `rpc_ad_nonce`, `rpc_watch_ad` and `ad_nonces` all refuse an
anonymous caller; `config` gives the browser the `ads` row and nothing else — the request budget
stays server-side. `ads.txt` serves, `/privacy` and `/about` answer 200, and the bundle carries
all three languages of the policy copy.

---

## 2026-10-26 — one provider

Migration `0024_api_football.sql`, a new `sync/api-football.mjs`, and `sync/espn-sync.mjs` gone.
`bash tests/run.sh` runs seven SQL suites and two browser/parser suites. Backed up first to
`/root/thepool-backup-20261026-provider/` — this migration rewrites the identity of rows people
are playing, so the 640 settled matches, 105 calls and 13 ledger rows are in there verbatim.

### Why it is cheaper, not just different

ESPN's feeds were public, unofficial and free, and the design bent around them: a scoreboard read
one day at a time per competition, bookings that only arrived after full time, squads missing for
half the board. API-Football is a paid contract, and `/fixtures?ids=a-b-c` returns **twenty full
fixture details — score, events and line-ups — in one response**. That single fact is what makes
a minute-by-minute live sync affordable, and the whole request plan follows from it.

| Pass | When | Requests |
|---|---|---|
| League catalogue | weekly | 1, for ~1,250 leagues |
| Fixtures | daily, −2 to +8 days | 1 per followed competition |
| Squads | daily | 1 per team with a fixture on the board |
| Odds | once per fixture, retried after 6h | 1 per fixture |
| **Live** | **every minute** | **1 per 20 in-play fixtures that have a card on them** |
| Results | once, after the whistle | 1 per 20 fixtures |

**An idle minute costs nothing.** A match nobody is playing never gets a live pass — only one
results check at full time, which is exactly what the brief asked for and also what keeps the
day inside its budget.

### The budget is the database's

`config.football_api` holds the ceiling (7,000 against the plan's hard 7,500) and `api_usage`
keeps a row per UTC day, counted by endpoint. The sync calls `api_take(n, kind)` **before** it
spends, and a call it cannot afford is not made. A counter inside the script would reset every
time systemd restarted it, which is most of the point.

This caught a real leak within a minute of going live. The first timer pass spent **8 requests on
odds and learned nothing** — a fixture nobody has priced yet is the normal case the day before,
and the pass was asking again every sixty seconds. Eight a minute is 11,520 a day against a
budget of 7,000. `matches.odds_checked_at` now records the asking, not just the answer, and the
fixture is left alone for six hours. An idle pass went from 8 requests to 0.

### Competitions: twelve, plus two national sides

All ~1,250 leagues and cups are loaded into `competitions` with their country and type. Only what
somebody follows is `active`, and only active competitions cost requests. A new account follows:

> Süper Lig · 1. Lig · Türkiye Kupası · Bulgarian First League · Champions League · Europa League
> · Conference League · Premier League · La Liga · Serie A · Bundesliga · Ligue 1

plus **Türkiye's and Bulgaria's national-team matches** — the World Cup and Euro qualifiers, the
Nations League, and the two finals. Those five are followed through `competitions.team_filter`,
which pins them to team ids 777 and 1103: a World Cup qualifying group has fifty other fixtures
in it and none of them belong on this board, nor should they cost a request. Everything else is
under **More leagues**, on the board and in settings, browsable by country.

`tier` is set by hand for the competitions we follow and left null for the rest: **the provider
does not publish a tier**, and guessing one for 1,250 leagues would be inventing data. Competition
names stay as the provider gives them, like team and player names.

### A call nobody can judge is void, not a miss

The old rule scored a goalscorer call a **miss** when a match had no event data — the stake was
lost on a call nobody could say was wrong. `matches.detail_at` now records when the provider last
handed over a fixture's events and line-ups, and at full time without it the player calls are
voided and the stakes handed back.

`detail_at` is stamped by the writes themselves, through a trigger on `match_events` and
`player_stats`, rather than by the caller. A sync that forgot to set it would quietly turn every
judgeable call into a void, and that is not a failure anyone would notice quickly.

Everything settled before this keeps its verdict: 640 matches were backfilled so a rule change
cannot re-judge a match that has already been paid out.

### Mapping off ESPN, without re-keying anything

`teams.espn_key`, `players.id` and `matches.espn_key` are ESPN's, and the settled history hangs
off them. Nothing was re-keyed. `af_id` / `af_fixture_id` were added alongside, and the sync
claims an existing row by name within its competition — accents, case and the `FC`/`SC`/`AC`
noise ignored — before creating a new one. On the first pass: **67 matches and 87 teams claimed,
1,794 players mapped, 713 settled matches left exactly as they were**, and no duplicate fixture
or duplicate team name anywhere in the board's window.

`players.id` was the provider's own id, which stops working the moment the provider changes. It
now has a sequence starting clear of every existing row, so a new player gets an id of ours.

### Also

- Odds come from the provider's book: the three-way price, a goals line and an Asian handicap.
  **Quarter lines (-1.25) are refused** — they split a stake in half in real betting and have no
  meaning in a pot — and the main line is the one the two sides price closest together.
- `api_usage` was readable by anyone for about four minutes after it went in: the schema's
  default privileges grant select on a new table to `anon` (0003), the same gap that caught the
  icons tables in `0022`. It is behind RLS now, and `tests/provider_test.sql` asserts it — so the
  next new table that forgets is caught by the suite rather than by a curl.
- `tests/provider_test.mjs` runs the parsers against **responses API-Football actually sent**,
  kept in `tests/fixtures/api-football.json`: the 90-minute rule, extra time and penalties, every
  status code mapping to a real `match_status`, events, line-ups, the line-up fallback for
  leagues without them, odds, and the cross-provider name matching.

### Verified in production

Twelve of twelve fingerprints match the locally-migrated database. First live pass: 1,249 leagues
catalogued, 195 fixtures across 17 followed competitions, 34 results checked, 40 squads, 7 priced
— 75 requests, 6,904 left for the day. The timer now runs `api-football.mjs`, and an idle pass
costs 0 requests.

---

## 2026-10-26 — three languages

Migration `0023_languages.sql`. `bash tests/run.sh` rebuilds a local Postgres from every
migration, runs the six SQL suites and the browser-rule suite.

### English, Turkish and Bulgarian

- **Every user-facing string goes through a translation file.** `web/src/i18n/en.ts` is the
  source; `tr.ts` and `bg.ts` are annotated `: Dict`, so a key that is missing, renamed or takes
  different arguments **fails `npm run build`** before it can reach anyone. There is no runtime
  lookup by string and so no way to typo a key: `t.board.upcoming` is checked by the compiler,
  and a string that needs a number is a function (`t.board.playing(n)`), not a template with a
  placeholder to get wrong. Nothing user-facing is hard-coded in a page any more, down to the
  "v" between two team names, which is a hyphen in Turkish and a dash in Bulgarian.
- **The default language is the browser's**, if it is one of the three, otherwise English. The
  rule lives alone in `web/src/i18n/detect.js` so it can be tested without a browser, and
  `tests/lang_test.mjs` covers it: region subtags ignored (`tr-CY` is Turkish), case and
  separators ignored, preference order respected, junk skipped rather than treated as a miss.
- **The choice follows the player, not the browser.** `profiles.language` is null until someone
  chooses; the app then takes the browser's answer and writes it back, so the mail sent at full
  time is in the same language as the screen the card was filled on. A null default matters: a
  column defaulting to `'en'` would have silently overruled every Turkish browser that ever
  signed up. `rpc_set_language()` is the only way to set it — the column is not writable by a
  client, and the switcher sits in the top bar and in Settings.
- **Dates, times and numbers** are formatted by `Intl` for the chosen locale, including ordinals
  (`3rd` / `3.` / `3-ти`) and grouped numbers. Emails go further and read their times where
  their readers live: `Europe/London`, `Europe/Istanbul`, `Europe/Sofia`, each saying which.
- **Team, player, competition and crew names are never translated.** They are the provider's or
  the players' own words and pass through exactly as given.

### A call in pieces, not a sentence

`call_label()` builds English prose — "Over 2.5", "Yes — level at 90" — which cannot be
translated after the fact without guessing. `call_parts()` returns the same call as pieces
instead: the call type, the team, the player, the line, the scoreline, the window. The names come
straight from the provider and are passed through; everything else is a key or a number the app
puts its own words round. `card_crowd()` and `my_history()` now carry both, so nothing reading
the old `label` breaks, and a crowd split reads the same as the card it came from in all three
languages. A test asserts no English prose can leak into the pieces — that is the failure that
would quietly turn a Turkish screen half-English.

### Server refusals

The database raises in English. `translateError()` matches the known messages (and the three that
carry numbers — stake, insufficient points, the prize) and swaps them for the translation; one we
have not met still reaches the player in English rather than being swallowed.

### Also fixed, found while doing this

- **FillCard crashed on any card with a saved entry.** `payout()` runs during the render that
  hydrates a saved entry and dereferenced `pickRow`, a `const` declared further down the same
  function — a temporal-dead-zone `ReferenceError`. It only ever fired on the second render, which
  is why it survived: the first render has no picks, so `payout` is never called. The three pot
  lookups are now declared above their first caller.
- **Two outdated lines of copy.** The match page and the "open a card" dialog still said a call
  "returns its stake times the multiplier" and that points "follow the odds — each call pays 10 ×
  its price". Multipliers were removed in `0021`; both now describe the pot.
- The ad modal takes the reward as a prop instead of hard-coding `0.5`, and the "new card" mail
  counts the card's calls instead of claiming 8 and 3.

### For a native speaker to check

The translations are written to read naturally rather than word-for-word, which means some
choices are mine and worth a second opinion:

- **Turkish** — *kupon* for "card" (the betting-slip sense, which is what it is) and *tahmin* for
  "call"; *pot* for the pool of stakes, which is the poker word but also means a blunder
  colloquially; *jackpot* left as the loanword rather than *devreden pot*; *Tabela* for the board
  and *Sen* for the "You" nav item, which keeps the English's directness but is an unusual label;
  *ekip* for "crew"; *yatırım* for "stake".
- **Bulgarian** — *фиш* for "card" and *прогноза* for "call"; *пот* for the pool, same poker
  borrowing as Turkish; *екип* for "crew", where *компания* might read warmer; *Ти* for the "You"
  nav item; *Голмайстор* for the anytime-goalscorer market, which also means "top scorer".
- Both — the longer explanatory paragraphs (the pari-mutuel rules on the fill page, the album
  footer, the streak note) are the most paraphrased, because a literal translation of the English
  reads stiff in both languages.

Competition names are left as the provider gives them, so a Turkish screen says "Premier League",
not "Premier Lig". Say the word if they should be translated too.

### Verified in production

Eleven of the twelve fingerprints matched the locally-migrated database straight away; the other
two — the markets rows and the reference data — matched once the aggregate was ordered under an
explicit `collate "C"`. The mismatch was the comparison's, not the database's: `string_agg(… order
by x)` sorts under the database's own collation, and strings carrying punctuation and mixed case
sort differently between the two servers. The fingerprint now pins the collation.

### Not fixed: no mail has ever been sent

While checking the mail, a pre-existing bug turned up that has nothing to do with translation.
`pg_cron` is not installed on the production project, so `0006_cron.sql` has never been applied,
and nothing else calls the `send-notifications` function — the server's systemd timer runs the
ESPN sync only. **51 notifications are queued, none sent, none errored**, the newest from
2026-10-10. The function itself works and is now deployed in three languages; nothing drains the
queue. Draining it would send 51 mails, some of them sixteen days old, to real addresses, so that
is a decision rather than a fix: say the word and the timer goes in (and whether to send the
backlog or mark it as read first).

---

## 2026-10-26 — football only, a save that cannot lie, and points as a currency

Five pieces of work, one commit each. Migrations `0017`–`0019`; `bash tests/run.sh` rebuilds a
local Postgres from every migration and runs all three suites.

---

### 1. Football only

`0017_football_only.sql` withdraws the six sports added between `0008` and `0016`.

- **The competition decides the sport, not the column.** Applying this to production turned up a
  real bug: 468 matches in NBA, NCAAM, NHL, NFL, WTA and MLB carried the `matches.sport` default
  of `'soccer'`, so the old board filtered them under *Football*. A first draft of this migration
  keyed off that column and left 468 matches orphaned against a deleted competition. It now takes
  the sport from the competition, teams from their `espn_key` namespace (`soccer:1234` against
  `NBA:13`), and players from the team they belong to — and it corrects the drifted column before
  constraining it.
- **Data gone:** basketball, American football, baseball, ice hockey, tennis and MMA — their
  competitions (NBA, WNBA, NCAAM, NFL, NCAAF, MLB, NHL, ATP, WTA, **UFC**), matches, cards,
  entries, calls, teams, players, markets and the `sports` rows themselves. `match_props` (a
  basketball and NFL table) is dropped. Crew receipt posts whose call went with a deleted card are
  deleted first, because `crew_posts` requires a body or a call.
- **Locked shut:** check constraints on `competitions`, `matches`, `markets`, `teams` and
  `players` so nothing but `'soccer'` can land in a sport column again. The columns stay — they
  are woven through the schema — but they can only ever hold one value.
- **Code:** every function that branched on `m.sport` is rewritten for football alone
  (`rpc_save_calls`, `score_call`, `call_conflict`, `card_crowd`, `v_board`, `leaderboard`,
  `enqueue_deadline_reminders`, `sync_tracked_matches`, `sync_roster_needs`). The leaderboard's
  `sport` scope is gone.
- **App:** the sport filter, the per-sport leaderboard scope and the album's sport grouping are
  removed, along with the markets that belonged to the other sports (margin bands, set scores,
  fight method and round, goes-the-distance, player lines).
- **Sync:** `espn-sync.mjs` loses its tennis and fight-night parsers, the box-score reader and the
  player-prop pass. It reads football scoreboards and summaries, nothing else.
- **Tests:** `multisport_test.sql` is replaced by `football_test.sql`.

The handicap stays — it is football's `spread` market, added in `0014`, and it is the call the
brief asks for an explainer for.

---

### 2. The card that saved without the call you made

**Reported:** a card filled in on Türkiye v France later read "No pick" and scored nothing.

**What the production rows say.** Match `1000068`, one crew card, two entries, ten calls — all
saved. Both entries are missing exactly the calls that contradicted the exact scoreline the player
set. One has no result call at all: that is the "No pick · 0".

**The cause was in the form, not the database.** Two calls that cannot both land are a hedge, and
`rpc_save_calls` refuses the whole card, so `FillCard` drops the contradicting call when a new pick
arrives. It did that almost silently — one line of text in the sticky slip at the foot of a long
page, cleared again by the very next tap, while the market it emptied (the result is first on the
card, the scoreline fourth) had already scrolled out of sight. The player saved, the server stored
exactly what it was sent, and the call was gone.

**Fixed:**

- A removal now raises a banner above the card that **stays** until it is dismissed or undone, names
  the pick that caused it, and offers **Undo** to put the dropped calls back.
- The emptied market carries its own inline flag until it is filled again.
- Saving no longer silently drops a pick whose market has left the card — it refuses and says so.
- After writing, the form **reads the entry back through RLS** and confirms what the database
  actually holds, listing every stored call. If what came back differs from what was sent, it says
  so instead of claiming success.

`football_test.sql` pins down both halves of the mechanism: the server's refusal of each
contradicting pair on that exact fixture, and that a save is a full replacement, so a call left out
of the array is deleted.

---

### 3. Feedback

- **Redirect after saving.** Saving lands on the match page, carrying the receipt: it opens with
  "Saved ✓", the calls the database confirmed and what they stake. Dismissible.
- **"Your card is in."** The board shows that in place of "Join" on any fixture you already have an
  entry on, in the button and beside the card column, and sends you to the match page.
- **Explainers.** Every call has a one-line plain-English explainer under its title, on the card and
  in the match page's list. They live in `markets.explainer`, so they are editable without a deploy.
  The handicap reads: *"Your team starts the match with a virtual head start or deficit of N goals;
  your call wins if they are still ahead after the handicap is applied."*
- **Phones.** One column under 700px, a nav that scrolls instead of stacking, 44px minimum on
  everything tappable, a full-width save button, and the two leaderboards restated as narrow grids
  rather than a table that scrolled sideways. `html, body { overflow-x: hidden }` is the backstop.
  The album's grid is the only thing left that scrolls, inside its own box.
- **Prediction history.** The profile lists every card played, newest first, expanding to each call,
  the pick in words, whether it hit, missed or voided, and what it paid. Served by `my_history()`,
  which reuses a new `call_label()` — now the one place that turns a stored call into words.

---

### 4. The point economy

`0019_point_economy.sql`. Points stop being a score and become a currency.

- **1,000 points** to start (`profiles.balance`), with a matching `signup` row in the ledger.
- **A stake on every call** — 10, 25, 50, 100 or 200 — chosen per call, locked onto it at save.
- **Deducted at lock**, not at save. `sync_card_status()` takes the stakes the moment a card locks
  at kick-off, and hands them back if the match is called off and the card reopens.
- **Settlement:** a hit returns `stake × multiplier`; a miss returns nothing; a void hands the stake
  back.

| Call | Multiplier |
|---|---|
| The result — a team | 1.5× |
| The result — the draw | 3× |
| Over / under the goals line | 2× |
| The handicap | 2× |
| The exact scoreline | 8× |
| A goalscorer | 4× |
| An assist | 6× |
| A yellow card | 3× |
| A red card | 10× (35×–120× with a 15-minute window) |

- **One ledger.** `pool.ledger` (`user_id`, signed `amount`, `reason`, `reference`), append-only: a
  trigger refuses every update and delete, no role holds a write grant on it or on
  `profiles.balance`, and only `SECURITY DEFINER` functions move money. `apply_ledger()` is
  idempotent per `(reason, reference)` — it writes the difference between what a reason has already
  paid and what it should have — so a provider correction adjusts a balance instead of paying twice.
  The running sum of a player's rows is always their balance, asserted after every test scenario.
- **Affordability.** `rpc_save_calls` refuses a card that stakes more than the player holds,
  counting what other open cards have already promised. If a balance falls short by kick-off anyway,
  that entry is never staked and its calls settle void rather than taking a balance below zero.
- **Rewarded ads.** "Get points" plays a 30-second placeholder for 100 points, ten a day. The cap is
  structural: `ad_views` is keyed on `(user_id, day, seq)` with `check (seq between 1 and 10)`, so an
  eleventh row cannot exist and two racing calls cannot take one slot. `app_flags.rewarded_ads`
  switches it off. Swap the panel in `AdModal` for a real provider's player; nothing else moves.
- **The prize.** 1,000,000 points claims a PlayStation 5. The profile shows a progress bar and a
  Claim button; `rpc_claim_prize()` writes to `prize_claims` for us to handle by hand, one open
  claim at a time.
- **Leaderboards** rank by balance overall; a crew, a week or a competition ranks on what was won
  there. A card's own number is net — everything that came back, less everything staked — so it
  matches the card's effect on the balance exactly, and can be negative.
- **Tests.** `economy_test.sql` covers the five cases asked for (stake deducted at lock, payout on a
  hit, loss on a miss, refund on a void, the daily ad cap) plus the prize, the append-only ledger,
  the reopened match, a correction adjusting rather than double-paying, and the grants that stop a
  client touching any of it. `game_test` and `football_test` keep their narratives with the new
  arithmetic.

---

### 6. The jackpot, and stakes from a point

`0020_jackpot_rollover.sql`.

**Stakes are now 1, 2, 5, 10, 25, 50** — a point is a real unit and a card can be played for almost
nothing. 100 and 200 are gone; no call on production used either.

**A call nobody lands rolls its losses forward.** The multipliers are untouched: a correct call
still returns `stake × multiplier`, minted. What changes is where the *losing* stakes go, which
until now was nowhere.

- The pot on a call type = the stakes **actually lost** on it. A refunded void never counts, and
  nor does a winner's stake.
- Nobody correct → the house takes a **10% rake** and the rest becomes a jackpot, held per
  competition per call type.
- The next card in that competition shows **"Jackpot: +N points"** on the call while it is open, on
  the card itself and in the match page's list of calls.
- The first card where somebody does land it shares the jackpot among the winners **in proportion
  to what they staked**, on top of their multiplier payout. Shares are floored and the rounding
  remainder stays in the pot rather than being invented.
- Nobody lands it again and that card's pot is added, so it compounds.

**A card's part in the jackpot is decided once**, the first time it settles final, and written to
`jackpot_moves` — zero movements included. The zero rows are the point: a jackpot is a sequence
across cards in time, and the first version of this let a card re-settled after a correction be
judged against *today's* jackpot. The game test caught it — a card from before the jackpot existed
reached forward and scooped 59 points a later card had rolled in. A correction still re-scores the
card and adjusts the multiplier payouts through the ledger; it never moves the jackpot.

`tests/jackpot_test.sql` is new: the rake, the compounding, a void never feeding the pot, one
competition's jackpot staying out of another's, a single winner taking it all, two winners splitting
67 across 60 staked as 11 and 55 with the odd point carried, and settling twice moving nothing. The
other three suites were re-based on the new stakes and now assert the jackpot where it falls.

---

### 7. The pot pays, not the house

`0021_pari_mutuel.sql`. The multipliers are gone and nothing mints points any more.

Every stake on a call type goes into **one pot for that card**. At full time a void is refunded in
full and leaves the pot (no rake on it), the house takes **10%** of what remains as a ledger row,
and the other 90% — plus any jackpot carried in — is split among the correct calls **in proportion
to what they staked**, rounded down to the penny, with the remainder going to the jackpot rather
than to the house or to nobody. If nobody was correct the whole 90% rolls into the competition's
jackpot, exactly as before.

**A balance can now rise exactly four ways**: the 100-point season start, a 0.5-point ad credit, a
share of a pot, and a share of a jackpot. `markets.multiplier`, `markets.pick_multiplier`,
`markets.option_mult`, `calls.multiplier` and `call_multiplier()` are all dropped. `score_call()`
no longer returns a number at all — it decides only what happened, and the pot decides what it was
worth.

**Money is `numeric(14,2)`** throughout, since half a point is now a real amount.

**Before lock**, each call shows what is in its pot and any jackpot riding on it, and each option
shows what one point on it would return at the split as it stands — served by a new `card_pots()`,
aggregate-only like the crowd split.

**The conservation law** is the headline test: `balances + house + jackpots + stakes still riding =
everything ever credited`, asserted after every scenario in `economy_test` and `jackpot_test`,
alongside the weaker `balances + house ≤ credited` you asked for.

Three bugs the tests caught on the way:

- `jackpot_of()` was still declared `int` from `0020`. A 4.50 jackpot read back as 5, so a pot
  would have paid out more than it held. The conservation law would have caught it in production
  eventually; the game test caught it in seconds.
- Emptying and refilling a jackpot in a single upsert of `remainder - jack` failed its own
  `amount >= 0` check: Postgres validates the *proposed* row before the conflict that would have
  turned it into a subtraction. It is two statements now.
- An entry's total was computed from `points_awarded`, which a later correction zeroed — leaving
  the card's number disagreeing with the balance it had actually moved. An entry's number is now
  read back out of the ledger, so the two can never part company. A pot that has been divided and
  paid is not un-divided by a correction; the share stands and the call keeps showing it.

---

### 8. Ten profile icons, nine of them earned

`0022_profile_icons.sql`. Everyone starts with the football and can wear one icon at a time. The
other nine are achievements, and the rarity follows the difficulty you described: a pile of ads is
a grind anyone can finish (uncommon), an exact scoreline takes nerve (rare), a big jackpot takes
luck as well (epic), and the PlayStation is the one icon almost nobody will ever wear (legendary).

| Icon | Rarity | How |
|---|---|---|
| ⚽ The Football | common | yours from the moment you sign up |
| 📋 The Clipboard | common | play five cards through to full time |
| 🧣 The Scarf | common | join a crew, or start one |
| 📺 The Set | uncommon | sit through fifty ads |
| 🎯 The Target | uncommon | land ten calls |
| 🎱 The Eight Ball | rare | call an exact scoreline and watch it come in |
| 💰 The Bag | rare | hold 500 points at once, from a season that starts you on 100 |
| 🎰 The Machine | epic | take a jackpot share worth 100 points or more |
| 🐋 The Whale | epic | take 250 points or more out of a single pot |
| 🎮 The Console | legendary | claim the PlayStation 5 |

Every criterion is a question asked of data the game already keeps, so nothing is tracked
separately and an icon cannot be awarded for something that did not happen. The client cannot
insert into `user_icons`, call `award_icons()` or write `profiles.icon`; `rpc_set_icon()` refuses
an icon you have not unlocked, and `tests/icons_test.sql` proves all three.

The icon travels with the name, so it shows on the table, the standings, the crew room and the top
bar — with a coloured ring for its rarity and a glow on the legendary one.

---

## Decisions I made, and would like checked

These were not spelled out in the brief. Each is easy to reverse.

1. **The boost is gone.** One call a matchday doubled for free, with no downside, is exactly the
   "free points for a correct call" the new economy replaces — under a currency it is a money
   printer. The stake is the lever now (10 → 200 is a twentyfold swing, chosen per call). If you
   want it back, it would most naturally become something you *buy* with points. `entries.
   boost_call_type` and `rpc_set_boost` are dropped.

2. **Everyone's balance was reset to 100.** You chose this over leaving the six live players on
   1,000. Each reset is an `adjustment` row in the ledger, so the books still reconcile and
   "everything ever credited" is 600, not 6,000.

3. **A season start is the only place a round number enters.** With pots paying and a 0.5-point ad
   credit, a player who never plays keeps exactly 100 and will often top the table. That is what a
   zero-sum game looks like, and the game test asserts it rather than hiding it.

4. **The rake is kept, not redistributed.** 10% of *every* pot now leaves the game, not just a
   rolled-over one. It is
   recorded in `jackpot_moves` as its own row so the take is auditable, but nothing spends it yet.

5. **A void never feeds the pot.** A push on the goals line, a player who never came on, an
   abandoned match: the stake is handed back, so there is nothing lost to roll. Only real misses
   fund a jackpot.

6. **"Winner on a draw" is a miss here, not a void.** The brief gives that as the example of a void.
   But football's result market has been 3-way since `0014` — home, draw or away — and the brief's
   own multiplier list has a separate entry for the draw, which only makes sense on a 3-way market.
   So a team pick on a 0–0 loses its stake, and the draw pays 3×. Voids come from pushes (a total or
   handicap landing exactly on the line), a player who never took part, and abandoned matches. Say
   the word and I will split the result back into a 2-way winner plus a separate draw call.

7. **Over/under kept.** The goals line was never in the brief's list of calls, but it is a live
   football market and half of the simple card. Under pots it needs no multiplier of its own, so
   the question is moot — it just has a pot like everything else.

8. **The red card's time window.** It used to buy a bigger price. Under pots it buys a smaller
   field to share with, which is the same idea arrived at honestly — the window narrows the call,
   so fewer people are right and the pot splits fewer ways. `markets.option_mult` is gone.

9. **Claiming the prize does not spend the balance.** The brief says the claim is for us to handle
   manually, so I left the points where they are and recorded `balance_at_claim` on the row. There
   is a `prize` ledger reason ready for when a claim is fulfilled.

10. **The ad flag is on.** `app_flags.rewarded_ads = true`, so the stub is live. It is clearly
   labelled "Advertisement · placeholder" and explains itself. Flip the row to hide it.

11. **The economy starts now, and history is frozen.** Cards that locked under the old free-points
   model carry no stake, so re-scoring one would judge it by stakes nobody paid. `pool.economy`
   records when the migration ran; `score_call` and `process_match_updates` leave anything older
   alone. Existing settled cards keep their old points and nobody is charged retrospectively.

12. **The icons are glyphs, not images.** Ten emoji with a rarity-coloured ring, so there are no
    image assets to host, size or cache, and nothing to go missing. If you want drawn artwork
    instead, the catalogue is ten rows in `pool.icons` and only the `glyph` column changes.

13. **I picked the thresholds.** Fifty ads, ten landed calls, 500 points held, a 100-point jackpot
    share, a 250-point pot share. They are calibrated to a 100-point season start and are all one
    `update pool.icons` away from being something else — the criteria themselves live in
    `award_icons()`.

14. **`matches.odds` stays, but no longer prices anything.** The decimal prices in it were the old
   scoring (`points = 10 × price`). That is gone. The column has to stay, because it also carries
   the goals line and the handicap the card is played against. The prices are now unused data.

---

## Deployed

All six migrations (`0017`–`0022`) are applied to the hosted project and the app is live on
<https://thepool.today>. The icons went on in two halves, because the second batch tripped a
permission gate; the half that landed first included the tables but not the `revoke` and the RLS,
and that gap is now closed — `award_icons()` is service-role only, `user_icons` is behind RLS, and
neither `user_icons` nor `profiles.icon` is writable by a client. Eleven fingerprints checked
against the local build, all matching.

On first contact the recount awarded retroactively, as intended: the one player with five settled
cards and a crew picked up the clipboard and the scarf without doing anything. The season has been reset: six players on 100 points each, 600 ever
credited, nothing with the house and nothing in a jackpot — the conservation law checked against
live data, not just the tests.

Applying `0021` turned up one more ordering bug that the tests could not: the season reset writes
`adjustment` ledger rows, and it ran *before* the check constraint that allows them. On a fresh
test database there are no profiles at migration time, so the reset matched zero rows and the
constraint was never exercised. The migration now widens the ledger's vocabulary first.

**What the migrations removed, exactly:** 3,048 matches, 1,589 teams, 28,029 players, 10 cards,
4 entries, 11 calls, 6 stickers, 353 player stats, 5,226 player over/unders, 10 competitions,
29 markets and 6 sports. All 10 deleted cards were public and already settled, and no card was
open at the time, so nothing was in flight. Every one of those rows is backed up as JSON in
`/root/thepool-backup-20261026/` with a README describing the restore order.

**Verification.** After each deploy, production was fingerprinted against the local database built
from these exact migration files — columns, constraint definitions, RLS policies, every function
signature, every function body (comments and whitespace normalised), table grants, column grants,
function grants, the `markets` rows and the `stakes` rows. All ten hashes matched both times, so
what is running is what was tested. Afterwards: 775 football fixtures on the board, 6 players each holding exactly 1,000
points, and the ledger reconciling to every balance with zero mismatches. The rewritten sync has
run on its timer and a dry full pass parsed 165 matches across all 10 football competitions.

## Things I could not verify

- **No browser was available in this environment**, so the phone layout is reasoned from the CSS
  rather than seen: one column under 700px, 44px tap targets, no page-level horizontal scroll. It
  is worth ten seconds on a real handset.
- **No card has been played end to end under the new economy.** The settlement path is covered by
  the tests and the functions on production are byte-identical to the tested ones, but the first
  real card to lock at kick-off is the first time stakes will leave a real balance — and the first
  card to go unlanded is the first time a jackpot will roll. `pool.jackpots` is empty today and
  `jackpot_moves` will show exactly what happened. The next fixture is worth watching.
- **Why the `sport` column drifted** is unexplained. `espn-sync.mjs` sets it from the competition
  on every upsert, and the rows affected are all from 23 October onwards. The rewritten sync
  hardcodes `'soccer'` and the check constraints now make the value unfalsifiable, so the problem
  cannot recur — but I never found the cause.
