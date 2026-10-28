-- End-to-end test of the game rules against the design doc. Run on a fresh local db:
--   psql pool -f tests/game_test.sql
-- Every check raises on failure; a clean run prints "ALL TESTS PASSED".
\set ON_ERROR_STOP on
begin;
set search_path = pool, public;

-- --- fixtures -------------------------------------------------------------
insert into teams (id, name, short_name, tla) values (57, 'Arsenal', 'Arsenal', 'ARS'), (64, 'Liverpool', 'Liverpool', 'LIV');
insert into players (id, team_id, name) values
  (1, 57, 'Saka'), (2, 57, 'Havertz'), (3, 57, 'Ødegaard'), (4, 57, 'Rice'),
  (5, 64, 'Salah'), (6, 64, 'Van Dijk'), (7, 64, 'Mac Allister'), (8, 64, 'Konaté');
insert into matches (id, competition_code, season, utc_date, status, home_team_id, away_team_id)
  values (1000, 'PL', '2026', now() + interval '2 hours', 'TIMED', 57, 64);
-- a second match the same day, for the boost rule
insert into matches (id, competition_code, season, utc_date, status, home_team_id, away_team_id)
  values (1001, 'PL', '2026', now() + interval '3 hours', 'TIMED', 64, 57);

-- --- users ---------------------------------------------------------------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'mina@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'tobias@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'celine@example.com');
do $$ begin
  assert (select count(*) from profiles) = 3, 'profile trigger';
  assert (select count(*) from notification_settings) = 3, 'settings trigger';
  assert (select count(*) from profiles where balance = 100) = 3, 'everyone starts on 100';
  assert (select count(*) from ledger where reason = 'signup') = 3, 'and the ledger says where from';
end $$;

-- helper: act as a user
create or replace function test_as(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true), set_config('role', 'authenticated', true);
$$;
create or replace function test_reset() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', true), set_config('role', 'postgres', true);
$$;

create temp table t_ids (k text primary key, v text);
grant all on t_ids to public;
create or replace function tv(k text) returns text language sql stable security definer as $$ select v from t_ids where k = $1 $$;

-- --- crew + cards ----------------------------------------------------------
select test_as('11111111-1111-1111-1111-111111111111');
select rpc_set_display_name('Mina');
select rpc_create_crew('Desk XI', 'CL nights', 'complex') as crew_id \gset
insert into t_ids values ('crew_id', :'crew_id');
select rpc_open_card(1000, 'complex', :'crew_id') as card_id \gset
insert into t_ids values ('card_id', :'card_id');
select rpc_open_card(1000, 'simple', null) as pub_card_id \gset
insert into t_ids values ('pub_card_id', :'pub_card_id');
select rpc_open_card(1001, 'complex', :'crew_id') as card2_id \gset
insert into t_ids values ('card2_id', :'card2_id');
select test_reset();

do $$ begin
  assert (select count(*) from cards) = 3, 'three cards';
  -- public card opened again returns the same id
  perform test_as('22222222-2222-2222-2222-222222222222');
  assert rpc_open_card(1000, 'complex', null) = (select id from cards where match_id = 1000 and crew_id is null), 'public card is unique';
  perform test_reset();
end $$;

-- Tobias joins the crew by code, Céline does not
select invite_code as code from crews where id = :'crew_id' \gset
select test_as('22222222-2222-2222-2222-222222222222');
select rpc_set_display_name('Tobias');
select rpc_join_crew(:'code');
select test_reset();

do $$ begin
  perform test_as('33333333-3333-3333-3333-333333333333');
  begin
    perform rpc_save_calls(tv('card_id')::uuid, '[]');
    raise exception 'non-member could save on a crew card';
  exception when insufficient_privilege then null; end;
  -- RLS: Céline cannot see the crew card
  assert (select count(*) from cards) = 1, 'non-member sees only the public card';
  perform test_reset();
end $$;

