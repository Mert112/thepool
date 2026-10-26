-- Rules test for the football markets beyond the basic card: the 3-way result, the goals line,
-- the handicap, the red card's time window, non-runners and withdrawn cards.
-- Run on a fresh db after the migrations:  psql pool -f tests/football_test.sql
-- Every check raises on failure; a clean run prints "FOOTBALL TESTS PASSED".
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
create or replace function pts(p_user text, p_match int) returns int language sql as $$
  select e.points from entries e join cards c on c.id = e.card_id where c.match_id = p_match and e.user_id = p_user::uuid $$;
create or replace function res(p_user text, p_match int, p_ct call_type) returns call_result language sql as $$
  select k.result from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
  where c.match_id = p_match and e.user_id = p_user::uuid and k.call_type = p_ct $$;
create or replace function mult_of(p_user text, p_match int, p_ct call_type) returns numeric language sql as $$
  select k.multiplier from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
  where c.match_id = p_match and e.user_id = p_user::uuid and k.call_type = p_ct $$;
create or replace function finish(p_match int, h int, a int) returns void language sql as $$
  update matches set status = 'FINISHED', utc_date = now() - interval '3 hours', home_score = h, away_score = a,
         ft_home = h, ft_away = a, duration = 'REGULAR', provider_updated = now() where id = p_match;
$$;

\set A 'aaaaaaaa-0000-0000-0000-000000000001'
\set B 'bbbbbbbb-0000-0000-0000-000000000002'

-- --- fixtures -----------------------------------------------------------------
insert into teams (id, name, sport) values (8001, 'Fiji', 'soccer'), (8002, 'Vanuatu', 'soccer');
insert into players (id, team_id, name, sport) values
  (80011, 8001, 'Krishna', 'soccer'), (80012, 8001, 'Dunadamu', 'soccer'), (80021, 8002, 'Kaltack', 'soccer');
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, total_line, odds) values
  (8000, 'FRI', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 8001, 8002, 2.5, '{"home":1.8,"draw":3.6,"away":4.5}'),
  (8100, 'FRI', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 8001, 8002, null, '{}'),
  (8200, 'FRI', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 8001, 8002, 3.5,
     '{"home":2.1,"draw":3.3,"away":3.4,"spread":{"home_line":-1.5,"home":1.91,"away":1.91},"total":{"line":3.5,"over":1.87,"under":1.95}}'),
  (8300, 'FRI', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 8001, 8002, 2.5,
     '{"spread":{"home_line":-1.5,"home":1.91,"away":1.91},"total":{"line":2.5,"over":1.91,"under":1.91}}');

-- --- every other sport is gone (0017) -------------------------------------------
do $$ begin
  assert (select count(*) from sports) = 1, 'one sport';
  assert (select code from sports) = 'soccer', 'and it is football';
  assert (select count(*) from competitions where sport <> 'soccer') = 0, 'football competitions only';
  assert (select count(*) from markets where sport <> 'soccer') = 0, 'football markets only';
  assert to_regclass('pool.match_props') is null, 'player over/unders are gone with basketball';
  -- the card on offer
  assert (select array_agg(call_type::text order by sort_order) from markets where enabled)
         = array['winner','total','spread','score','scorer','assist','yellow','red'], 'the football card';
  assert (select array_agg(call_type::text order by call_type::text) from markets where enabled and simple)
         = array['total','winner'], 'the simple card is the result and the goals line';
end $$;

