-- The point economy (0019): balances, stakes, payouts, refunds, the ledger, rewarded ads, the prize.
-- Run on a fresh db after the migrations:  psql pool -f tests/economy_test.sql
-- Every check raises on failure; a clean run prints "ECONOMY TESTS PASSED".
\set ON_ERROR_STOP on
begin;
set search_path = pool, public;

insert into auth.users (id, email) values
  ('11111111-aaaa-0000-0000-000000000001', 'ana@example.com'),
  ('22222222-bbbb-0000-0000-000000000002', 'ben@example.com'),
  ('33333333-cccc-0000-0000-000000000003', 'cem@example.com');
update profiles set display_name = initcap(split_part(email, '@', 1));

create or replace function test_as(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true), set_config('role', 'authenticated', true);
$$;
create or replace function test_reset() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', true), set_config('role', 'postgres', true);
$$;
create or replace function bal(u text) returns int language sql stable as $$
  select balance from profiles where id = u::uuid $$;
create or replace function ledger_sum(u text) returns int language sql stable as $$
  select coalesce(sum(amount), 0)::int from ledger where user_id = u::uuid $$;
create or replace function play(p_user text, p_match int, p_calls jsonb) returns uuid
language plpgsql as $$
declare card uuid;
begin
  perform test_as(p_user);
  card := rpc_open_card(p_match, 'complex', null);
  perform rpc_save_calls(card, p_calls);
  perform test_reset();
  return card;
end $$;
create or replace function rejects(p_user text, p_match int, p_calls jsonb, p_like text) returns boolean
language plpgsql as $$
begin
  perform play(p_user, p_match, p_calls);
  return false;
exception when others then
  perform test_reset();
  if sqlerrm not like p_like then raise exception 'expected "%", got "%"', p_like, sqlerrm; end if;
  return true;
end $$;
create or replace function res(p_user text, p_match int, p_ct call_type) returns call_result language sql stable as $$
  select k.result from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
  where c.match_id = p_match and e.user_id = p_user::uuid and k.call_type = p_ct $$;
create or replace function pts(p_user text, p_match int) returns int language sql stable as $$
  select e.points from entries e join cards c on c.id = e.card_id
  where c.match_id = p_match and e.user_id = p_user::uuid $$;
create or replace function kickoff(p_match int) returns void language sql as $$
  update matches set utc_date = now() - interval '1 minute' where id = p_match;
  select sync_card_status();
$$;
create or replace function finish(p_match int, h int, a int) returns void language sql as $$
  update matches set status = 'FINISHED', utc_date = now() - interval '3 hours', home_score = h, away_score = a,
         ft_home = h, ft_away = a, duration = 'REGULAR', provider_updated = now() where id = p_match;
  select process_match_updates();
$$;

\set A '11111111-aaaa-0000-0000-000000000001'
\set B '22222222-bbbb-0000-0000-000000000002'
\set C '33333333-cccc-0000-0000-000000000003'

insert into teams (id, name, sport) values (9001, 'Rovers', 'soccer'), (9002, 'Athletic', 'soccer');
insert into players (id, team_id, name, sport) values
  (90011, 9001, 'Okafor', 'soccer'), (90012, 9001, 'Pires', 'soccer'), (90021, 9002, 'Lindqvist', 'soccer');
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, total_line, odds) values
  (9000, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, 3,
     '{"total":{"line":3,"over":1.9,"under":1.9},"spread":{"home_line":-1.5,"home":1.9,"away":1.9}}'),
  (9100, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, null, '{}'),
  (9200, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, null, '{}'),
  (9300, 'PL', 'soccer', '2026', now() + interval '3 hours', 'TIMED', 9001, 9002, null, '{}');

-- --- 1. everyone starts with 1,000 points, and the ledger says where they came from ------------
do $$ begin
  assert bal('11111111-aaaa-0000-0000-000000000001') = 1000, 'Ana starts on 1,000';
  assert bal('22222222-bbbb-0000-0000-000000000002') = 1000, 'Ben starts on 1,000';
  assert (select count(*) from ledger where reason = 'signup') = 3, 'one signup row each';
  assert ledger_sum('11111111-aaaa-0000-0000-000000000001') = 1000, 'the ledger is the balance';
  assert (select array_agg(amount order by amount) from stakes) = array[10, 25, 50, 100, 200], 'the five stakes';