-- crews are readable (no policy recursion), the code only through the helper
do $$ begin
  perform test_as('22222222-2222-2222-2222-222222222222');
  assert (select count(*) from crews) = 1, 'member reads crew';
  assert crew_invite_code(tv('crew_id')::uuid) is not null, 'member gets code';
  assert (select count(*) from card_players(tv('card_id')::uuid)) = 0, 'nobody playing yet';
  perform test_reset();
  perform test_as('33333333-3333-3333-3333-333333333333');
  assert (select count(*) from crews) = 0, 'outsider sees no crew';
  assert crew_invite_code(tv('crew_id')::uuid) is null, 'outsider gets no code';
  perform test_reset();
end $$;

-- --- Mina fills the complex crew card, staking what she believes -------------
select test_as('11111111-1111-1111-1111-111111111111');
select rpc_save_calls(:'card_id', '[
  {"call_type":"winner","team_id":57,"stake":10},
  {"call_type":"score","home_goals":2,"away_goals":1,"stake":5},
  {"call_type":"scorer","player_id":2,"stake":10},
  {"call_type":"assist","player_id":3,"stake":5},
  {"call_type":"yellow","player_id":7,"stake":2},
  {"call_type":"red","player_id":8,"stake":1}
]') as mina_entry \gset
insert into t_ids values ('mina_entry', :'mina_entry');
do $$ begin
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111') = 100, 'saving a card costs nothing yet';
  assert my_committed_stake() = 33, 'but 33 is promised to it';
end $$;

-- validation: simple card rejects complex calls, wrong squad rejected, motm disabled
do $$ declare pub uuid := (select id from cards where match_id = 1000 and crew_id is null);
begin
  begin perform rpc_save_calls(pub, '[{"call_type":"score","home_goals":1,"away_goals":1}]');
    raise exception 'simple card accepted a scoreline'; exception when others then
    if sqlerrm not like '%not on a simple card%' then raise; end if; end;
  begin perform rpc_save_calls(pub, '[{"call_type":"motm","player_id":1}]');
    raise exception 'motm accepted'; exception when others then
    if sqlerrm not like '%not available%' then raise; end if; end;
  begin perform rpc_save_calls(pub, '[{"call_type":"winner","team_id":999}]');
    raise exception 'foreign team accepted'; exception when others then
    if sqlerrm not like '%one of the two teams%' then raise; end if; end;
end $$;

-- a second card the same matchday: both are promised against the one balance
select rpc_save_calls(:'card2_id', '[{"call_type":"scorer","player_id":5,"stake":5}]');
do $$ begin
  assert my_committed_stake() = 38, 'both open cards count against the balance';
end $$;
select test_reset();

-- a thin balance refuses a stake it cannot cover
do $$ declare pub uuid := (select id from cards where match_id = 1000 and crew_id is null);
begin
  perform apply_ledger('33333333-3333-3333-3333-333333333333', 'adjustment', 'test-drain', -98);
  perform test_as('33333333-3333-3333-3333-333333333333');
  assert (select balance from profiles where id = '33333333-3333-3333-3333-333333333333') = 2, 'Celine is down to 2';
  begin
    perform rpc_save_calls(pub, '[{"call_type":"winner","team_id":57,"stake":50}]');
    raise exception 'a card was staked past the balance';
  exception when others then if sqlerrm not like '%at most 2 on one call%' then raise; end if; end;
  perform test_reset();
  perform apply_ledger('33333333-3333-3333-3333-333333333333', 'adjustment', 'test-drain', 0);
  assert (select balance from profiles where id = '33333333-3333-3333-3333-333333333333') = 100, 'and she is restored';
  assert (select count(*) from entries e join cards c on c.id = e.card_id where c.match_id = 1000 and e.user_id = '33333333-3333-3333-3333-333333333333') = 0, 'the refused card left nothing behind';
end $$;
select test_as('11111111-1111-1111-1111-111111111111');
select test_reset();

