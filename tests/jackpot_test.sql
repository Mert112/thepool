-- The jackpot (0020): a call type nobody lands rolls its losses forward, less a 10% rake, into the
-- next card in the same competition. Run on a fresh db after the migrations:
--   psql pool -f tests/jackpot_test.sql
-- Every check raises on failure; a clean run prints "JACKPOT TESTS PASSED".
\set ON_ERROR_STOP on
begin;
set search_path = pool, public;

insert into auth.users (id, email) values
  ('11111111-aaaa-0000-0000-000000000001', 'ana@example.com'),
  ('22222222-bbbb-0000-0000-000000000002', 'ben@example.com');
update profiles set display_name = initcap(split_part(email, '@', 1));

create or replace function test_as(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true), set_config('role', 'authenticated', true);
$$;
create or replace function test_reset() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', true), set_config('role', 'postgres', true);
$$;
create or replace function bal(u text) returns int language sql stable as $$
  select balance from profiles where id = u::uuid $$;
create or replace function pts(p_user text, p_match int) returns int language sql stable as $$
  select e.points from entries e join cards c on c.id = e.card_id
  where c.match_id = p_match and e.user_id = p_user::uuid $$;
create or replace function jack(p_comp text, p_ct call_type) returns int language sql stable as $$
  select jackpot_of(p_comp, p_ct) $$;
create or replace function got_jackpot(p_user text, p_match int, p_ct call_type) returns int
language sql stable as $$
  select coalesce(sum(l.amount), 0)::int from ledger l
  where l.user_id = p_user::uuid and l.reason = 'jackpot'
    and l.reference in (select k.id::text from calls k join entries e on e.id = k.entry_id
                        join cards c on c.id = e.card_id
                        where c.match_id = p_match and e.user_id = p_user::uuid and k.call_type = p_ct) $$;
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
-- a fixture, played, kicked off and finished in one go
create or replace function fixture(p_id int, p_comp text) returns void language sql as $$
  insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, odds)
  values (p_id, p_comp, 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, '{}');
$$;
create or replace function kickoff(p_match int) returns void language sql as $$
  update matches set utc_date = now() - interval '1 minute' where id = p_match;
  select sync_card_status();
$$;
create or replace function finish(p_match int, h int, a int) returns void language sql as $$
  update matches set status = 'FINISHED', utc_date = now() - interval '3 hours', home_score = h, away_score = a,
         ft_home = h, ft_away = a, duration = 'REGULAR', provider_updated = now() where id = p_match;
  select process_match_updates();
$$;
-- the called player scored; everyone else did not
create or replace function scored(p_match int, p_player int, p_key text) returns void language sql as $$
  insert into match_events (match_id, type, minute, team_id, player_id, provider_key)
  select p_match, 'goal', 30, p.team_id, p_player, p_key from players p where p.id = p_player;
$$;
create or replace function lineup(p_match int) returns void language sql as $$
  insert into player_stats values (p_match, 90011, 'app', 1), (p_match, 90012, 'app', 1), (p_match, 90021, 'app', 1);
$$;

\set A '11111111-aaaa-0000-0000-000000000001'
\set B '22222222-bbbb-0000-0000-000000000002'

insert into teams (id, name, sport) values (9001, 'Rovers', 'soccer'), (9002, 'Athletic', 'soccer');
insert into players (id, team_id, name, sport) values
  (90011, 9001, 'Okafor', 'soccer'), (90012, 9001, 'Pires', 'soccer'), (90021, 9002, 'Lindqvist', 'soccer');

-- --- 1. a point is a stake now -----------------------------------------------------
do $$ begin
  assert (select array_agg(amount order by sort_order) from stakes) = array[1, 2, 5, 10, 25, 50], 'the six stakes';
  assert (select min(amount) from stakes) = 1, 'a single point will do';
end $$;
select fixture(9500, 'PL');
do $$ begin
  begin
    perform play('11111111-aaaa-0000-0000-000000000001', 9500, '[{"call_type":"scorer","player_id":90011,"stake":100}]');
    raise exception 'a 100 stake was accepted';
  exception when others then if sqlerrm not like '%1, 2, 5, 10, 25 or 50%' then raise; end if; end;
