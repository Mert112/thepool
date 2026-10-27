# Migrations

`supabase/migrations/` is the schema's history, applied in order. **A migration is never edited once
applied** — a change is a new file. `bash tests/run.sh` rebuilds a local database from all of them
(skipping `0006`, which needs the hosted pg_cron) and runs every test. Each file's header comment
says what it does and why; this is the index.

| File | What it does | Superseded by |
|---|---|---|
| `0001_schema` | Core tables: competitions, teams, players, matches, profiles, crews, cards, entries, calls, stickers | |
| `0002_game` | Card lifecycle, settlement (`settle_match`, `process_match_updates`), streaks, stickers | rules: `0011`, `0014`, `0019`–`0021` |
| `0003_rls` | Row-level security, and the default grants that make every later revoke necessary | |
| `0004_views` | Read models for the screens (`v_board` and friends), run as the caller | `v_board`: `0017` |
| `0005_notifications` | The email queue and the triggers that fill it | |
| `0006_cron` | pg_cron jobs: lock cards, deadline reminders, weekly digest (three of six live) | |
| `0007_function_search_path` | Pinned `search_path` on helper functions | |
| `0008`–`0016` | Multi-sport and sportsbook markets, squads, the red-card window | withdrawn by `0017` |
| `0017_football_only` | Football is the whole game; `v_board` as it stands | |
| `0018_explainers_and_history` | What each call means; prediction history | |
| `0019_point_economy` | Points as a currency: the append-only `ledger`, stakes, ads, prize claims | payouts: `0021` |
| `0020_jackpot_rollover` | A pot nobody lands rolls into the competition's jackpot | |
| `0021_pari_mutuel` | The pot pays, not the house: 10% rake, the rest split by stake | |
| `0022_profile_icons` | Ten icons and the achievements behind them | |
| `0023_languages` | English, Turkish, Bulgarian; calls travel as parts, not prose | |
| `0024_api_football` | One provider (API-Football), request budget, league catalogue, follows | |
| `0025_rewarded_ads` | Rewarded ads with a single-use nonce and a ten-a-day cap | spacing: `0026` |
| `0026_ad_fraud_scoring` | Fraud scoring instead of ad spacing; admin views; phone before the first claim | |
| `0027_free_stakes` | Any whole-number stake, capped at half the pot plus 10 | cap: `0028` |
| `0028_stake_what_you_hold` | No pot cap: stake any whole number you have free; the handicap switched off | |
