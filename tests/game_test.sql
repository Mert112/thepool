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
  assert (select count(*) from profiles where balance = 1000) = 3, 'everyone starts on 1,000';
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
  {"call_type":"winner","team_id":57,"stake":50},
  {"call_type":"score","home_goals":2,"away_goals":1,"stake":25},
  {"call_type":"scorer","player_id":2,"stake":100},
  {"call_type":"assist","player_id":3,"stake":50},
  {"call_type":"yellow","player_id":7,"stake":25},
  {"call_type":"red","player_id":8,"stake":10}
]') as mina_entry \gset
insert into t_ids values ('mina_entry', :'mina_entry');
do $$ begin
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111') = 1000, 'saving a card costs nothing yet';
  assert my_committed_stake() = 260, 'but 260 is promised to it';
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
select rpc_save_calls(:'card2_id', '[{"call_type":"scorer","player_id":5,"stake":25}]');
do $$ begin
  assert my_committed_stake() = 285, 'both open cards count against the balance';
  begin
    perform rpc_save_calls(tv('card2_id')::uuid, '[{"call_type":"scorer","player_id":5,"stake":200},
      {"call_type":"assist","player_id":5,"stake":200},{"call_type":"yellow","player_id":5,"stake":200},
      {"call_type":"red","player_id":5,"stake":200}]');
    raise exception 'a card was staked past the balance';
  exception when others then if sqlerrm not like '%Not enough points%' then raise; end if; end;
  assert my_committed_stake() = 285, 'and the refused card changed nothing';
end $$;
select test_reset();

-- --- Tobias fills the same card: the draw at 3×, and two player calls --------------
select test_as('22222222-2222-2222-2222-222222222222');
select rpc_save_calls(:'card_id', '[
  {"call_type":"winner","pick":"draw","stake":100},
  {"call_type":"scorer","player_id":5,"stake":50},
  {"call_type":"yellow","player_id":7,"stake":25}
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
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111') = 1000 - 260, 'Mina staked 260';
  assert (select balance from profiles where id = '22222222-2222-2222-2222-222222222222') = 1000 - 175, 'Tobias staked 175';
  assert (select coalesce(sum(amount), 0) from ledger where reason = 'stake') = -435, 'the ledger holds both';
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
  -- scorer 100 × 4, assist 50 × 6, yellow 25 × 3, less the 260 staked
  assert (select points from entries where id = e) = 400 + 300 + 75 - 260, format('live net %s', (select points from entries where id = e));
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
  -- Mina: result 50×1.5 + scoreline 25×8 + scorer 100×4 + assist 50×6 + yellow 25×3 + red 10×10 = 1150 back on 260 staked
  assert (select points from entries where id = e) = 1150 - 260, format('Mina points %s', (select points from entries where id = e));
  assert (select hits from entries where id = e) = 6, 'Mina 6 of 6';
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111') = 1000 - 260 + 1150, 'Mina is paid';
  -- Tobias: the draw loses its 100, Salah pays 50×4, the yellow 25×3 — 275 back on 175 staked
  assert (select points from entries where id = t) = 275 - 175, format('Tobias points %s', (select points from entries where id = t));
  assert (select result from calls where entry_id = t and call_type = 'winner') = 'miss', 'a wrong call is a wrong call';
  assert (select points_awarded from calls where entry_id = t and call_type = 'winner') = 0, 'and returns nothing';
  assert (select balance from profiles where id = '22222222-2222-2222-2222-222222222222') = 1000 - 175 + 275, 'Tobias is paid';
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
select rpc_save_calls(:'card2_id', '[{"call_type":"scorer","player_id":5,"stake":25},{"call_type":"winner","team_id":64,"stake":50}]') ;
select test_reset();
update matches set utc_date = now() - interval '3 hours' where id = 1001;
update matches set status = 'FINISHED', home_score = 0, away_score = 0, ft_home = 0, ft_away = 0, provider_updated = now() where id = 1001;
select process_match_updates();
do $$ begin
  assert (select result from calls c join entries e on e.id = c.entry_id where e.card_id = tv('card2_id')::uuid and call_type = 'winner') = 'miss', 'a side loses to a draw';
  assert (select points from entries where card_id = tv('card2_id')::uuid) = -75, 'a blank card costs what it staked';
  -- streak: same matchday, Mina landed on the other card that day → still 1
  assert (select streak from profiles where id = '11111111-1111-1111-1111-111111111111') = 1, 'streak survives';
end $$;

-- --- provider correction: the assist on the first goal is re-credited to Rice (4) ---------
update match_events set assist_player_id = 4 where provider_key = 'g1';
update matches set provider_updated = now() + interval '1 second' where id = 1000;
select process_match_updates();
do $$ declare e uuid := tv('mina_entry')::uuid; begin
  assert (select result from calls where entry_id = e and call_type = 'assist') = 'miss', 'correction: assist now missed';
  assert (select points from entries where id = e) = 1150 - 300 - 260, format('corrected points %s', (select points from entries where id = e));
  -- the 300 is taken back off the balance, not paid again
  assert (select balance from profiles where id = '11111111-1111-1111-1111-111111111111') = 1000 - 260 + 1150 - 75 - 300, 'the correction adjusts the balance';
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
  -- the overall table is a rich list now
  assert (select display_name from leaderboard('overall') limit 1) = 'Mina', 'the richest leads';
  assert (select balance from leaderboard('overall') limit 1) = 1515, 'and the table shows the balance';
  assert (select points from leaderboard('overall') limit 1) = 890 - 300 - 75, 'with what the settled cards were worth';
  assert (select display_name from leaderboard('crew', tv('crew_id')) limit 1) = 'Mina', 'crew table';
  assert (my_stats()->>'rank')::int = 1, 'my rank';
  assert (my_stats()->>'balance')::int = 1515, 'my balance';
  assert crew_score(tv('crew_id')::uuid) = 590 + 100 - 75, format('crew score %s', crew_score(tv('crew_id')::uuid));
  perform test_reset();
end $$;

-- --- deadline reminders -------------------------------------------------------------
insert into matches (id, competition_code, season, utc_date, status, home_team_id, away_team_id)
  values (1002, 'PL', '2026', now() + interval '55 minutes', 'TIMED', 57, 64);
select test_as('11111111-1111-1111-1111-111111111111');
select rpc_open_card(1002, 'complex', :'crew_id') as card3 \gset
insert into t_ids values ('card3', :'card3');
select rpc_save_calls(:'card3', '[{"call_type":"winner","team_id":57,"stake":10}]');
select test_reset();
do $$ begin
  assert (select count(*) from notifications where type = 'new_card') = 1, 'new-card mail to Tobias only';
  assert enqueue_deadline_reminders() = 2, 'reminders: Mina (incomplete) + Tobias (absent)';
  assert enqueue_deadline_reminders() = 0, 'reminders deduped';
end $$;

select 'ALL TESTS PASSED' as result;
rollback;
