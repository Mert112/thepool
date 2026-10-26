# Changelog

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

All five migrations (`0017`–`0021`) are applied to the hosted project and the app is live on
<https://thepool.today>. The season has been reset: six players on 100 points each, 600 ever
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
