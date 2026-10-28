-- The point economy (0019–0021, 0031): balances, stakes, pari-mutuel pots, refunds, the
-- ledger, rewarded ads, the prize — and the conservation law that says nothing is ever minted.
-- Run on a fresh db after the migrations:  psql pool -f tests/economy_test.sql
-- Every check raises on failure; a clean run prints "ECONOMY TESTS PASSED".
\set ON_ERROR_STOP on
begin;
set search_path = pool, public;

insert into auth.users (id, email) values
  ('11111111-aaaa-0000-0000-000000000001', 'ana@example.com'),
  ('22222222-bbbb-0000-0000-000000000002', 'ben@example.com'),
  ('33333333-cccc-0000-0000-000000000003', 'cem@example.com'),
  ('44444444-dddd-0000-0000-000000000004', 'dee@example.com');
update profiles set display_name = initcap(split_part(email, '@', 1));

create or replace function test_as(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true), set_config('role', 'authenticated', true);
$$;
create or replace function test_reset() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', true), set_config('role', 'postgres', true);
$$;
create or replace function bal(u text) returns numeric language sql stable as $$
  select balance from profiles where id = u::uuid $$;
create or replace function ledger_sum(u text) returns numeric language sql stable as $$
  select coalesce(sum(amount), 0) from ledger where user_id = u::uuid $$;
create or replace function house() returns numeric language sql stable as $$
  select coalesce(sum(amount), 0) from ledger where reason = 'house' $$;
create or replace function escrow() returns numeric language sql stable as $$
  select coalesce(sum(amount), 0) from jackpots $$;
-- stakes that have left a balance but whose pot has not been settled yet
create or replace function inflight() returns numeric language sql stable as $$
  select coalesce(sum(c.stake), 0) from calls c join entries e on e.id = c.entry_id
  where c.staked and not exists (
    select 1 from jackpot_moves j where j.card_id = e.card_id and j.call_type = c.call_type) $$;
create or replace function credited() returns numeric language sql stable as $$
  select coalesce(sum(amount), 0) from ledger where reason in ('signup', 'adjustment', 'ad_reward') $$;
create or replace function held() returns numeric language sql stable as $$
  select coalesce(sum(balance), 0) from profiles $$;
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
create or replace function pts(p_user text, p_match int) returns numeric language sql stable as $$
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
-- the books balance: everything ever credited is in a balance, with the house, in a jackpot, or
-- still riding on a pot that has not settled
create or replace function assert_conserved(p_where text) returns void language plpgsql as $$
begin
  assert held() + house() + escrow() + inflight() = credited(),
    format('%s: held %s + house %s + jackpots %s + in flight %s <> credited %s',
           p_where, held(), house(), escrow(), inflight(), credited());
  assert held() + house() <= credited(),
    format('%s: balances and the house exceed what was ever credited', p_where);
end $$;

\set A '11111111-aaaa-0000-0000-000000000001'
\set B '22222222-bbbb-0000-0000-000000000002'
\set C '33333333-cccc-0000-0000-000000000003'
\set D '44444444-dddd-0000-0000-000000000004'

insert into teams (id, name, sport) values (9001, 'Rovers', 'soccer'), (9002, 'Athletic', 'soccer');
insert into players (id, team_id, name, sport) values
  (90011, 9001, 'Okafor', 'soccer'), (90012, 9001, 'Pires', 'soccer'), (90021, 9002, 'Lindqvist', 'soccer');
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, total_line, odds) values
  (9000, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, 3, '{"total":{"line":3,"over":1.9,"under":1.9}}'),
  (9100, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, null, '{}'),
  (9200, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, null, '{}'),
  (9300, 'PL', 'soccer', '2026', now() + interval '3 hours', 'TIMED', 9001, 9002, null, '{}'),
  (9400, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, null, '{}');

