-- The jackpot (0020, 0021, 0031): a call type nobody lands rolls its whole pot forward
-- into the next card in the same competition. Run on a fresh db after the migrations:
--   psql pool -f tests/jackpot_test.sql
-- Every check raises on failure; a clean run prints "JACKPOT TESTS PASSED".
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
create or replace function bal(u text) returns numeric language sql stable as $$
  select balance from profiles where id = u::uuid $$;
create or replace function pts(p_user text, p_match int) returns numeric language sql stable as $$
  select e.points from entries e join cards c on c.id = e.card_id
  where c.match_id = p_match and e.user_id = p_user::uuid $$;
create or replace function jack(p_comp text, p_ct call_type) returns numeric language sql stable as $$
  select jackpot_of(p_comp, p_ct) $$;
create or replace function house() returns numeric language sql stable as $$
  select coalesce(sum(amount), 0) from ledger where reason = 'house' $$;
create or replace function got(p_user text, p_match int, p_reason text) returns numeric
language sql stable as $$
  select coalesce(sum(l.amount), 0) from ledger l
  where l.user_id = p_user::uuid and l.reason = p_reason
    and l.reference in (select k.id::text from calls k join entries e on e.id = k.entry_id
                        join cards c on c.id = e.card_id
                        where c.match_id = p_match and e.user_id = p_user::uuid) $$;
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
create or replace function scored(p_match int, p_player int, p_key text) returns void language sql as $$
  insert into match_events (match_id, type, minute, team_id, player_id, provider_key)
  select p_match, 'goal', 30, p.team_id, p_player, p_key from players p where p.id = p_player;
$$;
create or replace function lineup(p_match int) returns void language sql as $$
  insert into player_stats values (p_match, 90011, 'app', 1), (p_match, 90012, 'app', 1), (p_match, 90021, 'app', 1);
$$;
-- nothing is minted: every point is in a balance, with the house, in a jackpot, or still riding
create or replace function assert_conserved(p_where text) returns void language plpgsql as $$
declare held numeric; hse numeric; esc numeric; fly numeric; cred numeric;
begin
  select coalesce(sum(balance), 0) into held from profiles;
  hse := house();
  select coalesce(sum(amount), 0) into esc from jackpots;
  select coalesce(sum(c.stake), 0) into fly from calls c join entries e on e.id = c.entry_id
   where c.staked and not exists (select 1 from jackpot_moves j where j.card_id = e.card_id and j.call_type = c.call_type);
  select coalesce(sum(amount), 0) into cred from ledger where reason in ('signup', 'adjustment', 'ad_reward');
  assert held + hse + esc + fly = cred,
    format('%s: held %s + house %s + jackpots %s + riding %s <> credited %s', p_where, held, hse, esc, fly, cred);
end $$;

\set A '11111111-aaaa-0000-0000-000000000001'
\set B '22222222-bbbb-0000-0000-000000000002'
\set C '33333333-cccc-0000-0000-000000000003'

insert into teams (id, name, sport) values (9001, 'Rovers', 'soccer'), (9002, 'Athletic', 'soccer');
insert into players (id, team_id, name, sport) values
  (90011, 9001, 'Okafor', 'soccer'), (90012, 9001, 'Pires', 'soccer'), (90021, 9002, 'Lindqvist', 'soccer');

-- --- 1. a point is a stake now -----------------------------------------------------
do $$ begin
  assert (select array_agg(amount order by sort_order) from stakes) = array[1, 5, 10, 25, 50], 'the five quick stakes (0027)';
end $$;
select fixture(9500, 'PL');
do $$ begin
  begin
    perform play('11111111-aaaa-0000-0000-000000000001', 9500, '[{"call_type":"scorer","player_id":90011,"stake":101}]');
    raise exception 'a stake above the balance was accepted';
  exception when others then if sqlerrm not like '%at most 100 on one call%' then raise; end if; end;
end $$;
select play(:'A', 9500, '[{"call_type":"scorer","player_id":90011,"stake":1}]');
do $$ begin
  assert (select stake from calls limit 1) = 1, 'staked a single point';
  assert bal('11111111-aaaa-0000-0000-000000000001') = 100, 'and a season starts on 100';
  perform assert_conserved('a fresh season');
end $$;