end $$;

-- --- 2. the multipliers the design asks for ----------------------------------------------------
do $$ begin
  assert (select multiplier from markets where call_type = 'winner') = 1.5, 'result 1.5';
  assert (select (pick_multiplier->>'draw')::numeric from markets where call_type = 'winner') = 3, 'the draw 3';
  assert (select multiplier from markets where call_type = 'spread') = 2, 'handicap 2';
  assert (select multiplier from markets where call_type = 'score')  = 8, 'exact scoreline 8';
  assert (select multiplier from markets where call_type = 'scorer') = 4, 'goalscorer 4';
  assert (select multiplier from markets where call_type = 'assist') = 6, 'assist 6';
  assert (select multiplier from markets where call_type = 'yellow') = 3, 'yellow 3';
  assert (select multiplier from markets where call_type = 'red')    = 10, 'red 10';
end $$;

-- --- 3. a stake is one of five, and it is locked onto the call when it is saved -----------------
do $$ begin
  assert rejects('11111111-aaaa-0000-0000-000000000001', 9100,
    '[{"call_type":"winner","team_id":9001,"stake":30}]', '%10, 25, 50, 100 or 200%'), 'an invented stake';
  assert rejects('11111111-aaaa-0000-0000-000000000001', 9100,
    '[{"call_type":"winner","team_id":9001,"stake":500}]', '%10, 25, 50, 100 or 200%'), 'above the top stake';
end $$;

-- Ana's card: the result at 100, the scoreline at 25, over the goals line at 50, a scorer at 10.
select play(:'A', 9000, '[
  {"call_type":"winner","team_id":9001,"stake":100},
  {"call_type":"score","home_goals":2,"away_goals":1,"stake":25},
  {"call_type":"total","yes":true,"stake":50},
  {"call_type":"scorer","player_id":90012,"stake":10}
]') as ana_card \gset
do $$ begin
  assert (select count(*) from calls where stake not in (10, 25, 50, 100, 200)) = 0, 'every stake is legal';
  assert (select multiplier from calls where call_type = 'winner') = 1.5, 'the result at 1.5';
  assert (select multiplier from calls where call_type = 'score')  = 8, 'the scoreline at 8';
  -- nothing has moved yet: the stake leaves the balance at kick-off, not at save
  assert bal('11111111-aaaa-0000-0000-000000000001') = 1000, 'saving costs nothing';
  assert (select count(*) from ledger where reason = 'stake') = 0, 'no stake rows before kick-off';
  assert committed_stake('11111111-aaaa-0000-0000-000000000001') = 185, 'but 185 is promised';
end $$;

-- --- 4. you cannot promise more than you hold --------------------------------------------------
do $$ begin
  -- Ana has 1,000 and 185 promised; four more calls at 200 would be 800, over the 815 left… just.
  assert rejects('11111111-aaaa-0000-0000-000000000001', 9100,
    '[{"call_type":"winner","team_id":9001,"stake":200},{"call_type":"score","home_goals":1,"away_goals":0,"stake":200},
      {"call_type":"scorer","player_id":90011,"stake":200},{"call_type":"assist","player_id":90012,"stake":200},
      {"call_type":"yellow","player_id":90021,"stake":200}]',
    '%Not enough points%'), 'over the balance across open cards';
  -- and within the limit it goes through
  perform play('11111111-aaaa-0000-0000-000000000001', 9100, '[{"call_type":"winner","team_id":9001,"stake":200}]');
  assert committed_stake('11111111-aaaa-0000-0000-000000000001') = 385, 'both open cards count';
end $$;