-- --- 1. a season starts everyone on 100 -------------------------------------------------------
do $$ begin
  assert bal('11111111-aaaa-0000-0000-000000000001') = 100, 'Ana starts on 100';
  assert (select count(*) from ledger where reason = 'signup') = 4, 'one start each';
  assert ledger_sum('11111111-aaaa-0000-0000-000000000001') = 100, 'the ledger is the balance';
  assert (select array_agg(amount order by sort_order) from stakes) = array[1, 5, 10, 25, 50], 'the five quick stakes (0027)';
  assert credited() = 400, 'four starts of 100';
  perform assert_conserved('a fresh season');
end $$;

-- --- 2. nothing mints any more ----------------------------------------------------------------
do $$ begin
  assert (select count(*) from information_schema.columns
          where table_schema = 'pool' and table_name = 'markets' and column_name = 'multiplier') = 0, 'markets.multiplier is gone';
  assert (select count(*) from information_schema.columns
          where table_schema = 'pool' and table_name = 'calls' and column_name = 'multiplier') = 0, 'calls.multiplier is gone';
  assert to_regprocedure('pool.call_multiplier(pool.markets, text)') is null, 'call_multiplier is gone';
end $$;

-- --- 3. a stake is a whole number within the balance, and nothing moves until kick-off
do $$ begin
  assert rejects('11111111-aaaa-0000-0000-000000000001', 9100,
    '[{"call_type":"winner","team_id":9001,"stake":0}]', '%whole number%'), 'zero is not a stake';
  assert rejects('11111111-aaaa-0000-0000-000000000001', 9100,
    '[{"call_type":"winner","team_id":9001,"stake":2.5}]', '%whole number%'), 'nor a fraction';
  assert rejects('11111111-aaaa-0000-0000-000000000001', 9100,
    '[{"call_type":"winner","team_id":9001,"stake":"7"}]', '%whole number%'), 'nor a string';
  assert rejects('11111111-aaaa-0000-0000-000000000001', 9100,
    '[{"call_type":"winner","team_id":9001,"stake":101}]', '%at most 100%'), 'nor more than the balance';
end $$;

select play(:'A', 9000, '[
  {"call_type":"winner","team_id":9001,"stake":10},
  {"call_type":"score","home_goals":2,"away_goals":1,"stake":5},
  {"call_type":"scorer","player_id":90012,"stake":5}
]');
select play(:'B', 9000, '[
  {"call_type":"winner","team_id":9002,"stake":15},
  {"call_type":"score","home_goals":1,"away_goals":2,"stake":5}
]');
do $$ begin
  assert bal('11111111-aaaa-0000-0000-000000000001') = 100, 'saving a card costs nothing';
  assert committed_stake('11111111-aaaa-0000-0000-000000000001') = 20, 'but 20 is promised';
  perform assert_conserved('cards saved, nothing locked');
end $$;

-- --- 4. the pot and the price of a pick are visible before lock (§4) ---------------------------
do $$ declare card uuid := (select id from cards where match_id = 9000); p record; begin
  select * into p from card_pots(card) where call_type = 'winner' and key = '9001';
  assert p.pot = 25, format('the result pot is 25, not %s', p.pot);
  assert p.pick_stake = 10, 'Rovers carries 10 of it';
  assert p.purse = 25, format('the purse is the whole 25 (0031), not %s', p.purse);
  assert p.per_point = 2.5, format('a point on Rovers returns 2.50, not %s', p.per_point);
  select * into p from card_pots(card) where call_type = 'winner' and key = '9002';
  assert p.per_point = 1.66, format('a point on Athletic returns 1.66, not %s', p.per_point);
end $$;

