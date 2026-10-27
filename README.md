# The Pool — thepool.today

A free-to-play **football** prediction game. People call what will happen in a match and stake points on each call; every stake on a call goes into one pot, and at full time the people who were right share it. Everyone starts a season with 100 points and a million claims a PlayStation 5. This repo is the whole product: database, jobs, email, and the web app. How it fits together is in [ARCHITECTURE.md](ARCHITECTURE.md); the migrations are indexed in [MIGRATIONS.md](MIGRATIONS.md).

## Quickstart

```
git clone https://github.com/Mert112/thepool.git && cd thepool
git config core.hooksPath .githooks          # lint on commit
sudo apt install postgresql-17               # any Postgres 17 with a role that can create databases
(cd web && npm ci)                           # the web app's dependencies (the tests use them too)
bash tests/run.sh                            # rebuild a local db from every migration, run every test
cd web && npm run dev                        # http://localhost:5173 against the live project (VITE_SUPABASE_* to change)
npm test && npm run lint && npm run typecheck
bash deploy/deploy.sh                        # on the server: build and publish to /var/www/thepool
```

```
supabase/migrations/   schema, game rules, security, read models, notifications, cron (MIGRATIONS.md)
supabase/functions/    send-notifications (email) · phone-verify (SMS code) · _shared helpers
sync/                  api-football.mjs — fixtures, live details, squads, odds and settlement (runs on the server)
web/src/               pages/ · components/ (shared UI) · features/<board|card|crews|economy|ads|profile>/ · lib/ (supabase, i18n, format, auth)
tests/                 the rules tests on plain Postgres, and the parser and language tests
```

## How it fits together

| Piece | Where | What it does |
|---|---|---|
| Postgres schema | `0001_schema.sql` | competitions, teams, players, matches, match_events, profiles, crews, cards, entries, calls, stickers, crew_posts, notifications |
| Game rules | `0002_game.sql` | `rpc_*` functions (the only write path from the app), card lifecycle, **settlement** (`settle_match`, `resettle_match`, `process_match_updates`), streaks |
| Security | `0003_rls.sql` | row-level security: crew cards are invisible outside the crew; calls are hidden until the card locks |
| Read models | `0004_views.sql` | `v_board`, `leaderboard()`, `crew_score()`, `my_stats()` |
| Notifications | `0005_notifications.sql` | triggers + enqueue functions for the six email types (§7 of the design doc) |
| Cron | `0006_cron.sql` | pg_cron schedules calling the edge functions through pg_net |
| Multi-sport era | `0008`–`0016` | sports, ESPN leagues, per-sport markets, sportsbook pricing — **withdrawn by `0017`** |
| One provider | `0024` | API-Football replaces ESPN: a league catalogue, followed competitions, a request budget the database enforces, and a player call voided where the provider gave no coverage |
| Football only | `0017` | every other sport's data, markets and code paths removed; football's card is all that is left |
| Explainers, history | `0018` | one plain-English line per call; `call_label()`, `my_history()` |
| Point economy | `0019` | `profiles.balance`, the append-only `ledger`, stakes on calls, multipliers, rewarded ads, `prize_claims` |
| The jackpot | `0020` | stakes from 1 point; a call nobody lands rolls its losses forward, less a 10% rake |
| Pari-mutuel | `0021` | the pot pays, not the house: multipliers gone, nothing minted, money in decimals |
| Profile icons | `0022` | ten icons, nine earned; rarity follows difficulty |
| Scheduler | `pg_cron` on Supabase | `lock-cards` every minute, `deadline-reminders` every 5, `weekly-digest` on Fridays. `sync-fixtures` and `sync-live` are **not** scheduled — they are the retired football-data.org functions (see `0006`) |
| Sync | `sync/api-football.mjs` | systemd timer, every minute: the in-play fixtures somebody is playing, twenty to a request, with their events and line-ups; fixtures and squads daily; one results check per match at full time; then settlement. Every request reserved from the database first |
| Mail | `send-notifications` | drains the queue through Resend |

Everything settles on the 90-minute state (events at minute ≤ 90 + stoppage only). "Best on the pitch" exists in the schema but is **disabled**: no feed publishes an official man of the match. Flip `markets.enabled` when a source exists.

## First-time setup (about an hour)

