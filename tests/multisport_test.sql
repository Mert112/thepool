-- Rules test for every non-football market and the sportsbook pricing (0009–0014). Run on a fresh db after the migrations:
--   psql pool -f tests/multisport_test.sql
-- Every check raises on failure; a clean run prints "MULTISPORT TESTS PASSED". Points = 10 × the locked decimal price.
\set ON_ERROR_STOP on
begin;
set search_path = pool, public;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'ana@example.com'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'ben@example.com');
update profiles set display_name = 'Ana' where email = 'ana@example.com';
update profiles set display_name = 'Ben' where email = 'ben@example.com';

create or replace function test_as(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true), set_config('role', 'authenticated', true);
$$;
create or replace function test_reset() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', true), set_config('role', 'postgres', true);
$$;
-- play a public complex card on a match as a user
create or replace function play(p_user text, p_match int, p_calls jsonb, p_boost call_type default null) returns uuid
language plpgsql as $$
declare card uuid;
begin
  perform test_as(p_user);
  card := rpc_open_card(p_match, 'complex', null);
  perform rpc_save_calls(card, p_calls);
  if p_boost is not null then perform rpc_set_boost(card, p_boost); end if;
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
create or replace function pts(p_user text, p_match int) returns int language sql as $$
  select e.points from entries e join cards c on c.id = e.card_id where c.match_id = p_match and e.user_id = p_user::uuid $$;
create or replace function res(p_user text, p_match int, p_ct call_type) returns call_result language sql as $$
  select k.result from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
  where c.match_id = p_match and e.user_id = p_user::uuid and k.call_type = p_ct $$;
create or replace function finish(p_match int, h int, a int, detail jsonb default '{}') returns void language sql as $$
  update matches set status = 'FINISHED', utc_date = now() - interval '3 hours', home_score = h, away_score = a,
         result_detail = detail, provider_updated = now() where id = p_match;
$$;

\set A 'aaaaaaaa-0000-0000-0000-000000000001'
\set B 'bbbbbbbb-0000-0000-0000-000000000002'
create or replace function price_of(p_user text, p_match int, p_ct call_type) returns numeric language sql as $$
  select k.price from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
  where c.match_id = p_match and e.user_id = p_user::uuid and k.call_type = p_ct $$;

-- --- fixtures -----------------------------------------------------------------
insert into teams (id, name, sport) values
  (2001, 'Lakers', 'basketball'), (2002, 'Celtics', 'basketball'),
  (3001, 'Giants', 'american_football'), (3002, 'Cowboys', 'american_football'),
  (4001, 'Angels', 'baseball'), (4002, 'Twins', 'baseball'),
  (5001, 'Kraken', 'hockey'), (5002, 'Canucks', 'hockey'),
  (6001, 'Sinner', 'tennis'), (6002, 'Alcaraz', 'tennis'),
  (7001, 'Moreno', 'mma'), (7002, 'Morales', 'mma'),
  (8001, 'Fiji', 'soccer'), (8002, 'Vanuatu', 'soccer');
