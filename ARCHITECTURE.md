# Architecture

The Pool is a Postgres database with a thin web app on top. **The database is the game**: every
rule, every point and every permission lives in `supabase/migrations/`. The app reads views and
calls `rpc_*` functions; it never writes a table directly and never decides what anything is worth.

```
 API-Football ──► sync/api-football.mjs ──► matches · match_events · player_stats
 (provider)       (server, every minute,         │
                   thepool-sync.timer)            ▼
                                       process_match_updates()  ◄── pg_cron lock-cards (every minute)
                                         settle_match → settle_pot      sync_card_status → take_stakes
                                                 │                               │
                                                 ▼                               ▼
                                         apply_ledger(user, reason, ref, target)  ──►  ledger (append-only)
                                                                                        │
                                                                                        ▼
                                                                               profiles.balance
                                                                                        │
 Browser (web/, React) ◄── views / RPCs over PostgREST, row-level security ◄──────────┘
        │  rpc_save_calls · rpc_watch_ad · rpc_claim_prize · rpc_follow_competition …
        └─► edge functions: phone-verify (Twilio)      notifications queue ──► send-notifications (Resend)
```

## How data flows: provider → settlement → ledger

1. **Fixtures in.** `sync/api-football.mjs` runs every minute on the server. It asks the database
   how many requests it may spend (`api_take`), fetches only the leagues somebody follows, and
   upserts matches, events, line-ups and odds.
2. **Lock at kick-off.** pg_cron's `lock-cards` runs `sync_card_status()`: a card whose match has
   started locks, and `take_stakes` moves each call's stake out of the balance (`ledger` reason
   `stake`).
3. **Settle.** At the end of each sync pass, `process_match_updates()` re-judges every changed match
   (`settle_match`): each call becomes hit, miss or void, and each call type's pot on a card is
   settled by `settle_pot` — voids refunded, 10% raked, the rest split by stake among the hits, or
   rolled into the competition's jackpot if nobody hit.
4. **Ledger.** Every movement is `apply_ledger(user, reason, reference, target)`, which writes only
   the difference between what the ledger already holds for that key and the target. Settling
   twice — or re-settling after a correction — moves nothing extra. The balance is the ledger's sum.
5. **Mail.** Settlement and other triggers queue rows in `notifications`; the sync host then wakes
   `send-notifications`, which sends them through Resend in the player's language.

## Invariants

- **Nothing is minted.** Points enter only at the season start and from rewarded ads; every point
  won was staked by someone. `tests/economy_test.sql` asserts the conservation law after every step.
- **The ledger is append-only** (a trigger refuses update and delete) and **idempotent** (keyed by
  user, reason and reference).
- **The client decides nothing.** Stakes, caps, ad credits, nonces and claims are checked in the
  database; the page only mirrors the rules so a refusal is rare.
- **Every new table and function is revoked from `anon` and `authenticated`** before anything is
  granted — `0003` grants by default. The tests assert it.
- **A migration is never edited** once applied (see `MIGRATIONS.md`).
- **Everything the player reads is in their language**; the database raises in English and the app
  translates known messages (`translateError`).

## Where each concern lives

| Concern | Database | Web app | Tests |
|---|---|---|---|
| Board, leagues, following | `0017` (`v_board`), `0024` | `features/board/`, `pages/Board.tsx`, `pages/Settings.tsx` | `provider_test.sql`, `features/board/follows.test.mjs` |
| Cards and calls | `0002`, `0011`, `0021`, `0027` | `features/card/`, `pages/FillCard.tsx`, `pages/LiveCard.tsx`, `pages/Match.tsx` | `game_test.sql`, `football_test.sql` |
| Points, pots, prize | `0019`–`0021`, `0026`, `0027` | `features/economy/`, `pages/Profile.tsx`, `pages/Table.tsx` | `economy_test.sql`, `jackpot_test.sql`, `features/economy/stakes.test.mjs` |
| Ads and fraud scoring | `0025`, `0026` | `features/ads/` | `ads_test.sql`, `features/ads/AdModal.test.mjs` |
| Crews | `0002`, `0005` | `features/crews/`, `pages/Crews.tsx`, `pages/CrewRoom.tsx` | `game_test.sql` |
| Profile, icons, settings | `0022`, `0023` | `features/profile/`, `pages/Profile.tsx`, `pages/Settings.tsx` | `icons_test.sql`, `i18n_test.sql` |
| Languages | `0023` | `lib/i18n/` | `i18n_test.sql`, `tests/lang_test.mjs` |
| Provider sync | `0024` | — (`sync/api-football.mjs`) | `provider_test.sql`, `tests/provider_test.mjs` |
| Mail | `0005`, `0006` | — (`supabase/functions/send-notifications`) | |

In the web app, a page reads top to bottom as **fetch → show → act**: `useLoad(() => featureApi())`
at the top, JSX in the middle, handlers that call an `rpc_*` and reload. Each `features/<x>/api.ts`
is the only place that names that feature's tables and functions, and every query goes through
`must()` in `lib/supabase.ts`, which returns the data or throws the database's message.