end $$;
-- a one-point call goes through
select play(:'A', 9500, '[{"call_type":"scorer","player_id":90011,"stake":1}]');
do $$ begin assert (select stake from calls limit 1) = 1, 'staked a single point'; end $$;

-- --- 2. nobody lands it: the pot rolls over, less the 10% rake ----------------------
select fixture(9510, 'PL');
select play(:'A', 9510, '[{"call_type":"scorer","player_id":90011,"stake":50}]');
select play(:'B', 9510, '[{"call_type":"scorer","player_id":90012,"stake":25}]');
select kickoff(9510);
do $$ begin
  assert bal('11111111-aaaa-0000-0000-000000000001') = 950, 'Ana staked 50';
  assert bal('22222222-bbbb-0000-0000-000000000002') = 975, 'Ben staked 25';
  assert jack('PL', 'scorer') = 0, 'no jackpot yet';
end $$;
select lineup(9510);
select scored(9510, 90021, 'g1');          -- Lindqvist scored: neither call lands
select finish(9510, 0, 1);
do $$ begin
  -- 50 + 25 lost = 75; rake 8 (10% of 75, rounded); 67 rolls forward
  assert jack('PL', 'scorer') = 67, format('the jackpot is 67, not %s', jack('PL', 'scorer'));
  assert (select amount from jackpot_moves where call_type = 'scorer' and kind = 'rake') = 8, 'the house took 8';
  assert (select amount from jackpot_moves where call_type = 'scorer' and kind = 'rollover') = 67, 'and 67 rolled';
  assert bal('11111111-aaaa-0000-0000-000000000001') = 950, 'a miss returns nothing';
  assert pts('11111111-aaaa-0000-0000-000000000001', 9510) = -50, 'the card cost Ana 50';
end $$;

-- --- 3. the next card in that competition carries it, and only that competition -----
select fixture(9520, 'PD');
select play(:'A', 9520, '[{"call_type":"scorer","player_id":90011,"stake":10}]');
do $$ begin
  assert jack('PL', 'scorer') = 67, 'still standing while the next card is open';
  assert jack('PD', 'scorer') = 0, 'another competition has its own jackpot';
  assert jack('PL', 'yellow') = 0, 'and another call type has its own';
end $$;
select kickoff(9520); select lineup(9520); select scored(9520, 90021, 'g1'); select finish(9520, 0, 1);
do $$ begin
  -- 10 lost in La Liga: rake 1, 9 rolls — into La Liga, not the Premier League
  assert jack('PD', 'scorer') = 9, format('La Liga holds 9, not %s', jack('PD', 'scorer'));
  assert jack('PL', 'scorer') = 67, 'the Premier League jackpot is untouched';
end $$;

-- --- 4. a void never feeds the pot -------------------------------------------------
select fixture(9530, 'PL');
select play(:'B', 9530, '[{"call_type":"assist","player_id":90012,"stake":25}]');
select kickoff(9530);
insert into player_stats values (9530, 90011, 'app', 1), (9530, 90021, 'app', 1);   -- Pires never came on
select finish(9530, 1, 0);
do $$ begin
  assert (select result from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
          where c.match_id = 9530 and k.call_type = 'assist') = 'void', 'an unused sub voids the call';
  assert jack('PL', 'assist') = 0, 'a refunded stake was never lost, so nothing rolls';
  assert bal('22222222-bbbb-0000-0000-000000000002') = 975, 'and Ben has his 25 back';
end $$;