insert into players (id, team_id, name, sport) values
  (20011, 2001, 'LeBron', 'basketball'), (20012, 2001, 'Luka', 'basketball'), (20021, 2002, 'Tatum', 'basketball'),
  (30011, 3001, 'Skattebo', 'american_football'), (30012, 3001, 'Nabers', 'american_football'),
  (40011, 4001, 'Trout', 'baseball'), (40021, 4002, 'Buxton', 'baseball'),
  (50011, 5001, 'Beniers', 'hockey'), (50021, 5002, 'Pettersson', 'hockey'),
  (80011, 8001, 'Krishna', 'soccer'), (80012, 8001, 'Dunadamu', 'soccer');
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, total_line, best_of, odds) values
  (2000, 'NBA', 'basketball',        '2026', now() + interval '2 hours', 'TIMED', 2001, 2002, 220.5, null,
     '{"home":1.5,"away":2.7,"spread":{"home_line":-5.5,"home":1.91,"away":1.91},"total":{"line":220.5,"over":1.87,"under":1.95}}'),
  (2003, 'NBA', 'basketball',        '2026', now() + interval '2 hours', 'TIMED', 2002, 2001, null,  null, '{}'),
  (2100, 'NBA', 'basketball',        '2026', now() + interval '2 hours', 'TIMED', 2001, 2002, 210.5, null, '{"spread":{"home_line":-4.5,"home":1.91,"away":1.91}}'),
  (3000, 'NFL', 'american_football', '2026', now() + interval '2 hours', 'TIMED', 3001, 3002, 44.5,  null, '{"spread":{"home_line":-3.5,"home":1.91,"away":1.91}}'),
  (3100, 'NFL', 'american_football', '2026', now() + interval '2 hours', 'TIMED', 3002, 3001, 41.5,  null, '{}'),
  (4000, 'MLB', 'baseball',          '2026', now() + interval '2 hours', 'TIMED', 4001, 4002, 8.5,   null, '{"spread":{"home_line":-1.5,"home":2.2,"away":1.7}}'),
  (5000, 'NHL', 'hockey',            '2026', now() + interval '2 hours', 'TIMED', 5001, 5002, 6,     null, '{}'),
  (5100, 'NHL', 'hockey',            '2026', now() + interval '2 hours', 'TIMED', 5001, 5002, 6.5,   null, '{"spread":{"home_line":-1.5,"home":2.4,"away":1.6}}'),
  (6000, 'ATP', 'tennis',            '2026', now() + interval '2 hours', 'TIMED', 6001, 6002, null,  3,    '{}'),
  (6100, 'ATP', 'tennis',            '2026', now() + interval '2 hours', 'TIMED', 6002, 6001, null,  3,    '{}'),
  (6200, 'ATP', 'tennis',            '2026', now() + interval '2 hours', 'TIMED', 6001, 6002, null,  3,    '{}'),
  (7000, 'UFC', 'mma',               '2026', now() + interval '2 hours', 'TIMED', 7001, 7002, null,  3,    '{}'),
  (7100, 'UFC', 'mma',               '2026', now() + interval '2 hours', 'TIMED', 7002, 7001, null,  3,    '{}'),
  (7200, 'UFC', 'mma',               '2026', now() + interval '2 hours', 'TIMED', 7001, 7002, null,  5,    '{}'),
  (7300, 'UFC', 'mma',               '2026', now() + interval '2 hours', 'TIMED', 7001, 7002, null,  3,    '{}'),
  (8000, 'FRI', 'soccer',            '2026', now() + interval '2 hours', 'TIMED', 8001, 8002, 2.5,   null, '{"home":1.8,"draw":3.6,"away":4.5}');
insert into match_props values (2000, 20011, 'pts', 25.5, now()), (2000, 20012, 'reb', 8.5, now()), (3000, 30012, 'rec_yds', 65.5, now());

-- --- validation -----------------------------------------------------------------
do $$ declare u text := 'aaaaaaaa-0000-0000-0000-000000000001'; begin
  assert rejects(u, 2003, '[{"call_type":"total","yes":true}]', '%no line%'), 'total without a line';
  assert rejects(u, 2003, '[{"call_type":"spread","team_id":2001}]', '%no spread%'), 'spread without a line';
  assert rejects(u, 2000, '[{"call_type":"margin","team_id":2001,"pick":"6-10"}]', '%not available%'), 'margin bands are gone (0014)';
  assert rejects(u, 2000, '[{"call_type":"winner","pick":"draw"}]', '%no draw%'), 'no draw in basketball';
  assert rejects(u, 2000, '[{"call_type":"top_scorer","player_id":30011}]', '%two squads%'), 'player from another game';
  assert rejects(u, 2000, '[{"call_type":"player_line","player_id":20021,"pick":"pts","yes":true}]', '%not on the board%'), 'no such player line';
  assert rejects(u, 6000, '[{"call_type":"sets","home_goals":2,"away_goals":2}]', '%possible set score%'), 'impossible set score';
  assert rejects(u, 6000, '[{"call_type":"sets","home_goals":3,"away_goals":1}]', '%possible set score%'), 'best-of-5 score in a best of 3';
  assert rejects(u, 7000, '[{"call_type":"round","pick":"4"}]', '%round between 1 and 3%'), 'round past the scheduled length';
  assert rejects(u, 7000, '[{"call_type":"method","team_id":7001,"pick":"Doctor stoppage"}]', '%unknown method%'), 'unknown method';
  assert rejects(u, 7000, '[{"call_type":"method","pick":"KO/TKO"}]', '%fighter who wins%'), 'the method names a fighter';
  assert rejects(u, 7000, '[{"call_type":"total","yes":true}]', '%not available%'), 'no total in MMA';
  assert rejects(u, 7000, '[{"call_type":"distance","yes":true}]', '%not available%'), 'no distance call in MMA (0012)';
  assert rejects(u, 8000, '[{"call_type":"draw","yes":true}]', '%not available%'), 'football''s draw lives in the result (0014)';