-- --- validation -----------------------------------------------------------------
do $$ declare u text := 'aaaaaaaa-0000-0000-0000-000000000001'; begin
  assert rejects(u, 8100, '[{"call_type":"total","yes":true}]', '%no goals line%'), 'total without a line';
  assert rejects(u, 8100, '[{"call_type":"spread","team_id":8001}]', '%no handicap%'), 'handicap without a line';
  assert rejects(u, 8000, '[{"call_type":"draw","yes":true}]', '%not available%'), 'the draw lives in the result';
  assert rejects(u, 8000, '[{"call_type":"motm","player_id":80011}]', '%not available%'), 'no man of the match';
  assert rejects(u, 8000, '[{"call_type":"method","team_id":8001,"pick":"KO/TKO"}]', '%not available%'), 'MMA is gone';
  assert rejects(u, 8000, '[{"call_type":"sets","home_goals":2,"away_goals":1}]', '%not available%'), 'tennis is gone';
  assert rejects(u, 8000, '[{"call_type":"top_scorer","player_id":80011}]', '%not available%'), 'basketball is gone';
  assert rejects(u, 8000, '[{"call_type":"winner","team_id":9999}]', '%one of the two teams%'), 'a foreign team';
  assert rejects(u, 8000, '[{"call_type":"scorer","player_id":99999}]', '%two squads%'), 'a player from nowhere';
  assert rejects(u, 8000, '[{"call_type":"red","player_id":80011,"pick":"91-95"}]', '%time window%'), 'unknown window';
  assert rejects(u, 8000, '[{"call_type":"yellow","player_id":80011,"pick":"0-15"}]', '%time window%'), 'only the red takes a window';
end $$;

-- --- no hedging -----------------------------------------------------------------
do $$ declare u text := 'bbbbbbbb-0000-0000-0000-000000000002'; begin
  assert rejects(u, 8200, '[{"call_type":"score","home_goals":1,"away_goals":1},{"call_type":"winner","team_id":8002}]', '%level scoreline%'), 'level score + a side';
  assert rejects(u, 8200, '[{"call_type":"score","home_goals":2,"away_goals":1},{"call_type":"winner","pick":"draw"}]', '%contradicts your draw%'), 'a scoreline with a winner + the draw';
  assert rejects(u, 8200, '[{"call_type":"score","home_goals":2,"away_goals":1},{"call_type":"winner","team_id":8002}]', '%other side winning%'), 'the scoreline backs the other side';
  assert rejects(u, 8200, '[{"call_type":"score","home_goals":1,"away_goals":0},{"call_type":"total","yes":true}]', '%over/under disagree%'), 'scoreline vs over';
  assert rejects(u, 8200, '[{"call_type":"score","home_goals":2,"away_goals":1},{"call_type":"spread","team_id":8001}]', '%loses your handicap%'), 'scoreline vs handicap';
  assert rejects(u, 8200, '[{"call_type":"winner","team_id":8002},{"call_type":"spread","team_id":8001}]', '%other side to win%'), 'giving goals needs your side to win';
  -- consistent combinations go through
  assert not rejects(u, 8200, '[{"call_type":"winner","team_id":8001},{"call_type":"score","home_goals":3,"away_goals":1},{"call_type":"total","yes":true},{"call_type":"spread","team_id":8001}]', '%'), 'a consistent card';
  assert not rejects(u, 8300, '[{"call_type":"winner","team_id":8002},{"call_type":"spread","team_id":8002}]', '%'), 'the underdog and its goals';
end $$;

-- --- the 3-way result, priced from the odds; a withdrawn card; non-runners ----------
select play(:'A', 8000, '[{"call_type":"winner","pick":"draw"}]');
do $$ begin
  assert mult_of('aaaaaaaa-0000-0000-0000-000000000001', 8000, 'winner') = 3, 'the draw pays 3×, a team 1.5×';
  assert (select label from card_crowd((select id from cards where match_id = 8000 and crew_id is null)) where call_type = 'winner' and key = 'draw') = 'Draw', 'crowd: draw';
end $$;
do $$ declare card uuid := (select id from cards where match_id = 8000 and crew_id is null); begin
  perform test_as('aaaaaaaa-0000-0000-0000-000000000001');
  assert rpc_save_calls(card, '[]') is null, 'an empty save returns no entry';
  perform test_reset();
  assert (select count(*) from entries where card_id = card and user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 0, 'entry withdrawn';
end $$;
-- Dunadamu never came on; Krishna played but was not booked
select play(:'A', 8000, '[{"call_type":"winner","team_id":8001},{"call_type":"scorer","player_id":80012},{"call_type":"yellow","player_id":80011}]');
select play(:'B', 8000, '[{"call_type":"total","yes":true}]');
insert into player_stats values (8000, 80011, 'app', 1);
select finish(8000, 1, 0);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8000, 'scorer') = 'void', 'an unused sub voids the scorer';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8000, 'yellow') = 'miss', 'played, not booked: a miss';
  -- three calls at the default 10: the result pays 10 × 1.5, the void hands 10 back, the yellow loses 10
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 8000) = 15 + 10 - 30, format('Ana is %s on the card', pts('aaaaaaaa-0000-0000-0000-000000000001', 8000));
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 8000, 'total') = 'miss', 'one goal is under 2.5';
end $$;