-- --- 4b. no pot cap (0028): anything up to what you have free, even into an empty pot --------------
do $$ begin
  assert to_regprocedure('pool.stake_cap(uuid, pool.call_type, uuid)') is null, 'the cap is gone';
  perform play('33333333-cccc-0000-0000-000000000003', 9300, '[{"call_type":"winner","team_id":9001,"stake":100}]');
  assert committed_stake('33333333-cccc-0000-0000-000000000003'::uuid) = 100, 'Cem put his whole 100 on an empty pot';
  perform play('33333333-cccc-0000-0000-000000000003', 9300, '[]');   -- and takes it back off
  assert committed_stake('33333333-cccc-0000-0000-000000000003'::uuid) = 0, 'an emptied card promises nothing';
end $$;

-- --- 5. the stake is deducted when the card locks ----------------------------------------------
select kickoff(9000);
do $$ begin
  assert bal('11111111-aaaa-0000-0000-000000000001') = 80, 'Ana staked 20';
  assert bal('22222222-bbbb-0000-0000-000000000002') = 80, 'Ben staked 20';
  assert inflight() = 40, 'and 40 is riding on the pots';
  perform assert_conserved('locked, nothing settled');
end $$;

-- --- 6. the pot pays in full (0031), split by stake, a void refunded in full ----------------------
insert into player_stats values (9000, 90011, 'app', 1), (9000, 90021, 'app', 1);   -- Pires never came on
insert into match_events (match_id, type, minute, team_id, player_id, provider_key) values
  (9000, 'goal', 20, 9001, 90011, 'g1'), (9000, 'goal', 55, 9001, 90011, 'g2'), (9000, 'goal', 70, 9002, 90021, 'g3');
select finish(9000, 2, 1);
do $$ begin
  assert res('11111111-aaaa-0000-0000-000000000001', 9000, 'winner') = 'hit', 'Rovers won it';
  assert res('11111111-aaaa-0000-0000-000000000001', 9000, 'scorer') = 'void', 'Pires never came on';
  -- the result: pot 25, all of it to Ana alone. The scoreline: pot 10, all to Ana. No house cut.
  assert house() = 0, format('the house takes nothing, not %s', house());
  assert (select points_awarded from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
          where c.match_id = 9000 and k.call_type = 'winner' and e.user_id = '11111111-aaaa-0000-0000-000000000001') = 25, 'the result paid 25';
  assert (select points_awarded from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
          where c.match_id = 9000 and k.call_type = 'score' and e.user_id = '11111111-aaaa-0000-0000-000000000001') = 10, 'the scoreline paid 10';
  -- a void is refunded in full and never enters the pot
  assert (select coalesce(sum(amount),0) from ledger where reason = 'refund' and user_id = '11111111-aaaa-0000-0000-000000000001') = 5, 'the void came back whole';
  assert bal('11111111-aaaa-0000-0000-000000000001') = 80 + 25 + 10 + 5, format('Ana is on %s', bal('11111111-aaaa-0000-0000-000000000001'));
  assert bal('22222222-bbbb-0000-0000-000000000002') = 80, 'Ben got nothing back';
  assert pts('11111111-aaaa-0000-0000-000000000001', 9000) = 20, format('Ana''s card is worth %s', pts('11111111-aaaa-0000-0000-000000000001', 9000));
  assert pts('22222222-bbbb-0000-0000-000000000002', 9000) = -20, 'Ben''s card cost him 20';
  assert inflight() = 0, 'nothing is left riding';
  perform assert_conserved('the first card settled');
end $$;

-- --- 7. alone and right gets the stake back whole --------------------------------------------------
select play(:'C', 9100, '[{"call_type":"winner","team_id":9001,"stake":10}]');
select kickoff(9100); select finish(9100, 1, 0);
do $$ begin
  assert res('33333333-cccc-0000-0000-000000000003', 9100, 'winner') = 'hit', 'Cem was right';
  assert bal('33333333-cccc-0000-0000-000000000003') = 100, format('and got all 10 back: %s', bal('33333333-cccc-0000-0000-000000000003'));
  assert pts('33333333-cccc-0000-0000-000000000003', 9100) = 0, 'the only player in a pot breaks even';
  perform assert_conserved('a one-player pot');