-- --- Tobias fills the same card: the draw at 3×, and two player calls --------------
select test_as('22222222-2222-2222-2222-222222222222');
select rpc_save_calls(:'card_id', '[
  {"call_type":"winner","pick":"draw","stake":10},
  {"call_type":"scorer","player_id":5,"stake":5},
  {"call_type":"yellow","player_id":7,"stake":2}
]');
-- before lock Tobias cannot see Mina's calls, nor her entry row, but can see she is playing
do $$ begin
  assert (select count(*) from calls) = 3, 'only own calls visible before lock';
  assert (select count(*) from entries) = 1, 'only own entry visible before lock';
  assert (select count(*) from card_players(tv('card_id')::uuid)) = 2, 'both listed as playing';
end $$;
select test_reset();

-- crowd split is aggregate-only and visible
do $$ begin
  perform test_as('22222222-2222-2222-2222-222222222222');
  assert (select n from card_crowd(tv('card_id')::uuid) where call_type = 'yellow') = 2, 'crowd: both picked Mac Allister';
  perform test_reset();
end $$;

-- --- kickoff: lock, and the stakes leave the balances ----------------------------
update matches set utc_date = now() - interval '1 minute' where id = 1000;
select sync_card_status();
do $$ begin
  assert (select status from cards where id = tv('card_id')::uuid) = 'locked', 'locked at kickoff';
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111') = 100 - 33, 'Mina staked 33';
  assert (select balance from profiles where id = '22222222-2222-2222-2222-222222222222') = 100 - 17, 'Tobias staked 17';
  assert (select coalesce(sum(amount), 0) from ledger where reason = 'stake') = -50, 'the ledger holds both';
  perform test_as('11111111-1111-1111-1111-111111111111');
  begin perform rpc_save_calls(tv('card_id')::uuid, '[]'); raise exception 'edit after lock';
  exception when others then if sqlerrm not like '%locked%' then raise; end if; end;
  perform test_reset();
  perform test_as('22222222-2222-2222-2222-222222222222');
  assert (select count(*) from calls) = 9, 'everyone''s calls visible after lock';
  assert (select count(*) from entries) = 2, 'everyone''s entries visible after lock';
  perform test_reset();
end $$;

-- --- live: 1–1 at 67', Havertz scored (assist Ødegaard), Mac Allister booked ------------
update matches set status = 'IN_PLAY', minute = 67, home_score = 1, away_score = 1, provider_updated = now() where id = 1000;
insert into match_events (match_id, type, minute, team_id, player_id, assist_player_id, provider_key) values
  (1000, 'goal', 12, 57, 2, 3, 'g1'),
  (1000, 'yellow', 34, 64, 7, null, 'b1'),
  (1000, 'goal', 58, 64, 5, 6, 'g2');
select process_match_updates();
do $$ declare e uuid := tv('mina_entry')::uuid; begin
  assert (select status from cards where id = tv('card_id')::uuid) = 'live', 'card live';
  assert (select result from calls where entry_id = e and call_type = 'scorer') = 'hit', 'live: scorer lands';
  assert (select result from calls where entry_id = e and call_type = 'assist') = 'hit', 'live: assist lands';
  assert (select result from calls where entry_id = e and call_type = 'yellow') = 'hit', 'live: yellow lands';
  assert (select result from calls where entry_id = e and call_type = 'red') = 'pending', 'live: red still open';
  -- §3 progressive settlement: result calls stay open at 1–1 in the 67th minute
  assert (select result from calls where entry_id = e and call_type = 'winner') = 'pending', 'live: winner open';
  assert (select result from calls where entry_id = e and call_type = 'score') = 'pending', 'live: score open';
  -- a pot cannot pay until it closes: three calls have landed, but the card is still 33 out
  assert (select points from entries where id = e) = -33, format('live net %s', (select points from entries where id = e));
end $$;

-- --- full time 2–1: Saka 90+3 (counts), Konaté red 90+5 (counts), ET goal ignored --------------
insert into match_events (match_id, type, minute, injury_time, team_id, player_id, assist_player_id, provider_key) values
  (1000, 'goal', 90, 3, 57, 1, 4, 'g3'),
  (1000, 'red', 90, 5, 64, 8, null, 'r1'),
  (1000, 'goal', 105, null, 64, 5, 7, 'g_et');   -- would only happen in a cup tie; must not count