-- --- 2. nobody lands it: the whole pot rolls over -----------------------------------
select fixture(9510, 'PL');
select play(:'A', 9510, '[{"call_type":"scorer","player_id":90011,"stake":5}]');
select play(:'B', 9510, '[{"call_type":"scorer","player_id":90012,"stake":2}]');
select kickoff(9510);
do $$ begin
  assert bal('11111111-aaaa-0000-0000-000000000001') = 95, 'Ana staked 5';
  assert bal('22222222-bbbb-0000-0000-000000000002') = 98, 'Ben staked 2';
  assert jack('PL', 'scorer') = 0, 'no jackpot yet';
end $$;
select lineup(9510);
select scored(9510, 90021, 'g1');          -- Lindqvist scored: neither call lands
select finish(9510, 0, 1);
do $$ begin
  -- 7 in the pot, all 7 rolls forward
  assert house() = 0, format('the house takes nothing, not %s', house());
  assert jack('PL', 'scorer') = 7, format('the jackpot is 7, not %s', jack('PL', 'scorer'));
  assert (select amount from jackpot_moves where call_type = 'scorer' and kind = 'rollover') = 7, 'and the move says so';
  assert pts('11111111-aaaa-0000-0000-000000000001', 9510) = -5, 'the card cost Ana her stake';
  perform assert_conserved('a pot nobody won');
end $$;

-- --- 3. the next card in that competition carries it, and only that competition -----
select fixture(9520, 'PD');
select play(:'A', 9520, '[{"call_type":"scorer","player_id":90011,"stake":2}]');
do $$ begin
  assert jack('PL', 'scorer') = 7, 'still standing while the next card is open';
  assert jack('PD', 'scorer') = 0, 'another competition has its own jackpot';
  assert jack('PL', 'yellow') = 0, 'and another call type has its own';
end $$;
select kickoff(9520); select lineup(9520); select scored(9520, 90021, 'g1'); select finish(9520, 0, 1);
do $$ begin
  assert jack('PD', 'scorer') = 2, format('La Liga holds 2, not %s', jack('PD', 'scorer'));
  assert jack('PL', 'scorer') = 7, 'the Premier League jackpot is untouched';
  perform assert_conserved('two competitions');
end $$;

-- --- 4. a void never feeds the pot -------------------------------------------------
select fixture(9530, 'PL');
select play(:'B', 9530, '[{"call_type":"assist","player_id":90012,"stake":5}]');
select kickoff(9530);
insert into player_stats values (9530, 90011, 'app', 1), (9530, 90021, 'app', 1);   -- Pires never came on
select finish(9530, 1, 0);
do $$ begin
  assert (select result from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
          where c.match_id = 9530 and k.call_type = 'assist') = 'void', 'an unused sub voids the call';
  assert jack('PL', 'assist') = 0, 'a refunded stake was never lost, so nothing rolls';
  assert house() = 0, 'and the house still holds nothing';
  assert bal('22222222-bbbb-0000-0000-000000000002') = 98, 'Ben has his 5 back';
  perform assert_conserved('an all-void pot');
end $$;

-- --- 5. somebody lands it: the pot and the jackpot both go to them --------------------
select fixture(9540, 'PL');
select play(:'A', 9540, '[{"call_type":"scorer","player_id":90011,"stake":5}]');
select play(:'B', 9540, '[{"call_type":"scorer","player_id":90012,"stake":5}]');
do $$ declare p record; begin
  -- the price on the board already carries the jackpot: 10 in the pot plus 7 standing, across
  -- the 5 on Okafor
  select * into p from card_pots((select id from cards where match_id = 9540)) where key = '90011';
  assert p.pot = 10 and p.jackpot = 7, format('pot %s jackpot %s', p.pot, p.jackpot);
  assert p.purse = 17, format('the purse is 17, not %s', p.purse);
  assert p.per_point = 3.4, format('a point on Okafor returns 3.40, not %s', p.per_point);