end $$;

-- --- no hedging -----------------------------------------------------------------
do $$ declare u text := 'bbbbbbbb-0000-0000-0000-000000000002'; begin
  assert rejects(u, 8000, '[{"call_type":"score","home_goals":1,"away_goals":1},{"call_type":"winner","team_id":8002}]', '%level scoreline%'), 'level score + a side';
  assert rejects(u, 8000, '[{"call_type":"score","home_goals":2,"away_goals":1},{"call_type":"winner","pick":"draw"}]', '%contradicts your draw%'), 'score with a winner + the draw';
  assert rejects(u, 8000, '[{"call_type":"score","home_goals":2,"away_goals":1},{"call_type":"winner","team_id":8002}]', '%other side winning%'), 'score backs the other side';
  assert rejects(u, 5100, '[{"call_type":"score","home_goals":5,"away_goals":2},{"call_type":"total","yes":false}]', '%over/under disagree%'), 'score vs under';
  assert rejects(u, 5100, '[{"call_type":"score","home_goals":3,"away_goals":2},{"call_type":"spread","team_id":5001}]', '%loses your spread%'), 'score vs spread';
  assert rejects(u, 5100, '[{"call_type":"score","home_goals":3,"away_goals":3}]', '%always has a winner%'), 'no level hockey score';
  assert rejects(u, 2100, '[{"call_type":"winner","team_id":2002},{"call_type":"spread","team_id":2001}]', '%other side to win%'), 'giving points needs your side to win';
  assert rejects(u, 6200, '[{"call_type":"winner","team_id":6001},{"call_type":"sets","home_goals":0,"away_goals":2}]', '%other player winning%'), 'sets vs winner';
  assert rejects(u, 6200, '[{"call_type":"sets","home_goals":2,"away_goals":0},{"call_type":"distance","yes":true}]', '%goes the distance%'), 'straight sets vs distance';
  assert rejects(u, 7300, '[{"call_type":"winner","team_id":7001},{"call_type":"method","team_id":7002,"pick":"KO/TKO"}]', '%other fighter%'), 'method vs winner';
  assert rejects(u, 7300, '[{"call_type":"method","team_id":7001,"pick":"Decision"},{"call_type":"round","pick":"2"}]', '%decision has no finishing round%'), 'round vs decision';
  -- consistent combinations go through
  assert not rejects(u, 8000, '[{"call_type":"winner","team_id":8001},{"call_type":"score","home_goals":2,"away_goals":1},{"call_type":"total","yes":true}]', '%'), 'consistent football card';
  assert not rejects(u, 2100, '[{"call_type":"winner","team_id":2002},{"call_type":"spread","team_id":2002}]', '%'), 'underdog + its points';
  assert not rejects(u, 7300, '[{"call_type":"method","team_id":7001,"pick":"Submission"},{"call_type":"round","pick":"1"}]', '%'), 'consistent fight card';
end $$;