update matches set status = 'FINISHED', minute = null, home_score = 2, away_score = 1, ft_home = 2, ft_away = 1,
       duration = 'REGULAR', provider_updated = now() where id = 1000;
select process_match_updates();

do $$ declare e uuid := tv('mina_entry')::uuid; t uuid; begin
  select id into t from entries where card_id = tv('card_id')::uuid and user_id = '22222222-2222-2222-2222-222222222222';
  assert (select status from cards where id = tv('card_id')::uuid) = 'settled', 'card settled';
  -- six pots, each paid out in full (0031). The result 20 to Mina alone; the scoreline 5; the
  -- scorer 15 split 10:5; the assist 5; the yellow 4 split evenly as 2 each; the red 1.
  -- Mina takes 43 on 33 staked.
  assert (select points from entries where id = e) = 10, format('Mina points %s', (select points from entries where id = e));
  assert (select hits from entries where id = e) = 6, 'Mina 6 of 6';
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111') = 100 - 33 + 43, 'Mina is paid';
  assert (select points_awarded from calls where entry_id = e and call_type = 'scorer') = 10, 'the scorer pot split 10:5';
  -- Tobias: the draw loses its 10, and he shares the scorer and yellow pots — 7 back on 17
  assert (select points from entries where id = t) = -10, format('Tobias points %s', (select points from entries where id = t));
  assert (select result from calls where entry_id = t and call_type = 'winner') = 'miss', 'a wrong call is a wrong call';
  assert (select points_awarded from calls where entry_id = t and call_type = 'winner') = 0, 'and returns nothing';
  assert (select points_awarded from calls where entry_id = t and call_type = 'scorer') = 5, 'but he had a third of the scorer pot';
  assert (select balance from profiles where id = '22222222-2222-2222-2222-222222222222') = 100 - 17 + 7, 'Tobias is paid';
  -- somebody landed every call on this card, so nothing rolled forward; the house takes nothing
  assert (select coalesce(sum(amount), 0) from jackpots) = 0, 'no jackpot from a card where everything landed';
  assert (select coalesce(sum(amount), 0) from ledger where reason = 'house') = 0, 'the house took nothing from six pots';
  -- ET goal did not count against anything
  assert (select count(*) from match_events where match_id = 1000 and not counts) = 1, 'ET event excluded';
  -- stickers: one per (competition, season, call type)
  assert (select count(*) from stickers where user_id = '11111111-1111-1111-1111-111111111111') = 6, 'Mina 6 stickers';
  assert (select count(*) from stickers where user_id = '22222222-2222-2222-2222-222222222222') = 2, 'Tobias 2 stickers';
  -- receipts in the crew feed
  assert (select count(*) from crew_posts where call_id is not null) = 8, 'receipts posted';
  -- result mail queued for both
  assert (select count(*) from notifications where type = 'result') = 2, 'result mail queued';
  -- streaks
  assert (select streak from profiles where id = '11111111-1111-1111-1111-111111111111') = 1, 'streak 1';
  assert (select settlement_version from matches where id = 1000) = 1, 'settlement v1';
end $$;