end $$;
select kickoff(9540); select lineup(9540); select scored(9540, 90011, 'g1');
select finish(9540, 1, 0);
do $$ begin
  assert got('11111111-aaaa-0000-0000-000000000001', 9540, 'pot') = 10, 'Ana took the whole pot';
  assert got('11111111-aaaa-0000-0000-000000000001', 9540, 'jackpot') = 7, 'and the whole jackpot';
  assert jack('PL', 'scorer') = 0, 'which is now spent';
  assert bal('11111111-aaaa-0000-0000-000000000001') = 105, format('Ana is on %s', bal('11111111-aaaa-0000-0000-000000000001'));
  assert pts('11111111-aaaa-0000-0000-000000000001', 9540) = 12, 'the card is worth 17 back on 5 staked';
  perform assert_conserved('a jackpot paid out');
end $$;

-- --- 6. two misses in a row compound ------------------------------------------------
select fixture(9550, 'PL');
select play(:'A', 9550, '[{"call_type":"scorer","player_id":90011,"stake":5}]');
select kickoff(9550); select lineup(9550); select scored(9550, 90021, 'g1'); select finish(9550, 0, 1);
do $$ begin assert jack('PL', 'scorer') = 5, format('first roll 5, got %s', jack('PL', 'scorer')); end $$;
select fixture(9560, 'PL');
select play(:'B', 9560, '[{"call_type":"scorer","player_id":90012,"stake":2}]');
select kickoff(9560); select lineup(9560); select scored(9560, 90021, 'g1'); select finish(9560, 0, 1);
do $$ begin
  assert jack('PL', 'scorer') = 7, format('compounded to 7, got %s', jack('PL', 'scorer'));
  perform assert_conserved('a compounded jackpot');
end $$;

-- --- 7. several winners share both pots in proportion, and the remainder is carried ----
select fixture(9570, 'PL');
select play(:'A', 9570, '[{"call_type":"scorer","player_id":90011,"stake":2}]');
select play(:'B', 9570, '[{"call_type":"scorer","player_id":90011,"stake":5}]');
select play(:'C', 9570, '[{"call_type":"scorer","player_id":90012,"stake":2}]');
select kickoff(9570); select lineup(9570); select scored(9570, 90011, 'g1'); select finish(9570, 0, 1);
do $$ begin
  -- 9 in the pot to share across the 7 that was right, plus the 7 jackpot
  assert got('11111111-aaaa-0000-0000-000000000001', 9570, 'pot') = 2.57, format('Ana pot share %s', got('11111111-aaaa-0000-0000-000000000001', 9570, 'pot'));
  assert got('22222222-bbbb-0000-0000-000000000002', 9570, 'pot') = 6.42, format('Ben pot share %s', got('22222222-bbbb-0000-0000-000000000002', 9570, 'pot'));
  assert got('11111111-aaaa-0000-0000-000000000001', 9570, 'jackpot') = 2, 'Ana jackpot share';
  assert got('22222222-bbbb-0000-0000-000000000002', 9570, 'jackpot') = 5, 'Ben jackpot share';
  -- 9 split seven ways leaves a penny, and it stays in the pot rather than being invented
  assert jack('PL', 'scorer') = 0.01, format('the rounding remainder is carried: %s', jack('PL', 'scorer'));
  assert pts('33333333-cccc-0000-0000-000000000003', 9570) = -2, 'Cem was wrong and paid for it';
  perform assert_conserved('a split pot');
end $$;

-- --- 8. the pot is decided once: settling again moves nothing --------------------------
do $$ declare a numeric := bal('11111111-aaaa-0000-0000-000000000001'); b numeric := bal('22222222-bbbb-0000-0000-000000000002'); h numeric := house(); begin
  perform process_match_updates();
  perform process_match_updates();
  assert bal('11111111-aaaa-0000-0000-000000000001') = a and bal('22222222-bbbb-0000-0000-000000000002') = b, 'no double payout';
  assert house() = h, 'and the house is still untouched';
  assert jack('PL', 'scorer') = 0.01, 'and no double roll';
  perform assert_conserved('settled twice over');
end $$;

-- --- 9. the books balance to the point -------------------------------------------------
do $$ declare held numeric; begin
  select coalesce(sum(balance), 0) into held from profiles;
  assert held = 102.57 + 97.42 + 98, format('the three balances are %s', held);
  assert house() = 0, format('the house holds nothing, not %s', house());
  assert house() + (select sum(amount) from jackpots) + held = 300, 'three seasons'' starts, all still in the game';
  perform assert_conserved('the end');
end $$;

select 'JACKPOT TESTS PASSED' as result;
rollback;