-- --- the handicap and the goals line: 3–1 covers -1.5 and goes over 3.5 is a push ------
select play(:'A', 8200, '[{"call_type":"spread","team_id":8001},{"call_type":"total","yes":true},{"call_type":"score","home_goals":3,"away_goals":1}]');
select play(:'B', 8200, '[{"call_type":"spread","team_id":8002},{"call_type":"total","yes":false}]');
do $$ begin
  assert (select k.line from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
           where c.match_id = 8200 and e.user_id = 'bbbbbbbb-0000-0000-0000-000000000002' and k.call_type = 'spread') = 1.5, 'the underdog gets +1.5';
  assert (select label from card_crowd((select id from cards where match_id = 8200)) where call_type = 'spread' and key = '8001') = 'Fiji -1.5', 'crowd: the handicap';
  assert (select label from card_crowd((select id from cards where match_id = 8200)) where call_type = 'total' and key = 'true') = 'Over 3.5', 'crowd: the goals line';
end $$;
select finish(8200, 3, 1);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8200, 'spread') = 'hit', '3–1 covers -1.5';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8200, 'total') = 'hit', 'four goals is over 3.5';
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8200, 'score') = 'hit', 'the exact scoreline';
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 8200, 'spread') = 'miss', '+1.5 does not save a two-goal loss';
end $$;

-- --- a push on a whole-number goals line -----------------------------------------
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, total_line, odds) values
  (8400, 'FRI', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 8001, 8002, 3, '{"total":{"line":3,"over":1.91,"under":1.91}}');
select play(:'A', 8400, '[{"call_type":"total","yes":true}]');
select finish(8400, 2, 1);
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8400, 'total') = 'void', 'three goals on a line of 3 is a push';
end $$;

-- --- the red card with a time window (0015) --------------------------------------
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, odds) values
  (8500, 'FRI', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 8001, 8002, '{}');
select play(:'A', 8500, '[{"call_type":"red","player_id":80011,"pick":"31-45"}]');
select play(:'B', 8500, '[{"call_type":"red","player_id":80011,"pick":"76-90"}]');
do $$ begin
  assert mult_of('aaaaaaaa-0000-0000-0000-000000000001', 8500, 'red') = 60, 'a window multiplies the call: 10 × 6';
  assert (select label from card_crowd((select id from cards where match_id = 8500 and crew_id is null)) where key = '80011:31-45') = 'Krishna · 31-45''', 'crowd: the window';
end $$;
update matches set status = 'IN_PLAY', utc_date = now() - interval '1 hour' where id = 8500;
insert into match_events (match_id, type, minute, injury_time, team_id, player_id, provider_key) values (8500, 'red', 45, 2, 8001, 80011, 'r1');
select process_match_updates();
do $$ begin
  assert res('aaaaaaaa-0000-0000-0000-000000000001', 8500, 'red') = 'hit', '45+2 lands in 31–45, during play';
  assert pts('aaaaaaaa-0000-0000-0000-000000000001', 8500) = 10 * 60 - 10, 'a 10 stake at 60× returns 600';
end $$;
select finish(8500, 0, 1);
select process_match_updates();
do $$ begin
  assert res('bbbbbbbb-0000-0000-0000-000000000002', 8500, 'red') = 'miss', 'the wrong window misses';
end $$;

-- --- the save path: Türkiye v France (the bug behind "No pick · 0") -----------------
-- Two users filled this card and later found a call they had made reading "No pick". The calls
-- they thought they had made contradicted the exact scoreline they set, so the app dropped them
-- before sending — it had to, because the server refuses a card whose calls cannot all land.
-- These checks pin both halves down: the refusal, and the fact that a save is a full replacement.
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, total_line, odds) values
  (8600, 'UNL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 8001, 8002, 3.5,
     '{"home":7.5,"draw":5.25,"away":1.32,"spread":{"home_line":1.5,"home":1.87,"away":1.83},"total":{"line":3.5,"over":1.91,"under":1.87}}');