-- --- the result is 3-way: a draw beats a side ------------------------------------------
-- settle match 1001 as 0–0: Tobias has no entry; Mina's scorer call misses, and we add a winner call for a third user
select test_as('11111111-1111-1111-1111-111111111111');
select rpc_save_calls(:'card2_id', '[{"call_type":"scorer","player_id":5,"stake":5},{"call_type":"winner","team_id":64,"stake":10}]');
select test_reset();
update matches set utc_date = now() - interval '3 hours' where id = 1001;
-- the provider's fixture detail: line-ups but no events, which is what a goalless, cardless game
-- looks like. It is the line-ups that make the goalscorer call judgeable — without them `0024`
-- voids it instead of scoring it a miss.
insert into player_stats values (1001, 5, 'app', 1), (1001, 1, 'app', 1);
update matches set status = 'FINISHED', home_score = 0, away_score = 0, ft_home = 0, ft_away = 0, provider_updated = now() where id = 1001;
select process_match_updates();
do $$ begin
  assert (select result from calls c join entries e on e.id = c.entry_id where e.card_id = tv('card2_id')::uuid and call_type = 'winner') = 'miss', 'a side loses to a draw';
  assert (select points from entries where card_id = tv('card2_id')::uuid) = -15, 'a blank card costs what it staked';
  -- and a blank card is exactly what feeds the jackpot: the 10 and 5 lost, whole
  assert jackpot_of('PL', 'winner') = 10, format('the result jackpot is 10, not %s', jackpot_of('PL', 'winner'));
  assert jackpot_of('PL', 'scorer') = 5, format('the scorer jackpot is 5, not %s', jackpot_of('PL', 'scorer'));
  -- streak: same matchday, Mina landed on the other card that day → still 1
  assert (select streak from profiles where id = '11111111-1111-1111-1111-111111111111') = 1, 'streak survives';
end $$;

-- --- provider correction: the assist on the first goal is re-credited to Rice (4) ---------
update match_events set assist_player_id = 4 where provider_key = 'g1';
update matches set provider_updated = now() + interval '1 second' where id = 1000;
select process_match_updates();
do $$ declare e uuid := tv('mina_entry')::uuid; begin
  assert (select result from calls where entry_id = e and call_type = 'assist') = 'miss', 'correction: assist now missed';
  -- the pot was divided and paid when the card settled, and a pot is not un-divided: the share
  -- stays with Mina and the card's number stays where the balance did (0021)
  assert (select points from entries where id = e) = 10, format('corrected points %s', (select points from entries where id = e));
  assert (select points_awarded from calls where entry_id = e and call_type = 'assist') = 5, 'the share she was paid stands';
  assert (select hits from entries where id = e) = 5, 'but it no longer counts as a hit';
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111') = 100 - 33 + 43 - 15, 'the balance is untouched by the correction';
  assert jackpot_of('PL', 'assist') = 0, format('the assist pot is not re-decided, got %s', jackpot_of('PL', 'assist'));
  assert jackpot_of('PL', 'winner') = 10, 'and the standing jackpots are untouched by it';
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111')
       = (select sum(amount) from ledger where user_id = '11111111-1111-1111-1111-111111111111'), 'the ledger is the balance';
  assert (select status from cards where id = tv('card_id')::uuid) = 'settled', 'disputed → settled';
  assert (select settlement_version from matches where id = 1000) = 2, 'settlement v2';
  assert (select count(*) from notifications where type = 'correction') = 1, 'correction mail queued';
  assert (select payload->>'card_id' from notifications where type = 'correction') is not null, 'correction carries card';
  perform process_match_updates(); perform process_match_updates();
  assert (select settlement_version from matches where id = 1000) = 2, 'a correction settles exactly once';
end $$;

-- --- extra time status counts as in play ---------------------------------------------
insert into matches (id, competition_code, season, utc_date, status, home_team_id, away_team_id)
  values (1003, 'CL', '2026', now() - interval '2 hours', 'EXTRA_TIME', 57, 64);
insert into cards (match_id, mode) values (1003, 'simple');
select process_match_updates();
do $$ begin
  assert (select status from cards where match_id = 1003) = 'live', 'extra time keeps the card live';
end $$;

