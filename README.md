# The Pool — thepool.today

A free-to-play football prediction game. People call what will happen in a match, score points for being right, and argue about it with the same crew every week. This repo is the whole product: database, jobs, email, and the web app.

```
supabase/migrations/   schema, game rules, security, read models, notifications, cron
supabase/functions/    sync-fixtures · sync-live · send-notifications (Deno edge functions)
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
| Fixtures | `sync-fixtures` | twice an hour: competitions, next two weeks of matches, squads (football-data.org, ~5 calls/run) |
| Live | `sync-live` | every minute while something is on: scores, goals, bookings → progressive settlement |
| Mail | `send-notifications` | drains the queue through Resend |

Scoring follows the design doc exactly: winner 1 · draw 3 · scoreline 8 · goalscorer 7 · assist 9 · yellow 6 · red 10. Everything settles on the 90-minute state (events at minute ≤ 90 + stoppage only). One boost per matchday doubles one call, no downside. "Best on the pitch" (8) exists in the schema but is **disabled** for v1 because football-data.org does not publish an official man of the match; flip `markets.enabled` when a source exists.

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

## Provider notes (football-data.org)
- Free tier: 10 requests/minute, 12 competitions (exactly the ones in the design doc), match detail includes goals (with assists) and bookings. The live sync is 1 list call + up to 4 detail calls per minute and sits out the two minutes an hour the fixtures sync uses.
- 90-minute rule: `score.regularTime` is used when a match goes to extra time; goals/bookings carry `minute` and `injuryTime`, and only `minute <= 90` counts.
- Corrections after settlement (a re-credited assist, a withdrawn goal) re-run settlement automatically; affected players get a "correction" email.
- If the free tier turns out to omit bookings or assists on your key, the event calls will simply never land; check one finished match's JSON at `/v4/matches/{id}` before launch.

## Running the rules test locally
Needs a plain Postgres 16:
```
createdb pool
psql pool -f tests/local_auth_stub.sql          # stand-in for Supabase's auth schema
for f in supabase/migrations/000[1-5]*.sql supabase/migrations/0007*.sql; do psql -v ON_ERROR_STOP=1 pool -f $f; done
psql pool -f tests/game_test.sql                 # prints ALL TESTS PASSED
```
The test walks a full card: crew creation, RLS, filling, the boost rule, lock at kickoff, progressive live settlement at 1–1, a 90+3 goal and 90+5 red that count, an extra-time goal that does not, a void winner on a 0–0, stickers, receipts, streaks, a provider correction, leaderboards and deadline reminders.

## Not in v1 (by design)
Real money, odds, native apps, push/WhatsApp, chat beyond the crew feed, sticker trading, social login, public profiles.

## Open decisions carried over from the design doc
- Whether the boost should carry downside (currently pure upside, FPL-chip style).
- "Best on the pitch" needs a data source; until then a simple card is two calls (winner + draw).