-- --- 5. the stake is deducted when the card locks at kick-off ----------------------------------
select kickoff(9000);
do $$ begin
  assert (select status from cards where match_id = 9000) = 'locked', 'the card locked';
  assert bal('11111111-aaaa-0000-0000-000000000001') = 1000 - 185, format('185 left the balance: %s', bal('11111111-aaaa-0000-0000-000000000001'));
  assert (select count(*) from ledger where reason = 'stake') = 4, 'one stake row per call';
  assert (select sum(amount) from ledger where reason = 'stake') = -185, 'and they sum to the card';
  assert (select bool_and(staked) from calls k join entries e on e.id = k.entry_id where e.card_id = (select id from cards where match_id = 9000)), 'every call is staked';
  assert ledger_sum('11111111-aaaa-0000-0000-000000000001') = bal('11111111-aaaa-0000-0000-000000000001'), 'the ledger still is the balance';
  -- the promise on the locked card is spent, the one on the open card is not
  assert committed_stake('11111111-aaaa-0000-0000-000000000001') = 200, 'only the open card is still promised';
end $$;

-- --- 6. settlement: a hit pays stake × multiplier, a miss loses it, a push gives it back --------
-- Rovers 2–1: the result lands, the scoreline lands, three goals is exactly the line (a push),
-- and Pires did not score although he played.
insert into player_stats values (9000, 90011, 'app', 1), (9000, 90012, 'app', 1), (9000, 90021, 'app', 1);
insert into match_events (match_id, type, minute, team_id, player_id, provider_key) values
  (9000, 'goal', 20, 9001, 90011, 'g1'), (9000, 'goal', 55, 9001, 90011, 'g2'), (9000, 'goal', 70, 9002, 90021, 'g3');
select finish(9000, 2, 1);
do $$ declare b int := bal('11111111-aaaa-0000-0000-000000000001'); begin
  assert res('11111111-aaaa-0000-0000-000000000001', 9000, 'winner') = 'hit',  'the result landed';
  assert res('11111111-aaaa-0000-0000-000000000001', 9000, 'score')  = 'hit',  'the scoreline landed';
  assert res('11111111-aaaa-0000-0000-000000000001', 9000, 'total')  = 'void', 'three goals on a line of 3 is a push';
  assert res('11111111-aaaa-0000-0000-000000000001', 9000, 'scorer') = 'miss', 'Pires did not score';
  -- 100 × 1.5 = 150 won, 25 × 8 = 200 won, 50 refunded, 10 lost
  assert (select points_awarded from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
          where c.match_id = 9000 and k.call_type = 'winner') = 150, 'the result paid 150';
  assert (select points_awarded from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
          where c.match_id = 9000 and k.call_type = 'score') = 200, 'the scoreline paid 200';
  assert (select count(*) from ledger where reason = 'win') = 2, 'two winnings';
  assert (select amount from ledger where reason = 'refund') = 50, 'the push was handed back';
  assert b = 1000 - 185 + 150 + 200 + 50, format('balance after the card: %s', b);
  assert b = 1215, format('balance is 1215, not %s', b);
  assert ledger_sum('11111111-aaaa-0000-0000-000000000001') = b, 'the ledger is the balance';
  -- the card''s own number is the net effect on the balance
  assert pts('11111111-aaaa-0000-0000-000000000001', 9000) = 215, format('the card is worth +215, not %s', pts('11111111-aaaa-0000-0000-000000000001', 9000));
end $$;

-- --- 7. losing: every call wrong takes every stake ---------------------------------------------
select kickoff(9100);
do $$ begin assert bal('11111111-aaaa-0000-0000-000000000001') = 1215 - 200, 'the second card''s stake went too'; end $$;
select finish(9100, 0, 2);
do $$ begin
  assert res('11111111-aaaa-0000-0000-000000000001', 9100, 'winner') = 'miss', 'Rovers lost';
  assert bal('11111111-aaaa-0000-0000-000000000001') = 1015, format('a wrong call returns nothing: %s', bal('11111111-aaaa-0000-0000-000000000001'));
  assert pts('11111111-aaaa-0000-0000-000000000001', 9100) = -200, 'the card cost 200';
  assert (select count(*) from ledger where user_id = '11111111-aaaa-0000-0000-000000000001' and reason = 'win' and reference =
          (select k.id::text from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id where c.match_id = 9100)) = 0,
         'nothing was credited for it';
end $$;