-- --- football: a 3-way result priced from the odds; a withdrawn card; non-runners ----------
select play(:'A', 8000, '[{"call_type":"winner","pick":"draw"}]');
do $$ begin
  assert price_of('aaaaaaaa-0000-0000-0000-000000000001', 8000, 'winner') = 3.6, 'the draw at its price';
  assert (select label from card_crowd((select id from cards where match_id = 8000 and crew_id is null)) where call_type = 'winner' and key = 'draw') = 'Draw', 'crowd: draw';
end $$;
do $$ declare card uuid := (select id from cards where match_id = 8000 and crew_id is null); begin
  perform test_as('aaaaaaaa-0000-0000-0000-000000000001');
  assert rpc_save_calls(card, '[]') is null, 'empty save returns no entry';
  perform test_reset();
  assert (select count(*) from entries where card_id = card and user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 0, 'entry withdrawn';
end $$;
-- Dunadamu never came on; Krishna played but was not booked
select play(:'A', 8000, '[{"call_type":"winner","team_id":8001},{"call_type":"scorer","player_id":80012},{"call_type":"yellow","player_id":80011}]');
insert into player_stats values (8000, 80011, 'app', 1);
select finish(8000, 1, 0);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8000, 'scorer') = 'void', 'unused sub: scorer void';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8000, 'yellow') = 'miss', 'played, not booked: miss';
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 8000) = 18, 'Fiji at 1.8 pays 18';
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 8000, 'total') = 'miss', 'one goal is under 2.5';
end $$;

-- --- basketball: 112–104 · prices from the odds, locked at save; spread; player lines; tied top scorer ----------
select play(:'A', 2000, '[{"call_type":"winner","team_id":2001},{"call_type":"total","yes":true,"line":150},
  {"call_type":"spread","team_id":2001},{"call_type":"top_scorer","player_id":20012},
  {"call_type":"player_line","player_id":20011,"pick":"pts","yes":false}]', 'total');
select play(:'B', 2000, '[{"call_type":"winner","team_id":2002},{"call_type":"total","yes":false},
  {"call_type":"spread","team_id":2002},{"call_type":"top_scorer","player_id":20021},
  {"call_type":"player_line","player_id":20012,"pick":"reb","yes":true}]');
do $$ begin
  assert (select line from calls where call_type = 'total' limit 1) = 220.5, 'the line is the board''s, not the client''s';
  assert price_of('aaaaaaaa-0000-0000-0000-000000000001', 2000, 'winner') = 1.5, 'favourite at 1.5';
  assert price_of('bbbbbbbb-0000-0000-0000-000000000002', 2000, 'winner') = 2.7, 'underdog at 2.7';
  assert (select k.line from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
           where c.match_id = 2000 and e.user_id = 'bbbbbbbb-0000-0000-0000-000000000002' and k.call_type = 'spread') = 5.5, 'the underdog gets +5.5';
  assert (select label from card_crowd((select id from cards where match_id = 2000)) where call_type = 'total' and key = 'true') = 'Over 220.5', 'crowd: total';
  assert (select label from card_crowd((select id from cards where match_id = 2000)) where call_type = 'spread' and key = '2001') = 'Lakers -5.5', 'crowd: spread';
end $$;
-- the market moves after Ana saved: her unchanged picks keep their price, a new pick takes today's
update matches set odds = jsonb_set(jsonb_set(odds, '{home}', '1.3'), '{away}', '3.4') where id = 2000;
do $$ declare card uuid := (select id from cards where match_id = 2000 and crew_id is null); begin
  perform test_as('aaaaaaaa-0000-0000-0000-000000000001');
  perform rpc_save_calls(card, (select jsonb_agg(jsonb_build_object('call_type', k.call_type, 'team_id', k.team_id, 'yes', k.yes, 'player_id', k.player_id, 'pick', k.pick))
                                  from calls k join entries e on e.id = k.entry_id where e.card_id = card and e.user_id = 'aaaaaaaa-0000-0000-0000-000000000001'));
  perform test_reset();
  assert price_of('aaaaaaaa-0000-0000-0000-000000000001', 2000, 'winner') = 1.5, 'an unchanged pick keeps its price';
  perform test_as('bbbbbbbb-0000-0000-0000-000000000002');
  perform rpc_save_calls(card, '[{"call_type":"winner","team_id":2001},{"call_type":"total","yes":false},{"call_type":"top_scorer","player_id":20021},{"call_type":"player_line","player_id":20012,"pick":"reb","yes":true}]');
  perform test_reset();
  assert price_of('bbbbbbbb-0000-0000-0000-000000000002', 2000, 'winner') = 1.3, 'a changed pick takes today''s price';
