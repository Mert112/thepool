# The Pool — thepool.today

A free-to-play **football** prediction game. People call what will happen in a match and stake points on it; a call that lands returns the stake multiplied, a call that misses costs it. Everyone starts with 1,000 points and a million claims a PlayStation 5. This repo is the whole product: database, jobs, email, and the web app.

The board carried seven sports for a while; `0017_football_only.sql` withdrew all of them. Football is the whole game.

```
supabase/migrations/   schema, game rules, security, read models, notifications, cron
supabase/functions/    send-notifications (Deno edge function); sync-fixtures · sync-live are the retired football-data.org sync
sync/                  espn-sync.mjs — fixtures, live scores, goals/cards and squads (runs on the server)
web/                   React + Vite app (Vercel / Cloudflare Pages / Netlify)
tests/                 end-to-end rules test that runs on plain Postgres
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
| Football only | `0017` | every other sport's data, markets and code paths removed; football's card is all that is left |
| Explainers, history | `0018` | one plain-English line per call; `call_label()`, `my_history()` |
| Point economy | `0019` | `profiles.balance`, the append-only `ledger`, stakes on calls, multipliers, rewarded ads, `prize_claims` |
| Sync | `sync/espn-sync.mjs` | systemd timer, every minute: fixtures a week out (every 30 min), live scoreboards, goals and cards for matches being played, squads for the board, then settlement |
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
supabase secrets set FOOTBALL_DATA_KEY=<football-data.org token>
supabase secrets set RESEND_API_KEY=<resend key>
supabase secrets set SITE_URL=https://thepool.today
supabase secrets set MAIL_FROM="The Pool <hello@thepool.today>"
```
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.

### 3. Deploy the functions
```
supabase functions deploy sync-fixtures --no-verify-jwt
supabase functions deploy sync-live --no-verify-jwt
supabase functions deploy send-notifications --no-verify-jwt
```
They reject any call that is not carrying the service-role key, so `--no-verify-jwt` is safe. Run `sync-fixtures` once by hand from the dashboard to fill the board; squads arrive over the following day (2 teams per run, twice an hour, free-tier pacing).

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

The red card takes an optional 15-minute window for a far bigger multiplier. Rules: calls that cannot all land are refused (no hedging); a player who never took part is void; a total or handicap landing exactly on the line is a push and is void; the result is 3-way, so a draw beats both sides.

## Points are a currency (§4, `0019`)

Everyone starts with **1,000 points**. Every call carries a stake the player picks — **10, 25, 50, 100 or 200** — and the stake leaves the balance when the card **locks at kick-off**, not when it is saved. At settlement a call that lands returns `stake × multiplier`, a call that misses returns nothing, and a void call hands the stake back.

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
| A red card | 10×, or 35×–120× with a 15-minute window |

A card cannot stake more than the player holds, counting what other open cards have already promised; the check is in `rpc_save_calls`. If a balance somehow falls short by kick-off the entry is not staked at all and its calls settle void.

**The ledger.** Every movement is one row in `pool.ledger` (`user_id`, signed `amount`, `reason`, `reference`), written only by `SECURITY DEFINER` functions; a trigger refuses any update or delete, and no role has a write grant on it or on `profiles.balance`. `apply_ledger()` is idempotent per `(reason, reference)` — it writes the difference between what a reason has already paid and what it should have — so a provider correction adjusts a balance instead of paying twice. The running sum of a player's rows is always their balance; the tests assert it.

**Getting points.** A "Get points" button plays a 30-second rewarded-video placeholder worth **100 points**, up to **ten a day**. The cap is structural: `ad_views` is keyed on `(user_id, day, seq)` with `check (seq between 1 and 10)`, so an eleventh row cannot exist and two racing calls cannot take the same slot. `app_flags.rewarded_ads` switches the whole thing off. Swap the panel in `AdModal` for a real provider's player; nothing else moves.

**The prize.** A balance of 1,000,000 can claim a PlayStation 5: `rpc_claim_prize()` writes a row to `prize_claims` for us to handle by hand. The profile page shows the progress bar and the claim button. Claiming does not spend the balance — we settle that when we fulfil it.

**Leaderboards** rank by balance overall, and by what was won in scope for a crew, a week or a competition.

## ESPN sync
```
cp sync/.env.example sync/.env    # SUPABASE_URL and a secret key (Supabase → Settings → API keys)
bash deploy/setup-sync.sh         # installs the thepool-sync systemd timer
journalctl -u thepool-sync -f     # one line per pass
node sync/espn-sync.mjs --dry     # fetch and parse without writing
```
ESPN's `site.api.espn.com` feeds are public but unofficial: no key, no contract, and they can change without notice. The sync is polite (about 150 small requests every 30 minutes, a handful per minute otherwise). Football scoreboards only accept single-day `dates=` queries. Competitions are rows in `pool.competitions` (`espn_path`, optional `espn_params`) — add a league by inserting one.

## Provider notes (football-data.org, retired)
- Free tier: 10 requests/minute, 12 competitions (exactly the ones in the design doc), match detail includes goals (with assists) and bookings. The live sync is 1 list call + up to 4 detail calls per minute and sits out the two minutes an hour the fixtures sync uses.
- 90-minute rule: `score.regularTime` is used when a match goes to extra time; goals/bookings carry `minute` and `injuryTime`, and only `minute <= 90` counts.
- Corrections after settlement (a re-credited assist, a withdrawn goal) re-run settlement automatically; affected players get a "correction" email.
- If the free tier turns out to omit bookings or assists on your key, the event calls will simply never land; check one finished match's JSON at `/v4/matches/{id}` before launch.

## Running the rules test locally
Needs a plain Postgres 17 and a role that can create databases:
```
bash tests/run.sh      # rebuilds the db from every migration, then runs the tests
```
`tests/game_test.sql` walks a full card: crew creation, RLS, filling, lock at kickoff, progressive live settlement at 1–1, a 90+3 goal and 90+5 red that count, an extra-time goal that does not, stickers, receipts, streaks, a provider correction, leaderboards and deadline reminders.
`tests/football_test.sql` covers the rest of the card: the 3-way result, the goals line, the handicap, pushes, the red card's time window, non-runners and withdrawn cards.
`tests/economy_test.sql` covers the money: the starting 1,000, a stake deducted at lock, a payout on a hit, a loss on a miss, a refund on a void, the balance handed back when a match is called off, a correction adjusting rather than double-paying, the ten-a-day ad cap, the prize claim, and the grants that stop a client touching any of it.

## Not in v1 (by design)
Real money, sports other than football, native apps, push/WhatsApp, chat beyond the crew feed, sticker trading, social login, public profiles. Points are play money: they are never bought, sold or cashed out, and the only thing they buy is the prize.