### 1. Supabase project
Everything installs into a dedicated `pool` schema, so the project can be shared with other apps (Byblos lives in `public` in the same project).
1. Note the project ref, the anon/publishable key and the service-role key.
2. Expose the schema to the API: Settings → API → *Exposed schemas* → add `pool` (or run `alter role authenticator set pgrst.db_schemas = 'public, graphql_public, pool'; notify pgrst, 'reload config';`).
3. Apply the migrations in order. Either `supabase link --project-ref <ref> && supabase db push`, or paste each file into the SQL editor. `0006_cron.sql` needs two Vault secrets first:
   ```sql
   select vault.create_secret('https://<ref>.supabase.co', 'project_url');
   select vault.create_secret('<service_role_key>', 'service_role_key');
   ```
4. Auth → Providers → Email: keep **Magic link** on, turn passwords off. Auth → Settings: set *Site URL* to `https://thepool.today`, add `http://localhost:5173` to redirect URLs, and set the **email OTP expiry to 900 seconds** (15 minutes, §5.1).
5. Auth → SMTP: enable custom SMTP with Resend (`smtp.resend.com`, port 465, user `resend`, password = your Resend API key, sender `The Pool <hello@thepool.today>`). Without this, Supabase's built-in mailer is rate-limited to a handful of links per hour.

### 2. Secrets for the edge functions
```
supabase secrets set RESEND_API_KEY=<resend key>
supabase secrets set SITE_URL=https://thepool.today
supabase secrets set MAIL_FROM="The Pool <hello@thepool.today>"
```
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.

### 3. Deploy the functions
```
supabase functions deploy send-notifications --no-verify-jwt
supabase functions deploy phone-verify
```
`send-notifications` rejects any call not carrying the service-role key, so `--no-verify-jwt` is safe; `phone-verify` takes the player's own token. Fixtures come from `sync/api-football.mjs` on the server (below), not from a function.

### 4. Resend
Add the domain `thepool.today` in Resend and create the DNS records it gives you (DKIM + SPF, and a DMARC TXT) in GoDaddy. Sending from an unverified domain lands in spam.

### 5. Web app
```
cd web
cp .env.example .env      # fill VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
npm install
npm run dev               # http://localhost:5173
```
Deploy to Vercel (import the repo, root directory `web`, framework Vite, add the two env vars). `vercel.json` and `public/_redirects` handle SPA routing on Vercel and Netlify/Cloudflare respectively.

### 6. Hosting on your own server (Ubuntu/Debian)
```
git clone <repo> && cd thepool
bash deploy/setup-server.sh     # once: installs Node + Caddy, copies deploy/Caddyfile
bash deploy/deploy.sh           # every release: builds web/ and publishes to /var/www/thepool
```
Caddy serves `thepool.today` and `www.thepool.today` with automatic HTTPS; ports 80 and 443 must be open. (Vercel works too: import the repo, root `web`, framework Vite.)

### 7. DNS (GoDaddy)
- `thepool.today` → A record to the server's IP; `www` → CNAME to `thepool.today`.
- Resend's DKIM/SPF/DMARC records from step 4.

## The card

| Card | Calls |
|---|---|
| Simple | the result (home / draw / away), over or under the goals line |
| Complex | adds the handicap, the exact scoreline, a goalscorer, an assist, a yellow and a red |

The red card takes an optional 15-minute window, which narrows the call — fewer people will be right, so the pot splits fewer ways. Rules: calls that cannot all land are refused (no hedging); a player who never took part is void; a total or handicap landing exactly on the line is a push and is void; the result is 3-way, so a draw beats both sides.

## Points are a currency, and the pot is all there is to win

Everyone starts a season with **100 points**. Every call carries a stake the player picks — **any
whole number of points**, up to what is free (balance less other open cards) and up to **half of
what the others already have in that call's pot, plus 10** (0027), so nobody can swamp a pot late.
1, 5, 10, 25 and 50 are quick buttons; a stake already saved is never pushed out by the cap. The stake leaves the balance when the card **locks at kick-off**, not when it
is saved. Every stake on a call type goes into **one pot for that card**.

At full time, per pot:

1. a **void** is refunded in full and leaves the pot entirely — no rake is taken on it
2. the house takes a **10% rake** of what remains, recorded in the ledger
3. the other 90%, plus any **jackpot** carried in, is split among the correct calls **in proportion
   to what they staked**, rounded down to the penny