end $$;
insert into player_stats values (2000, 20011, 'pts', 20), (2000, 20012, 'pts', 34), (2000, 20021, 'pts', 34), (2000, 20012, 'reb', 11),
  (2000, 20011, 'app', 1), (2000, 20012, 'app', 1), (2000, 20021, 'app', 1);
select finish(2000, 112, 104);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 2000, 'total') = 'miss', 'boosted over misses at 216';
  -- Ana: Lakers 15 + covers -5.5 by 8 → 19 + Luka tied top 50 + LeBron under 25.5 (20) 19 = 103
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 2000) = 15 + 19 + 50 + 19, format('Ana %s', pts('aaaaaaaa-0000-0000-0000-000000000001', 2000));
  -- Ben: Lakers now at 1.3 → 13 + under at 1.95 → 20 (19.5 rounds up) + Tatum tied top 50 + Luka over 8.5 rebounds 19 = 102
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 2000) = 13 + 20 + 50 + 19, format('Ben %s', pts('bbbbbbbb-0000-0000-0000-000000000002', 2000));
  assert (select count(*) from cards where match_id = 2000 and status = 'settled') = 1, 'card settled';
  assert (select points from leaderboard('sport', 'basketball') where display_name = 'Ana') = 103, 'sport table';
  assert (select count(*) from leaderboard('sport', 'hockey')) = 0, 'sport table is per sport';
end $$;

-- --- American football: a touchdown lands live; spread; a player line; no box score voids -------
select play(:'A', 3000, '[{"call_type":"scorer","player_id":30011},{"call_type":"spread","team_id":3001},{"call_type":"player_line","player_id":30012,"pick":"rec_yds","yes":true}]');
select play(:'B', 3000, '[{"call_type":"scorer","player_id":30012},{"call_type":"total","yes":true}]');
update matches set status = 'IN_PLAY', utc_date = now() - interval '1 hour' where id = 3000;
insert into player_stats values (3000, 30011, 'td', 1), (3000, 30012, 'td', 0), (3000, 30011, 'app', 1), (3000, 30012, 'app', 1);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 3000, 'scorer') = 'hit', 'touchdown settles during play';
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 3000, 'scorer') = 'pending', 'no touchdown yet is still pending';
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 3000, 'total') = 'pending', 'result calls wait for the end';
end $$;
insert into player_stats values (3000, 30012, 'rec_yds', 40);
select finish(3000, 28, 20);
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 3000) = 28 + 19, 'Ana: TD 28 + covers -3.5; Nabers 40 yds is under';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 3000, 'player_line') = 'miss', 'over 65.5 misses at 40';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 3000) = 19, 'Ben: over 44.5 at 48';
end $$;
select play(:'A', 3100, '[{"call_type":"scorer","player_id":30011}]');
select finish(3100, 17, 10);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 3100, 'scorer') = 'void', 'no box score: void, not a miss';
end $$;

-- --- baseball: 5–4 · the run line ---------------------------------------------------
select play(:'A', 4000, '[{"call_type":"spread","team_id":4002},{"call_type":"scorer","player_id":40011}]');
select play(:'B', 4000, '[{"call_type":"total","yes":false},{"call_type":"scorer","player_id":40021}]');
insert into player_stats values (4000, 40011, 'hr', 0), (4000, 40021, 'hr', 2), (4000, 40011, 'app', 1), (4000, 40021, 'app', 1);
select finish(4000, 5, 4);
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 4000) = 17, 'Ana: Twins +1.5 at 1.7 covers a one-run loss; no homer';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 4000) = 50, 'Ben: under misses at 9, homer at 5.0';
end $$;

