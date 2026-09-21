-- Rules test for the non-football markets (0009). Run after game_test.sql's setup steps on a fresh db:
--   psql pool -f tests/multisport_test.sql
-- Every check raises on failure; a clean run prints "MULTISPORT TESTS PASSED".
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

-- --- fixtures -----------------------------------------------------------------
insert into teams (id, name, sport) values
  (2001, 'Lakers', 'basketball'), (2002, 'Celtics', 'basketball'),
  (3001, 'Giants', 'american_football'), (3002, 'Cowboys', 'american_football'),
  (4001, 'Angels', 'baseball'), (4002, 'Twins', 'baseball'),
  (5001, 'Kraken', 'hockey'), (5002, 'Canucks', 'hockey'),
  (6001, 'Sinner', 'tennis'), (6002, 'Alcaraz', 'tennis'),
  (7001, 'Moreno', 'mma'), (7002, 'Morales', 'mma');
insert into players (id, team_id, name, sport) values
  (20011, 2001, 'LeBron', 'basketball'), (20012, 2001, 'Luka', 'basketball'), (20021, 2002, 'Tatum', 'basketball'),
  (30011, 3001, 'Skattebo', 'american_football'), (30012, 3001, 'Nabers', 'american_football'),
  (40011, 4001, 'Trout', 'baseball'), (40021, 4002, 'Buxton', 'baseball'),
  (50011, 5001, 'Beniers', 'hockey'), (50021, 5002, 'Pettersson', 'hockey');
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, total_line, best_of) values
  (2000, 'NBA',   'basketball',        '2026', now() + interval '2 hours', 'TIMED', 2001, 2002, 220.5, null),
  (2003, 'NBA',   'basketball',        '2026', now() + interval '2 hours', 'TIMED', 2002, 2001, null,  null),
  (3000, 'NFL',   'american_football', '2026', now() + interval '2 hours', 'TIMED', 3001, 3002, 44.5,  null),
  (3100, 'NFL',   'american_football', '2026', now() + interval '2 hours', 'TIMED', 3002, 3001, 41.5,  null),
  (4000, 'MLB',   'baseball',          '2026', now() + interval '2 hours', 'TIMED', 4001, 4002, 8.5,   null),
  (5000, 'NHL',   'hockey',            '2026', now() + interval '2 hours', 'TIMED', 5001, 5002, 6,     null),
  (6000, 'ATP',   'tennis',            '2026', now() + interval '2 hours', 'TIMED', 6001, 6002, null,  3),
  (6100, 'ATP',   'tennis',            '2026', now() + interval '2 hours', 'TIMED', 6002, 6001, null,  3),
  (7000, 'UFC',   'mma',               '2026', now() + interval '2 hours', 'TIMED', 7001, 7002, null,  3),
  (7100, 'UFC',   'mma',               '2026', now() + interval '2 hours', 'TIMED', 7002, 7001, null,  3),
  (7200, 'UFC',   'mma',               '2026', now() + interval '2 hours', 'TIMED', 7001, 7002, null,  5);

-- --- validation -----------------------------------------------------------------
do $$ begin
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 2003, '[{"call_type":"total","yes":true}]', '%no line%'), 'total without a line';
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 2000, '[{"call_type":"margin","team_id":2001,"pick":"3-9"}]', '%margin band%'), 'unknown band';
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 2000, '[{"call_type":"draw","yes":true}]', '%not available%'), 'no draw in basketball';
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 2000, '[{"call_type":"top_scorer","player_id":30011}]', '%two squads%'), 'player from another game';
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 6000, '[{"call_type":"sets","home_goals":2,"away_goals":2}]', '%possible set score%'), 'impossible set score';
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 6000, '[{"call_type":"sets","home_goals":3,"away_goals":1}]', '%possible set score%'), 'best-of-5 score in a best of 3';
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 7000, '[{"call_type":"round","pick":"4"}]', '%round between 1 and 3%'), 'round past the scheduled length';
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 7000, '[{"call_type":"method","pick":"Doctor stoppage"}]', '%unknown method%'), 'unknown method';
  assert rejects('aaaaaaaa-0000-0000-0000-000000000001', 7000, '[{"call_type":"total","yes":true}]', '%not available%'), 'no total in MMA';
end $$;

-- --- basketball: 112–104, Luka and Tatum tie on 34 --------------------------------
select play(:'A', 2000, '[{"call_type":"winner","team_id":2001},{"call_type":"total","yes":true,"line":150},
  {"call_type":"margin","team_id":2001,"pick":"6-10"},{"call_type":"top_scorer","player_id":20012}]', 'total');
select play(:'B', 2000, '[{"call_type":"winner","team_id":2002},{"call_type":"total","yes":false},
  {"call_type":"margin","team_id":2002,"pick":"1-5"},{"call_type":"top_scorer","player_id":20021}]');
do $$ begin
  assert (select line from calls where call_type = 'total' limit 1) = 220.5, 'the line is the board''s, not the client''s';
  assert (select label from card_crowd((select id from cards where match_id = 2000)) where call_type = 'total' and key = 'true') = 'Over 220.5', 'crowd label';
end $$;
insert into player_stats values (2000, 20011, 'pts', 20), (2000, 20012, 'pts', 34), (2000, 20021, 'pts', 34);
select finish(2000, 112, 104);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 2000, 'total') = 'miss', 'boosted over misses at 216';
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 2000) = 1 + 5 + 7, 'Ana: winner + margin + top scorer';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 2000) = 2 + 7, 'Ben: under + tied top scorer';
  assert (select count(*) from cards where match_id = 2000 and status = 'settled') = 1, 'card settled';
  assert (select points from leaderboard('sport', 'basketball') where display_name = 'Ana') = 13, 'sport table';
  assert (select count(*) from leaderboard('sport', 'hockey')) = 0, 'sport table is per sport';