4. what rounding leaves behind goes into the jackpot, never to the house and never invented
5. if **nobody** was correct, the whole 90% rolls into the competition's jackpot

So a pick is worth more the fewer people are on it, and being alone in a pot and right still costs
you the rake. Before lock, each option shows what one point on it would return at the split as it
stands, and each call shows the pot and any jackpot riding on it.

**Nothing is minted.** A balance can rise exactly four ways: the 100-point season start, a **0.5**
point ad credit, a share of a pot, and a share of a jackpot. Everything else is players' money
moving between players, or the rake leaving for the house. Money is `numeric(14,2)` throughout,
because half a point is a real amount.

**The jackpot (`0020`).** Held per competition per call type. The next card in that competition
shows `Jackpot: +N points` on the call while it is open. A card's part in the jackpot is **decided
once**, the first time it settles final, and recorded in `jackpot_moves` — zero movements included,
because a jackpot is a sequence across cards in time and a card re-judged later could otherwise
scoop a pot a *later* card had rolled in.

**The ledger.** `pool.ledger` (`user_id`, signed `amount`, `reason`, `reference`) is append-only: a
trigger refuses every update and delete, no role holds a write grant on it or on `profiles.balance`,
and only `SECURITY DEFINER` functions move money. The house's rake is a ledger row with no user.
`apply_ledger()` is idempotent per `(reason, reference)`, so a provider correction adjusts rather
than paying twice. An entry's own number is read back out of the ledger, so a card's total can never
disagree with the balance it moved.

The conservation law — `balances + house + jackpots + stakes still riding = everything ever
credited` — is asserted after every scenario in `tests/economy_test.sql` and `tests/jackpot_test.sql`.

**Getting points.** A "Get points" button plays a 25-second rewarded-video placeholder worth **0.2
points**, up to **ten a day**. The cap is structural: `ad_views` is keyed on `(user_id, day, seq)`
with `check (seq between 1 and 10)`. `app_flags.rewarded_ads` switches it off.

**The prize.** A balance of 1,000,000 can claim a PlayStation 5: `rpc_claim_prize()` writes a row to
`prize_claims` for us to handle by hand.

## Profile icons (`0022`)

Ten icons, one worn at a time. Everyone starts with the football; the other nine are earned, and
the rarer the icon the harder the thing:

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

Every criterion is a question asked of data the game already keeps — settled entries, landed calls,
ad views, ledger rows, prize claims — so nothing is tracked separately and an icon can never be
awarded for something that did not happen. `award_icons()` runs at the moments one can be earned
(settlement, an ad, a crew, a prize claim) and the profile page recounts on load; running it twice
awards nothing twice. The client cannot insert into `user_icons`, call `award_icons()` or write
`profiles.icon` — only `rpc_set_icon()`, which refuses an icon you have not unlocked.

**Leaderboards** rank by balance overall, and by what was won in scope for a crew, a week or a
competition. In a zero-sum game the player who never played can lead, which is the honest answer.

## Three languages (`0023`)

English, Turkish and Bulgarian. Every user-facing string lives in `web/src/i18n/{en,tr,bg}.ts`;
`en.ts` is the source and the other two are typed against it, so a missing or renamed key fails
`npm run build` rather than shipping a blank. Call it through `useI18n()`:

```tsx
const { t, fmt, lang, setLang } = useI18n();
<b>{t.board.upcoming}</b>                      // checked at build time, not looked up by string
<span>{t.board.playing(r.playing)}</span>      // a string that needs a number is a function
<span>{fmt.when(m.utc_date)}</span>            // Intl, in the chosen locale
```

- **Default**: the browser's language if it is one of the three, else English
  (`web/src/i18n/detect.js`, tested by `tests/lang_test.mjs`).
- **Saved**: `profiles.language`, null until chosen, set only through `rpc_set_language()`. The
  mail follows it, and reads its times in `Europe/London`, `Europe/Istanbul` or `Europe/Sofia`.
- **Not translated**: team, player, competition and crew names, which are the provider's or the
  players' own words.
- **Calls**: `call_parts()` hands a call over as pieces (type, team, player, line, scoreline,
  window) rather than as an English sentence, so the crowd split and the history read in the
  player's language. `call_label()` still returns the English alongside it.
- **Adding a language**: add the code to `LANGS` in `detect.js` and the `language` check in the
  migration, write the dictionary against `Dict`, add one to `supabase/functions/_shared/i18n.ts`
  for the mail, and the compiler will name anything you missed.