-- --- 5. somebody lands it: the jackpot goes to them, on top of the multiplier --------
select fixture(9540, 'PL');
select play(:'A', 9540, '[{"call_type":"scorer","player_id":90011,"stake":10}]');
select play(:'B', 9540, '[{"call_type":"scorer","player_id":90012,"stake":25}]');
select kickoff(9540); select lineup(9540); select scored(9540, 90011, 'g1');   -- Okafor scores: Ana lands it
select finish(9540, 1, 0);
do $$ begin
  assert got_jackpot('11111111-aaaa-0000-0000-000000000001', 9540, 'scorer') = 67, 'Ana took the whole jackpot';
  assert got_jackpot('22222222-bbbb-0000-0000-000000000002', 9540, 'scorer') = 0, 'Ben landed nothing';
  assert jack('PL', 'scorer') = 0, 'and the jackpot is spent';
  assert (select amount from jackpot_moves where card_id = (select id from cards where match_id = 9540) and kind = 'payout') = -67, 'the payout is on the record';
  -- Ana: 10 staked, 10 × 4 = 40 on the multiplier, plus the 67 jackpot
  assert bal('11111111-aaaa-0000-0000-000000000001') = 940 - 10 + 40 + 67, format('Ana is on %s', bal('11111111-aaaa-0000-0000-000000000001'));
  assert pts('11111111-aaaa-0000-0000-000000000001', 9540) = 40 + 67 - 10, format('the card is worth %s', pts('11111111-aaaa-0000-0000-000000000001', 9540));
end $$;

-- --- 6. two misses in a row compound ------------------------------------------------
select fixture(9550, 'PL');
select play(:'A', 9550, '[{"call_type":"scorer","player_id":90011,"stake":50}]');
select kickoff(9550); select lineup(9550); select scored(9550, 90021, 'g1'); select finish(9550, 0, 1);
do $$ begin assert jack('PL', 'scorer') = 45, format('first roll 45, got %s', jack('PL', 'scorer')); end $$;
select fixture(9560, 'PL');
select play(:'B', 9560, '[{"call_type":"scorer","player_id":90012,"stake":25}]');
select kickoff(9560); select lineup(9560); select scored(9560, 90021, 'g1'); select finish(9560, 0, 1);
do $$ begin assert jack('PL', 'scorer') = 45 + 22, format('compounded to 67, got %s', jack('PL', 'scorer')); end $$;

-- --- 7. several winners share it in proportion to what they staked --------------------
select fixture(9570, 'PL');
select play(:'A', 9570, '[{"call_type":"scorer","player_id":90011,"stake":10}]');
select play(:'B', 9570, '[{"call_type":"scorer","player_id":90011,"stake":50}]');
select kickoff(9570); select lineup(9570); select scored(9570, 90011, 'g1'); select finish(9570, 0, 1);
do $$ begin
  -- 67 across 60 staked: Ana 67×10/60 = 11, Ben 67×50/60 = 55, and the odd point stays put
  assert got_jackpot('11111111-aaaa-0000-0000-000000000001', 9570, 'scorer') = 11, format('Ana %s', got_jackpot('11111111-aaaa-0000-0000-000000000001', 9570, 'scorer'));
  assert got_jackpot('22222222-bbbb-0000-0000-000000000002', 9570, 'scorer') = 55, format('Ben %s', got_jackpot('22222222-bbbb-0000-0000-000000000002', 9570, 'scorer'));
  assert jack('PL', 'scorer') = 1, 'the rounding remainder is carried, never invented';
end $$;

-- --- 8. the jackpot is decided once: settling again moves nothing ----------------------
do $$ declare a int := bal('11111111-aaaa-0000-0000-000000000001'); b int := bal('22222222-bbbb-0000-0000-000000000002'); begin
  perform process_match_updates();
  perform process_match_updates();
  assert bal('11111111-aaaa-0000-0000-000000000001') = a and bal('22222222-bbbb-0000-0000-000000000002') = b, 'no double payout';
  assert jack('PL', 'scorer') = 1, 'and no double roll';
  assert (select count(*) from jackpot_moves where card_id = (select id from cards where match_id = 9570)) = 1, 'one move for that card';
end $$;

-- --- 9. the ledger still reconciles to every balance -----------------------------------
do $$ begin
  assert (select count(*) from profiles p
          where p.balance <> (select coalesce(sum(l.amount), 0) from ledger l where l.user_id = p.id)) = 0,
         'every balance is the sum of its ledger';
  -- and the house's rake plus the standing jackpots account for every point taken out of play
  assert (select coalesce(sum(amount), 0) from jackpot_moves where kind in ('rollover', 'payout'))
       = (select coalesce(sum(amount), 0) from jackpots), 'the jackpots hold exactly what rolled in less what was paid out';
end $$;

select 'JACKPOT TESTS PASSED' as result;
rollback;