end $$;

-- --- 8. nobody correct: the whole pot rolls into the competition's jackpot -------------------------
select play(:'A', 9400, '[{"call_type":"winner","team_id":9002,"stake":5}]');
select play(:'B', 9400, '[{"call_type":"winner","team_id":9002,"stake":5}]');
select kickoff(9400); select finish(9400, 1, 0);
do $$ begin
  assert jackpot_of('PL', 'winner') = 10, format('10 staked, 10 rolled — got %s', jackpot_of('PL', 'winner'));
  perform assert_conserved('a pot nobody won');
end $$;

-- --- 9. you cannot promise more than you hold -----------------------------------------------------
do $$ declare dee text := '44444444-dddd-0000-0000-000000000004'; begin
  perform apply_ledger(dee::uuid, 'adjustment', 'test-drain', -85);
  assert bal(dee) = 15, 'Dee is down to 15';
  perform play(dee, 9200, '[{"call_type":"winner","team_id":9001,"stake":10}]');
  assert rejects(dee, 9300, '[{"call_type":"winner","team_id":9001,"stake":10}]',
    '%at most 5%'), 'one call at 10 is more than the 5 she has free';
  assert rejects(dee, 9300, '[{"call_type":"winner","team_id":9001,"stake":5},{"call_type":"score","home_goals":1,"away_goals":0,"stake":5}]',
    '%Not enough points%'), 'nor can two calls add up past it';
  assert committed_stake(dee::uuid) = 10, 'and the refused card changed nothing';
  perform assert_conserved('a drained player');
end $$;

-- --- 10. a match called off before it starts hands the stakes back ---------------------------------
select play(:'C', 9300, '[{"call_type":"winner","team_id":9001,"stake":5}]');
select kickoff(9300);
do $$ begin assert bal('33333333-cccc-0000-0000-000000000003') = 95, 'staked at kick-off'; end $$;
update matches set utc_date = now() + interval '2 days', status = 'POSTPONED' where id = 9300;
select sync_card_status();
do $$ begin
  assert (select status from cards where match_id = 9300) = 'open', 'the card reopened';
  assert bal('33333333-cccc-0000-0000-000000000003') = 100, 'and the stake came back';
  perform assert_conserved('a postponed match');
end $$;

-- --- 11. the ledger is append-only -----------------------------------------------------------------
do $$ begin
  begin update ledger set amount = 99999 where id = (select min(id) from ledger);
    raise exception 'the ledger was rewritten'; exception when others then
    if sqlerrm not like '%append-only%' then raise; end if; end;
  begin delete from ledger where id = (select min(id) from ledger);
    raise exception 'the ledger was erased'; exception when others then
    if sqlerrm not like '%append-only%' then raise; end if; end;
end $$;

-- --- 12. rewarded ads: half a point a time, ten a day -----------------------------------------------
do $$ declare before numeric := bal('33333333-cccc-0000-0000-000000000003'); r jsonb; begin
  -- the sixty-second spacing is tested on its own in ads_test.sql; here it is only in the way
  update config set value = jsonb_set(value, '{spacing_seconds}', '0') where key = 'ads';
  perform test_as('33333333-cccc-0000-0000-000000000003');
  for i in 1..10 loop
    r := rpc_watch_ad();
    assert (r->>'credited')::numeric = 0.2, 'each ad is worth a fifth of a point';
    assert (r->>'watched_today')::int = i, format('ad %s of the day', i);
  end loop;
  assert bal('33333333-cccc-0000-0000-000000000003') = before + 2, 'ten ads are 2 points';
  begin perform rpc_watch_ad(); raise exception 'an eleventh ad was allowed';
  exception when others then if sqlerrm not like '%all ten%' then raise; end if; end;
  perform test_reset();
  begin
    insert into ad_views (user_id, day, seq, reward)
    values ('33333333-cccc-0000-0000-000000000003', (now() at time zone 'utc')::date, 11, 0.2);
    raise exception 'an eleventh ad view was stored';
  exception when check_violation then null; end;
  perform assert_conserved('after a day of ads');
  update config set value = jsonb_set(value, '{spacing_seconds}', '60') where key = 'ads';