end $$;

-- --- American football: a touchdown lands live; a game with no box score voids -------
select play(:'A', 3000, '[{"call_type":"scorer","player_id":30011},{"call_type":"margin","team_id":3001,"pick":"8-14"}]');
select play(:'B', 3000, '[{"call_type":"scorer","player_id":30012},{"call_type":"total","yes":true}]');
update matches set status = 'IN_PLAY', utc_date = now() - interval '1 hour' where id = 3000;
insert into player_stats values (3000, 30011, 'td', 1), (3000, 30012, 'td', 0);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 3000, 'scorer') = 'hit', 'touchdown settles during play';
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 3000, 'scorer') = 'pending', 'no touchdown yet is still pending';
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 3000, 'total') = 'pending', 'result calls wait for the end';
end $$;
select finish(3000, 28, 20);
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 3000) = 6 + 5, 'Ana: TD + margin 8';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 3000) = 2, 'Ben: over 44.5 at 48, no TD';
end $$;
select play(:'A', 3100, '[{"call_type":"scorer","player_id":30011}]');
select finish(3100, 17, 10);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 3100, 'scorer') = 'void', 'no box score: void, not a miss';
end $$;

-- --- baseball: 5–4, one-run margin ------------------------------------------------
select play(:'A', 4000, '[{"call_type":"margin","team_id":4001,"pick":"1"},{"call_type":"scorer","player_id":40011}]');
select play(:'B', 4000, '[{"call_type":"total","yes":false},{"call_type":"scorer","player_id":40021}]');
insert into player_stats values (4000, 40011, 'hr', 0), (4000, 40021, 'hr', 2);
select finish(4000, 5, 4);
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 4000) = 4, 'Ana: one-run margin, no homer';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 4000) = 6, 'Ben: under misses at 9, homer lands';
end $$;

-- --- hockey: 4–2 on a line of 6 is a push -----------------------------------------
select play(:'A', 5000, '[{"call_type":"total","yes":true},{"call_type":"score","home_goals":4,"away_goals":2}]');
select play(:'B', 5000, '[{"call_type":"winner","team_id":5002},{"call_type":"scorer","player_id":50011}]');
insert into player_stats values (5000, 50011, 'g', 2), (5000, 50021, 'g', 1);
select finish(5000, 4, 2);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 5000, 'total') = 'void', 'push voids';
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 5000) = 8, 'Ana: exact score';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 5000) = 5, 'Ben: goalscorer from the other side';
end $$;

-- --- tennis: 2–1 in full; then a retirement ---------------------------------------
select play(:'A', 6000, '[{"call_type":"winner","team_id":6001},{"call_type":"distance","yes":true},{"call_type":"sets","home_goals":2,"away_goals":1}]');
select play(:'B', 6000, '[{"call_type":"winner","team_id":6002},{"call_type":"sets","home_goals":0,"away_goals":2}]');
select finish(6000, 2, 1, '{"winner":"home"}');
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 6000) = 1 + 3 + 5, 'Ana: all three';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 6000) = 0, 'Ben: nothing';
end $$;
-- home (Alcaraz) leads a set and retires: the away side wins, set calls void
select play(:'A', 6100, '[{"call_type":"winner","team_id":6002},{"call_type":"sets","home_goals":2,"away_goals":0},{"call_type":"distance","yes":false}]');
select finish(6100, 1, 0, '{"winner":"away","retired":true}');
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 6100, 'winner') = 'miss', 'retirement: the provider''s winner, not the set count';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 6100, 'sets') = 'void', 'set score void on retirement';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 6100, 'distance') = 'void', 'distance void on retirement';
end $$;

-- --- MMA: a round-2 KO, a decision, a no contest -----------------------------------
select play(:'A', 7000, '[{"call_type":"winner","team_id":7001},{"call_type":"distance","yes":false},{"call_type":"method","pick":"KO/TKO"},{"call_type":"round","pick":"2"}]');
select play(:'B', 7000, '[{"call_type":"winner","team_id":7002},{"call_type":"distance","yes":true},{"call_type":"method","pick":"Decision"},{"call_type":"round","pick":"3"}]');
select finish(7000, 1, 0, '{"winner":"home","method":"KO/TKO","round":"2"}');
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 7000) = 1 + 2 + 4 + 7, 'Ana: the full KO call';
  assert pts('bbbbbbbb-0000-0000-0000-000000000002', 7000) = 0, 'Ben: nothing';
end $$;
select play(:'A', 7100, '[{"call_type":"distance","yes":true},{"call_type":"method","pick":"Decision"},{"call_type":"round","pick":"1"}]');
select finish(7100, 0, 1, '{"winner":"away","method":"Decision","round":"3"}');
select process_match_updates();
do $$ begin
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 7100) = 2 + 4, 'Ana: distance + decision';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 7100, 'round') = 'miss', 'a decision misses every round';
end $$;
select play(:'A', 7200, '[{"call_type":"winner","team_id":7001},{"call_type":"method","pick":"Submission"},{"call_type":"round","pick":"5"}]');
select finish(7200, 0, 0, '{"winner":"none"}');
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 7200, 'winner') = 'void', 'no contest voids the winner';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 7200, 'method') = 'void', 'no contest voids the method';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 7200, 'round') = 'void', 'no contest voids the round';
end $$;

-- --- the board carries sport fields; stickers per competition ------------------------
do $$ begin
  assert (select sport_name from v_board where match_id = 2000) = 'Basketball', 'board has sport name';
  assert (select count(*) from stickers where competition_code = 'UFC' and call_type = 'round') = 1, 'sticker for the round call';
end $$;

select 'MULTISPORT TESTS PASSED' as result;
rollback;