## API-Football sync (`0024`)
```
cp sync/.env.example sync/.env    # SUPABASE_URL, SUPABASE_SERVICE_KEY, FOOTBALL_API_KEY
bash deploy/setup-sync.sh         # installs the thepool-sync systemd timer
journalctl -u thepool-sync -f     # one line per pass
node sync/api-football.mjs --dry  # fetch and parse without writing
node sync/api-football.mjs --catalogue --fixtures --squads   # force the daily passes
```
One provider: [API-Football](https://www.api-football.com) v3, on the Pro plan. The key lives in
`FOOTBALL_API_KEY` in `sync/.env` (gitignored, `chmod 600`) and nowhere else — not in the
database, not in the bundle.

**The request budget is the database's.** The plan allows 7,500 calls a day; `config.football_api`
sets the ceiling at 7,000 and `api_usage` counts a row per UTC day, by endpoint. The sync calls
`api_take(n, kind)` *before* it spends, and a pass that cannot afford a call does not make it. A
counter inside the script would reset every time systemd restarted it.

**What a pass costs.** An idle minute costs nothing at all:

| Pass | When | Requests |
|---|---|---|
| League catalogue | weekly | 1 (~1,250 leagues) |
| Fixtures | daily, −2 to +8 days | 1 per followed competition |
| Squads | daily | 1 per team with a fixture on the board |
| Odds | once per fixture, retried after 6h | 1 per fixture |
| **Live** | **every minute** | **1 per 20 in-play fixtures with a card on them** |
| Results | once, after the whistle | 1 per 20 fixtures |

The live pass is cheap because `/fixtures?ids=a-b-c` returns up to twenty full fixture details —
score, events and line-ups — in one response. A match nobody is playing never gets a live pass,
only a single results check at full time.

**Competitions.** All ~1,250 leagues and cups are in `competitions` with their country and type;
only the ones somebody follows are `active`, and only active ones cost requests. A new account
follows the Süper Lig, 1. Lig, Türkiye Kupası, Bulgarian First League, the Champions, Europa and
Conference Leagues, the Premier League, La Liga, Serie A, Bundesliga and Ligue 1 — plus Türkiye's
and Bulgaria's national-team matches, which are the World Cup and Euro qualifiers, the Nations
League and the two finals, filtered to those two sides by `competitions.team_filter`. Everything
else is under **More leagues** on the board and in settings. `tier` is set by hand for the
competitions we follow: the provider does not publish it.

**The 90-minute rule, unchanged.** `score.fulltime` is the score at 90 and is what every call
settles on; `goals` includes extra time and is kept for the screen only. An event's `elapsed`
over 90 does not count (`match_events.counts` is a generated column), and a card shown before
kick-off arrives as a negative minute and is recorded as minute 0.

**A call nobody can judge is void.** `matches.detail_at` records when the provider last handed
over a fixture's events and line-ups, stamped by the writes themselves. Null at full time means
the goalscorer, assist, card and man-of-the-match calls are **voided and the stakes handed
back** — not scored as misses. Everything settled before `0024` keeps the verdict it was given.

**Mapping off ESPN.** Nothing was re-keyed. `teams.af_id`, `players.af_id` and
`matches.af_fixture_id` were added beside the old columns, and the sync claims an existing row by
name within its competition (accents, case and club-type noise ignored) before creating a new
one. 67 matches and 87 teams were claimed on the first pass; the 713 settled matches that predate
the window keep their ESPN keys and their history.

## Ads (`0025`)

Two kinds, both behind consent.

**Rewarded** — Google Ad Manager's rewarded slot, through the Publisher Tag. GPT's
`rewardedSlotGranted` event carries no token, so the nonce is ours: `rpc_ad_nonce()` mints a
single-use one after checking the flag and the daily cap, the page
plays the ad, and `rpc_watch_ad(nonce)` credits 0.2 points once. A replayed or borrowed nonce
credits nothing. No fill, no consent or no tag means **"No ad available right now"** and no
credit. There is no wait between ads (0026): the next can start the moment one finishes.

**Fraud scoring** (0026) replaced the sixty-second spacing. Every credit stores the device
fingerprint the page sends and the IP and user-agent from the gateway's headers.
`ad_fraud_scores()` flags an account that shares a fingerprint or an IP with 3+ other accounts,
or whose credits average under 20 seconds apart on a day (thresholds in `config.ad_fraud`).
Flagged accounts still play and earn; their prize claims carry a warning in
`pool.admin_prize_claims`, and `pool.admin_ad_fraud` lists every scored account. Both are
readable only from the dashboard / service role.

**Phone before the first claim** (0026). With `app_flags.phone_verification` on, `rpc_claim_prize()`
refuses until the account has a row in `phone_verifications` (one number per account, one
account per number). The `phone-verify` edge function sends and checks an SMS code through
Twilio Verify. To switch it on:
```
supabase secrets set TWILIO_ACCOUNT_SID=… TWILIO_AUTH_TOKEN=… TWILIO_VERIFY_SERVICE_SID=…
update pool.app_flags set enabled = true where key = 'phone_verification';
```

To go live, fill in the ad unit and switch the flag:
```sql
update pool.config set value = value || jsonb_build_object(
  'network_code', '<code>', 'ad_unit_path', '/<code>/<unit>') where key = 'ads';
update pool.app_flags set enabled = true where key = 'gam_rewarded';
```
Until then the twenty-five-second stub plays, which is also how to test. With the real slot on, the
stub refuses to pay.

**AdSense** — the tag is in `web/index.html` as Google issued it, neutralised with
`type="text/plain"` so it cannot run before consent, and `web/public/ads.txt` is served at
`/ads.txt`. `src/lib/consent.ts` turns the tag into a live script on accept, and `gpt.js` is
fetched on demand the same way. Rejecting leaves both unloaded.

**Consent** lives in `localStorage` under `pool.consent`, is asked once in a bar at the foot of
the page, and can be changed at any time on `/privacy`. Essential storage — session, language,
this answer — is outside it.

## Running the rules test locally
Needs a plain Postgres 17 and a role that can create databases:
```
bash tests/run.sh      # rebuilds the db from every migration, then runs the tests
```
`tests/game_test.sql` walks a full card: crew creation, RLS, filling, lock at kickoff, progressive live settlement at 1–1, a 90+3 goal and 90+5 red that count, an extra-time goal that does not, stickers, receipts, streaks, a provider correction, leaderboards and deadline reminders.
`tests/football_test.sql` covers the rest of the card: the 3-way result, the goals line, the handicap, pushes, the red card's time window, non-runners and withdrawn cards.
`tests/jackpot_test.sql` covers the rollover: the rake, the compounding, a void never feeding the pot, one competition's jackpot staying out of another's, a single winner taking it all, several winners splitting it by stake with the remainder carried, and settling twice moving nothing.
`tests/ads_test.sql` covers the rewarded ad: the nonce rules (replayed, borrowed, invented, expired, in-flight past the cap), back-to-back ads with no wait, ten a day, the flag, that the stub cannot pay while the real slot is live, what each credit records, the three fraud flags and the admin warning, and the phone gate (once, one number per account, codes rationed).
`tests/follows_test.mjs` covers "My leagues" in the browser: a follow or unfollow shows in the one shared list before the server answers, the server agrees, a refused follow is rolled back, and signing out forgets the list.
`tests/provider_test.sql` covers the provider: the request budget and what happens when it runs out, the league catalogue, following and unfollowing, which fixtures are worth a request, odds asked for once rather than once a minute, and the void-on-no-coverage rule.
`tests/provider_test.mjs` runs the parsers against responses API-Football actually sent (`tests/fixtures/api-football.json`): the 90-minute rule, extra time, every status code, events, line-ups, odds and the name matching.
`tests/i18n_test.sql` covers the language: the null default, the three-way check, `rpc_set_language()` setting only your own, the pieces a call travels as, that no English prose leaks into them, and the grants.
`tests/lang_test.mjs` covers the default-language rule in the browser (`node --test`).
`tests/economy_test.sql` covers the money: the starting 1,000, a stake deducted at lock, a payout on a hit, a loss on a miss, a refund on a void, the balance handed back when a match is called off, a correction adjusting rather than double-paying, the ten-a-day ad cap, the prize claim, and the grants that stop a client touching any of it.

## Not in v1 (by design)
Real money, sports other than football, native apps, push/WhatsApp, chat beyond the crew feed, sticker trading, social login, public profiles. Points are play money: they are never bought, sold or cashed out, and the only thing they buy is the prize.