end $$;

-- --- 13. the ads switch is a feature flag -------------------------------------------------------------
do $$ begin
  update app_flags set enabled = false where key = 'rewarded_ads';
  perform test_as('22222222-bbbb-0000-0000-000000000002');
  begin perform rpc_watch_ad(); raise exception 'an ad played with the flag off';
  exception when others then if sqlerrm not like '%switched off%' then raise; end if; end;
  perform test_reset();
  update app_flags set enabled = true where key = 'rewarded_ads';
end $$;

-- --- 14. the prize -------------------------------------------------------------------------------------
do $$ declare claim uuid; begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  begin perform rpc_claim_prize(); raise exception 'a PlayStation was claimed on pocket change';
  exception when others then if sqlerrm not like '%1,000,000 points%' then raise; end if; end;
  perform test_reset();
  perform apply_ledger('11111111-aaaa-0000-0000-000000000001', 'adjustment', 'test-top-up', 1000000);
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  claim := rpc_claim_prize();
  assert (select prize from prize_claims where id = claim) = 'PlayStation 5', 'a PlayStation 5';
  assert (select status from prize_claims where id = claim) = 'pending', 'waiting on us';
  begin perform rpc_claim_prize(); raise exception 'two claims at once';
  exception when others then if sqlerrm not like '%already with us%' then raise; end if; end;
  perform test_reset();
  perform assert_conserved('after the prize claim');
end $$;

-- --- 15. the table ranks by balance ----------------------------------------------------------------------
do $$ begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  assert (select display_name from leaderboard('overall') limit 1) = 'Ana', 'the richest leads';
  assert (my_stats()->>'balance')::numeric = bal('11111111-aaaa-0000-0000-000000000001'), 'my_stats carries the balance';
  assert (my_stats()->>'ad_reward')::numeric = 0.2, 'and what an ad is worth';
  perform test_reset();
end $$;

-- --- 16. nothing but these functions can move a balance ----------------------------------------------------
do $$ begin
  assert has_table_privilege('authenticated', 'pool.ledger', 'insert') = false, 'the client cannot write the ledger';
  assert has_column_privilege('authenticated', 'pool.profiles', 'balance', 'update') = false, 'nor set a balance';
  assert has_table_privilege('authenticated', 'pool.jackpots', 'update') = false, 'nor touch a jackpot';
  assert has_function_privilege('authenticated', 'pool.apply_ledger(uuid, text, text, numeric)', 'execute') = false, 'nor call the ledger function';
  assert has_function_privilege('authenticated', 'pool.credit_house(text, numeric)', 'execute') = false, 'nor pay the house';
  assert has_function_privilege('authenticated', 'pool.settle_pot(uuid, pool.call_type)', 'execute') = false, 'nor settle a pot';
end $$;

-- --- 17. the conservation law ------------------------------------------------------------------------------
-- The headline: with nothing minted, every point in the game came from a season start or an ad.
do $$ declare c numeric := credited(); begin
  perform assert_conserved('the end of the season');
  assert c = 400 - 85 + 2 + 1000000, format('credited is four starts, Dee''s drain, ten ads at 0.2 and the top-up: %s', c);
  assert held() + house() <= c, 'balances and the house never exceed what was credited';
  -- every point that left a balance is refunded, won, with the house, in a jackpot, or still riding
  assert -(select coalesce(sum(amount),0) from ledger where reason = 'stake')
       = (select coalesce(sum(amount),0) from ledger where reason in ('refund','pot','jackpot')) + house() + escrow() + inflight(),
    'every staked point is accounted for';
end $$;

select 'ECONOMY TESTS PASSED' as result;
rollback;