do $$ declare u text := 'aaaaaaaa-0000-0000-0000-000000000001'; begin
  -- backing the home side and then calling a 1–2 away win cannot both land
  assert rejects(u, 8600, '[{"call_type":"winner","team_id":8001},{"call_type":"score","home_goals":1,"away_goals":2}]', '%other side winning%'), 'the result and the scoreline must agree';
  -- three goals is under 3.5, so "over" and that scoreline cannot both land either
  assert rejects(u, 8600, '[{"call_type":"total","yes":true},{"call_type":"score","home_goals":1,"away_goals":2}]', '%over/under disagree%'), 'the goals line and the scoreline must agree';
  -- and the away side laying 1.5 goals does not cover a one-goal win
  assert rejects(u, 8600, '[{"call_type":"spread","team_id":8002},{"call_type":"score","home_goals":1,"away_goals":2}]', '%loses your handicap%'), 'the handicap and the scoreline must agree';
end $$;
-- a save is a full replacement: a call left out of the array is deleted, which is why the app now
-- reads the entry back and shows what the database actually holds
do $$ declare card uuid; begin
  card := play('aaaaaaaa-0000-0000-0000-000000000001', 8600,
    '[{"call_type":"winner","team_id":8002},{"call_type":"scorer","player_id":80021},{"call_type":"yellow","player_id":80011}]');
  assert (select count(*) from calls k join entries e on e.id = k.entry_id where e.card_id = card) = 3, 'three calls in';
  perform test_as('aaaaaaaa-0000-0000-0000-000000000001');
  perform rpc_save_calls(card, '[{"call_type":"scorer","player_id":80021},{"call_type":"yellow","player_id":80011}]');
  perform test_reset();
  assert (select count(*) from calls k join entries e on e.id = k.entry_id where e.card_id = card and k.call_type = 'winner') = 0,
         'a call left out of the save is deleted';
  assert (select count(*) from calls k join entries e on e.id = k.entry_id where e.card_id = card) = 2, 'the rest survive';
end $$;

-- --- the board -------------------------------------------------------------------
do $$ begin
  assert (select (odds->>'draw')::numeric from v_board where match_id = 8000) = 3.6, 'the board carries the prices';
  assert (select count(*) from stickers where competition_code = 'FRI' and call_type = 'red') = 1, 'a sticker for the red';
end $$;

-- --- every call says what it means, and the history reads back ---------------------
do $$ declare h jsonb; c jsonb; begin
  assert (select count(*) from markets where explainer is null or length(explainer) < 30) = 0, 'every market has an explainer';
  assert (select explainer from markets where call_type = 'spread') like 'Your team starts the match with a virtual head start%', 'the handicap explainer';
  perform test_as('aaaaaaaa-0000-0000-0000-000000000001');
  h := my_history(50);
  assert jsonb_array_length(h) >= 5, format('history has cards: %s', jsonb_array_length(h));
  -- the oldest-but-settled Fiji card: the scorer was void, the yellow missed, the result landed
  select x into c from jsonb_array_elements(h) x where (x->>'match_id')::int = 8000;
  assert c is not null, 'the 8000 card is in the history';
  assert c->>'home' = 'Fiji' and (c->>'home_score')::int = 1, 'the history carries the match';
  assert (select count(*) from jsonb_array_elements(c->'calls')) = 3, 'three calls on it';
  assert (select k->>'result' from jsonb_array_elements(c->'calls') k where k->>'call_type' = 'winner') = 'hit', 'the result hit';
  assert (select k->>'label' from jsonb_array_elements(c->'calls') k where k->>'call_type' = 'winner') = 'Fiji', 'and reads as the team name';
  assert (select k->>'result' from jsonb_array_elements(c->'calls') k where k->>'call_type' = 'scorer') = 'void', 'the unused sub is void';
  assert (select k->>'title' from jsonb_array_elements(c->'calls') k where k->>'call_type' = 'red') is null, 'no red on that card';
  perform test_reset();
end $$;

select 'FOOTBALL TESTS PASSED' as result;
rollback;