-- --- leaderboard ----------------------------------------------------------------
do $$ begin
  perform test_as('11111111-1111-1111-1111-111111111111');
  -- the overall table is a rich list, and in a zero-sum game the person who never played is top:
  -- Mina won five of her six calls and is still down, because her second card was blank
  assert (select user_id from leaderboard('overall') limit 1) = '33333333-3333-3333-3333-333333333333', 'the richest never played';
  assert (select balance from leaderboard('overall') limit 1) = 100, 'Celine still holds her whole start';
  assert (select balance from leaderboard('overall') offset 1 limit 1) = 95, 'Mina is second on 95';
  assert (select points from leaderboard('overall') offset 1 limit 1) = 10 - 15, 'with what her settled cards were worth';
  assert (select display_name from leaderboard('crew', tv('crew_id')) limit 1) = 'Mina', 'crew table';
  assert (my_stats()->>'rank')::int = 2, 'my rank';
  assert (my_stats()->>'balance')::numeric = 95, 'my balance';
  assert crew_score(tv('crew_id')::uuid) = 10 - 10 - 15, format('crew score %s', crew_score(tv('crew_id')::uuid));
  perform test_reset();
end $$;

-- --- a card is open to others only once its first bet is in (0029) -------------------
insert into matches (id, competition_code, season, utc_date, status, home_team_id, away_team_id)
  values (1094, 'PL', '2026', now() + interval '3 hours', 'TIMED', 57, 64);
select test_as('11111111-1111-1111-1111-111111111111');
select rpc_open_card(1094, 'complex', null) as card4 \gset
select test_reset();
do $$ declare c uuid := (select id from cards where match_id = 1094); n int; begin
  assert (select opened_at from cards where id = c) is null, 'created, not open';
  assert (select public_card_id from v_board where match_id = 1094) is null, 'not on the board';
  assert match_card_count(1094) = 0, 'and not counted';
  select count(*) into n from notifications where dedupe_key = c::text;
  assert n = 0, 'nobody mailed about an empty card';
  -- a save with no calls does not open it
  perform test_as('11111111-1111-1111-1111-111111111111');
  perform rpc_save_calls(c, '[]');
  perform test_reset();
  assert (select opened_at from cards where id = c) is null, 'an empty save does not open it';
  -- somebody else asking for a card on this match gets the same one, not a second
  perform test_as('22222222-2222-2222-2222-222222222222');
  assert rpc_open_card(1094, 'simple', null) = c, 'one public card per match';
  perform test_reset();
  -- the first bet opens it, and only then is it listed
  perform test_as('11111111-1111-1111-1111-111111111111');
  perform rpc_save_calls(c, '[{"call_type":"winner","team_id":57,"stake":1}]');
  perform test_reset();
  assert (select opened_at from cards where id = c) is not null, 'the first bet opens it';
  assert (select public_card_id from v_board where match_id = 1094) = c, 'and puts it on the board';
  assert match_card_count(1094) = 1, 'counted';
  -- tidy: this card is not part of the reminder count below
  delete from notifications where dedupe_key = c::text;
  delete from calls where entry_id in (select id from entries where card_id = c);
  delete from entries where card_id = c;
end $$;

-- --- deadline reminders -------------------------------------------------------------
insert into matches (id, competition_code, season, utc_date, status, home_team_id, away_team_id)
  values (1002, 'PL', '2026', now() + interval '55 minutes', 'TIMED', 57, 64);
select test_as('11111111-1111-1111-1111-111111111111');
select rpc_open_card(1002, 'complex', :'crew_id') as card3 \gset
insert into t_ids values ('card3', :'card3');
select rpc_save_calls(:'card3', '[{"call_type":"winner","team_id":57,"stake":2}]');
select test_reset();
do $$ begin
  -- the mail goes out when a card opens with its first bet (0029), not when it is created: the two
  -- earlier crew cards were created before Tobias joined, but opened after, so he hears of all three
  assert (select count(*) from notifications where type = 'new_card') = 3, 'a new-card mail per crew card';
  assert (select count(*) from notifications where type = 'new_card' and user_id <> '22222222-2222-2222-2222-222222222222') = 0,
    'all of them to Tobias, none to Mina who opened them';
  assert enqueue_deadline_reminders() = 2, 'reminders: Mina (incomplete) + Tobias (absent)';
  assert enqueue_deadline_reminders() = 0, 'reminders deduped';
end $$;

select 'ALL TESTS PASSED' as result;
rollback;