-- --- 8. void: a player who never came on gets the stake back -----------------------------------
select play(:'B', 9200, '[{"call_type":"scorer","player_id":90012,"stake":100},{"call_type":"winner","team_id":9001,"stake":50}]');
select kickoff(9200);
do $$ begin assert bal('22222222-bbbb-0000-0000-000000000002') = 850, 'Ben staked 150'; end $$;
insert into player_stats values (9200, 90011, 'app', 1), (9200, 90021, 'app', 1);   -- Pires was an unused sub
select finish(9200, 1, 0);
do $$ begin
  assert res('22222222-bbbb-0000-0000-000000000002', 9200, 'scorer') = 'void', 'an unused sub voids the call';
  assert res('22222222-bbbb-0000-0000-000000000002', 9200, 'winner') = 'hit', 'Rovers won';
  -- 100 back, and 50 × 1.5 = 75 on the result
  assert bal('22222222-bbbb-0000-0000-000000000002') = 850 + 100 + 75, format('Ben is on %s', bal('22222222-bbbb-0000-0000-000000000002'));
  assert pts('22222222-bbbb-0000-0000-000000000002', 9200) = 25, 'net +25: the void is neither won nor lost';
end $$;

-- --- 9. a provider correction adjusts the balance rather than paying twice ----------------------
do $$ declare before int := bal('22222222-bbbb-0000-0000-000000000002'); begin
  perform process_match_updates(); perform process_match_updates();
  assert bal('22222222-bbbb-0000-0000-000000000002') = before, 'settling again changes nothing';
  -- the goal is withdrawn: Rovers 0–0, so the result misses and the 75 comes back off
  delete from match_events where match_id = 9200;
  update matches set home_score = 0, ft_home = 0, provider_updated = now() + interval '1 second' where id = 9200;
  perform process_match_updates();
  assert res('22222222-bbbb-0000-0000-000000000002', 9200, 'winner') = 'miss', 'no goal, no win';
  assert bal('22222222-bbbb-0000-0000-000000000002') = before - 75, format('the 75 was taken back: %s', bal('22222222-bbbb-0000-0000-000000000002'));
  assert ledger_sum('22222222-bbbb-0000-0000-000000000002') = bal('22222222-bbbb-0000-0000-000000000002'), 'and the ledger agrees';
end $$;

-- --- 10. a match called off before it starts hands the stakes back ------------------------------
select play(:'C', 9300, '[{"call_type":"winner","team_id":9001,"stake":200}]');
select kickoff(9300);
do $$ begin assert bal('33333333-cccc-0000-0000-000000000003') = 800, 'staked at kick-off'; end $$;
update matches set utc_date = now() + interval '2 days', status = 'POSTPONED' where id = 9300;
select sync_card_status();
do $$ begin
  assert (select status from cards where match_id = 9300) = 'open', 'the card reopened';
  assert bal('33333333-cccc-0000-0000-000000000003') = 1000, 'and the stake came back';
  assert (select sum(amount) from ledger where user_id = '33333333-cccc-0000-0000-000000000003' and reason = 'stake') = 0, 'the stake nets to nothing';
end $$;

-- --- 11. the ledger is append-only --------------------------------------------------------------
do $$ begin
  begin update ledger set amount = 99999 where id = (select min(id) from ledger);
    raise exception 'the ledger was rewritten'; exception when others then
    if sqlerrm not like '%append-only%' then raise; end if; end;
  begin delete from ledger where id = (select min(id) from ledger);
    raise exception 'the ledger was erased'; exception when others then
    if sqlerrm not like '%append-only%' then raise; end if; end;
end $$;

-- --- 12. rewarded ads: 100 a time, ten a day, counted by the database ---------------------------
do $$ declare before int := bal('33333333-cccc-0000-0000-000000000003'); r jsonb; begin
  perform test_as('33333333-cccc-0000-0000-000000000003');
  for i in 1..10 loop
    r := rpc_watch_ad();
    assert (r->>'credited')::int = 100, 'each ad is worth 100';
    assert (r->>'watched_today')::int = i, format('ad %s of the day', i);
    assert (r->>'left_today')::int = 10 - i, 'the counter counts down';
  end loop;
  assert bal('33333333-cccc-0000-0000-000000000003') = before + 1000, 'ten ads are 1,000 points';
  begin perform rpc_watch_ad(); raise exception 'an eleventh ad was allowed';
  exception when others then if sqlerrm not like '%all ten%' then raise; end if; end;
  assert bal('33333333-cccc-0000-0000-000000000003') = before + 1000, 'and it credited nothing';
  assert ads_today('33333333-cccc-0000-0000-000000000003') = 10, 'ten watched today';
  perform test_reset();
  -- the cap is in the table, not the function: an eleventh row cannot exist
  begin
    insert into ad_views (user_id, day, seq, reward)
    values ('33333333-cccc-0000-0000-000000000003', (now() at time zone 'utc')::date, 11, 100);
    raise exception 'an eleventh ad view was stored';
  exception when check_violation then null; end;
  -- yesterday is its own day
  insert into ad_views (user_id, day, seq, reward)
  values ('33333333-cccc-0000-0000-000000000003', (now() at time zone 'utc')::date - 1, 1, 100);
  assert ads_today('33333333-cccc-0000-0000-000000000003') = 10, 'yesterday does not count against today';