-- --- hockey: 4–2 on a line of 6 is a push -----------------------------------------
select play(:'A', 5000, '[{"call_type":"total","yes":true},{"call_type":"score","home_goals":4,"away_goals":2}]');
select play(:'B', 5000, '[{"call_type":"winner","team_id":5002},{"call_type":"scorer","player_id":50011}]');
insert into player_stats values (5000, 50011, 'g', 2), (5000, 50021, 'g', 1);
select finish(5000, 4, 2);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 5000, 'total') = 'void', 'push voids';
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 5000) = 90, 'Ana: exact score at 9.0';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 5000) = 30, 'Ben: goalscorer at 3.0';
end $$;

-- --- tennis: 2–1 in full; then a retirement ---------------------------------------
select play(:'A', 6000, '[{"call_type":"winner","team_id":6001},{"call_type":"distance","yes":true},{"call_type":"sets","home_goals":2,"away_goals":1}]');
select play(:'B', 6000, '[{"call_type":"winner","team_id":6002},{"call_type":"sets","home_goals":0,"away_goals":2}]');
select finish(6000, 2, 1, '{"winner":"home"}');
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 6000) = 19 + 26 + 35, 'Ana: all three at standard prices';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 6000) = 0, 'Ben: nothing';
end $$;
select play(:'A', 6100, '[{"call_type":"winner","team_id":6002},{"call_type":"sets","home_goals":2,"away_goals":0},{"call_type":"distance","yes":false}]');
select finish(6100, 1, 0, '{"winner":"away","retired":true}');
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 6100, 'winner') = 'miss', 'retirement: the provider''s winner, not the set count';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 6100, 'sets') = 'void', 'set score void on retirement';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 6100, 'distance') = 'void', 'distance void on retirement';
end $$;

-- --- MMA: the fighter and the finish ------------------------------------------------------
select play(:'A', 7000, '[{"call_type":"winner","team_id":7001},{"call_type":"method","team_id":7001,"pick":"KO/TKO"},{"call_type":"round","pick":"2"}]');
select play(:'B', 7000, '[{"call_type":"winner","team_id":7002},{"call_type":"method","team_id":7002,"pick":"KO/TKO"}]');
select finish(7000, 1, 0, '{"winner":"home","method":"KO/TKO","round":"2"}');
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 7000) = 19 + 40 + 60, 'Ana: the full KO call';
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 7000, 'method') = 'miss', 'right finish, wrong fighter';
end $$;
select play(:'A', 7100, '[{"call_type":"method","team_id":7001,"pick":"Decision"}]');
select play(:'B', 7100, '[{"call_type":"round","pick":"1"}]');
select finish(7100, 0, 1, '{"winner":"away","method":"Decision","round":"3"}');
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 7100) = 40, 'Ana: Moreno by decision';
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 7100, 'round') = 'miss', 'a decision misses every round';
end $$;
select play(:'A', 7200, '[{"call_type":"winner","team_id":7001},{"call_type":"method","team_id":7001,"pick":"Submission"},{"call_type":"round","pick":"5"}]');
select finish(7200, 0, 0, '{"winner":"none"}');
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 7200, 'winner') = 'void', 'no contest voids the winner';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 7200, 'method') = 'void', 'no contest voids the method';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 7200, 'round') = 'void', 'no contest voids the round';
end $$;

-- --- the board carries sport fields and prices; stickers per competition ------------------------
do $$ begin
  assert (select sport_name from v_board where match_id = 2000) = 'Basketball', 'board has sport name';
  assert (select (odds->>'draw')::numeric from v_board where match_id = 8000) = 3.6, 'board has prices';
  assert (select count(*) from stickers where competition_code = 'UFC' and call_type = 'round') = 1, 'sticker for the round call';
end $$;

select 'MULTISPORT TESTS PASSED' as result;
rollback;