end $$;

-- --- 13. the ads switch is a feature flag --------------------------------------------------------
do $$ begin
  update app_flags set enabled = false where key = 'rewarded_ads';
  perform test_as('22222222-bbbb-0000-0000-000000000002');
  begin perform rpc_watch_ad(); raise exception 'an ad played with the flag off';
  exception when others then if sqlerrm not like '%switched off%' then raise; end if; end;
  perform test_reset();
  update app_flags set enabled = true where key = 'rewarded_ads';
end $$;

-- --- 14. the prize ------------------------------------------------------------------------------
do $$ declare claim uuid; begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  begin perform rpc_claim_prize(); raise exception 'a PlayStation was claimed on pocket change';
  exception when others then if sqlerrm not like '%1,000,000 points%' then raise; end if; end;
  perform test_reset();

  perform apply_ledger('11111111-aaaa-0000-0000-000000000001', 'ad_reward', 'test-top-up', 1000000);
  assert bal('11111111-aaaa-0000-0000-000000000001') >= 1000000, 'topped up';

  perform test_as('11111111-aaaa-0000-0000-000000000001');
  claim := rpc_claim_prize();
  assert (select prize from prize_claims where id = claim) = 'PlayStation 5', 'a PlayStation 5';
  assert (select status from prize_claims where id = claim) = 'pending', 'waiting on us';
  assert (select balance_at_claim from prize_claims where id = claim) >= 1000000, 'the balance is recorded';
  begin perform rpc_claim_prize(); raise exception 'two claims at once';
  exception when others then if sqlerrm not like '%already with us%' then raise; end if; end;
  assert (select count(*) from prize_claims) = 1, 'one claim';
  perform test_reset();
end $$;

-- --- 15. the table ranks by balance ---------------------------------------------------------------
do $$ begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  assert (select display_name from leaderboard('overall') limit 1) = 'Ana', 'the richest leads';
  assert (select balance from leaderboard('overall') limit 1) = bal('11111111-aaaa-0000-0000-000000000001'), 'and the table shows it';
  assert (my_stats()->>'balance')::int = bal('11111111-aaaa-0000-0000-000000000001'), 'my_stats carries the balance';
  assert (my_stats()->>'ads_left')::int = 10, 'Ana has not watched an ad';
  assert (my_stats()->'prize_claim'->>'status') = 'pending', 'and her claim is in';
  perform test_reset();
end $$;

-- --- 16. nothing but these functions can move a balance -------------------------------------------
do $$ begin
  assert has_table_privilege('authenticated', 'pool.ledger', 'insert') = false, 'the client cannot write the ledger';
  assert has_table_privilege('authenticated', 'pool.ledger', 'update') = false, 'nor rewrite it';
  assert has_column_privilege('authenticated', 'pool.profiles', 'balance', 'update') = false, 'nor set a balance';
  assert has_column_privilege('authenticated', 'pool.profiles', 'balance', 'select') = true, 'but can read one';
  assert has_table_privilege('authenticated', 'pool.ad_views', 'insert') = false, 'nor claim an ad reward directly';
  assert has_table_privilege('authenticated', 'pool.prize_claims', 'insert') = false, 'nor file a claim directly';
  assert has_function_privilege('authenticated', 'pool.apply_ledger(uuid, text, text, int)', 'execute') = false, 'nor call the ledger function';
end $$;

select 'ECONOMY TESTS PASSED' as result;
rollback;
