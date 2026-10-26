-- Three languages (0023): the choice lives on the profile, and a call travels as pieces rather
-- than as an English sentence so it can be said in any of them.
-- Run on a fresh local db:  psql pool -f tests/i18n_test.sql
-- Every check raises on failure; a clean run prints "I18N TESTS PASSED".
\set ON_ERROR_STOP on
begin;
set search_path = pool, public;

insert into teams (id, name, short_name, tla) values (57, 'Arsenal', 'Arsenal', 'ARS'), (64, 'Liverpool', 'Liverpool', 'LIV');
insert into players (id, team_id, name) values (1, 57, 'Saka'), (5, 64, 'Salah');
insert into matches (id, competition_code, season, utc_date, status, home_team_id, away_team_id, total_line)
  values (1000, 'PL', '2026', now() + interval '2 hours', 'TIMED', 57, 64, 2.5);
update matches set odds = '{"provider":"test","spread":{"home_line":-1,"home":1.9,"away":1.9}}'::jsonb where id = 1000;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'mina@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'tobias@example.com');

create or replace function test_as(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true), set_config('role', 'authenticated', true);
$$;
create or replace function test_reset() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', true), set_config('role', 'postgres', true);
$$;

\set A '11111111-1111-1111-1111-111111111111'
\set B '22222222-2222-2222-2222-222222222222'

-- --- 1. a new account has not chosen, and that is not English -------------------------------
-- Null is the signal the app needs: it means "take the browser's word for it and save that".
-- A default of 'en' would silently overrule a Turkish browser for everyone who ever signs up.
do $$ begin
  assert (select count(*) from profiles where language is null) = 2, 'nobody has chosen a language yet';
end $$;

-- --- 2. the column takes the three languages and nothing else -------------------------------
do $$ declare l text; begin
  foreach l in array array['en', 'tr', 'bg'] loop
    update profiles set language = l where id = '11111111-1111-1111-1111-111111111111';
    assert (select language from profiles where id = '11111111-1111-1111-1111-111111111111') = l, 'the column takes ' || l;
  end loop;
  begin
    update profiles set language = 'de' where id = '11111111-1111-1111-1111-111111111111';
    raise exception 'a language we do not speak was accepted';
  exception when check_violation then null; end;
  update profiles set language = null where id = '11111111-1111-1111-1111-111111111111';
end $$;

-- --- 3. rpc_set_language sets your own, and only yours ---------------------------------------
do $$ begin
  perform test_as('11111111-1111-1111-1111-111111111111');
  perform rpc_set_language('tr');
  perform test_reset();
  assert (select language from profiles where id = '11111111-1111-1111-1111-111111111111') = 'tr', 'Mina is reading Turkish';
  assert (select language from profiles where id = '22222222-2222-2222-2222-222222222222') is null, 'and nobody else moved';

  perform test_as('22222222-2222-2222-2222-222222222222');
  perform rpc_set_language('bg');
  perform test_reset();
  assert (select language from profiles where id = '22222222-2222-2222-2222-222222222222') = 'bg', 'Tobias is reading Bulgarian';
  assert (select language from profiles where id = '11111111-1111-1111-1111-111111111111') = 'tr', 'and Mina is still in Turkish';
end $$;

-- --- 4. and refuses anything else ------------------------------------------------------------
do $$ begin
  perform test_as('11111111-1111-1111-1111-111111111111');
  begin
    perform rpc_set_language('de');
    raise exception 'a language we do not speak was accepted';
  exception when others then if sqlerrm not like '%unknown language%' then raise; end if; end;
  begin
    perform rpc_set_language(null);
    raise exception 'null was accepted as a language';
  exception when others then if sqlerrm not like '%unknown language%' then raise; end if; end;
  assert (select language from profiles where id = '11111111-1111-1111-1111-111111111111') = 'tr', 'the choice survived both';
  perform test_reset();
end $$;

-- --- 5. the client cannot write the column round the back, and must be signed in -------------
do $$ begin
  assert has_column_privilege('authenticated', 'pool.profiles', 'language', 'update') = false, 'no direct update';
  assert has_column_privilege('authenticated', 'pool.profiles', 'language', 'select') = true, 'but the app can read it';
  assert has_function_privilege('anon', 'pool.rpc_set_language(text)', 'execute') = false, 'signed out, nothing to set';
  assert has_function_privilege('authenticated', 'pool.rpc_set_language(text)', 'execute') = true, 'signed in, your own';
end $$;

-- --- fixtures: one card, every kind of call ---------------------------------------------------
select test_as(:'A');
select rpc_set_display_name('Mina');
select rpc_open_card(1000, 'complex', null) as card_id \gset
select rpc_save_calls(:'card_id', '[
  {"call_type":"winner","team_id":57,"stake":10},
  {"call_type":"total","yes":true,"stake":5},
  {"call_type":"spread","team_id":57,"stake":5},
  {"call_type":"scorer","player_id":1,"stake":2},
  {"call_type":"red","player_id":5,"pick":"76-90","stake":1}
]'::jsonb);
select test_reset();

-- --- 6. call_parts hands over the pieces, not a sentence ---------------------------------------
-- Names come from the provider and are passed through exactly; everything else is a key or a
-- number, so the app can put its own words round them.
do $$ declare p jsonb; m matches; begin
  select * into m from matches where id = 1000;

  select call_parts(c, m) into p from calls c join entries e on e.id = c.entry_id
    where e.card_id = (select id from cards where match_id = 1000) and c.call_type = 'winner';
  assert p->>'call_type' = 'winner', 'the result call says so';
  assert p->>'team' = 'Arsenal', 'and carries the team name as the provider gave it';
  assert p->>'side' = 'home', 'and which side that is';
  assert p ? 'pick' = false, 'with no draw marker on a team pick';

  select call_parts(c, m) into p from calls c join entries e on e.id = c.entry_id
    where e.card_id = (select id from cards where match_id = 1000) and c.call_type = 'total';
  assert (p->>'yes')::boolean = true, 'over, not under';
  assert p->>'line' = '2.5', 'against the line as a number, with no "Over" glued to it';
  assert p->>'call_type' = 'total', 'and the call type to read it by';

  select call_parts(c, m) into p from calls c join entries e on e.id = c.entry_id
    where e.card_id = (select id from cards where match_id = 1000) and c.call_type = 'spread';
  assert p->>'team' = 'Arsenal' and p->>'line' = '-1', 'the handicap keeps its sign but not its "+"';

  select call_parts(c, m) into p from calls c join entries e on e.id = c.entry_id
    where e.card_id = (select id from cards where match_id = 1000) and c.call_type = 'scorer';
  assert p->>'player' = 'Saka', 'the goalscorer is a name, untranslated';
  assert p ? 'team' = false, 'and nothing else is invented for it';

  select call_parts(c, m) into p from calls c join entries e on e.id = c.entry_id
    where e.card_id = (select id from cards where match_id = 1000) and c.call_type = 'red';
  assert p->>'player' = 'Salah' and p->>'pick' = '76-90', 'the red card keeps its window';
end $$;

-- --- 7. nothing in the pieces is English prose --------------------------------------------------
-- The whole point: if a word that only means something in English leaks into the data, the
-- Turkish and Bulgarian screens quietly go half-English.
do $$ declare bad int; m matches; begin
  select * into m from matches where id = 1000;
  select count(*) into bad from calls c join entries e on e.id = c.entry_id, lateral (select call_parts(c, m) as p) x
   where e.card_id = (select id from cards where match_id = 1000)
     and (x.p::text ilike '%Over %' or x.p::text ilike '%Under %' or x.p::text ilike '%Draw%'
          or x.p::text ilike '%level at%' or x.p::text ilike '%someone wins%');
  assert bad = 0, 'the pieces carry no English';
end $$;

-- --- 8. the crowd split carries the pieces beside the English -----------------------------------
do $$ declare r record; begin
  perform test_as('11111111-1111-1111-1111-111111111111');
  select * into r from card_crowd((select id from cards where match_id = 1000)) where call_type = 'total';
  assert r.parts is not null, 'the crowd split carries the pieces';
  assert (r.parts->>'yes')::boolean = true and r.parts->>'line' = '2.5', 'and they describe the pick';
  assert r.label = 'Over 2.5', 'the English is still there for anything that has not been moved over';
  assert r.n = 1, 'one person is on it';

  select * into r from card_crowd((select id from cards where match_id = 1000)) where call_type = 'winner';
  assert r.parts->>'team' = 'Arsenal', 'and a team name survives the trip';
  perform test_reset();
end $$;

-- --- 9. so does the prediction history ------------------------------------------------------------
do $$ declare h jsonb; c jsonb; begin
  perform test_as('11111111-1111-1111-1111-111111111111');
  select my_history(10) into h;
  assert jsonb_array_length(h) = 1, 'one card in the history';
  select x into c from jsonb_array_elements(h->0->'calls') x where x->>'call_type' = 'scorer';
  assert c->'parts'->>'player' = 'Saka', 'the history carries the pieces too';
  assert c->>'label' = 'Saka', 'and the English alongside';
  select x into c from jsonb_array_elements(h->0->'calls') x where x->>'call_type' = 'red';
  assert c->'parts'->>'pick' = '76-90', 'window and all';
  perform test_reset();
end $$;

-- --- 10. the pieces are the server's to build, not the client's -------------------------------------
do $$ begin
  assert has_function_privilege('authenticated', 'pool.call_parts(pool.calls, pool.matches)', 'execute') = false,
    'the client cannot read other people''s calls through call_parts';
  assert has_function_privilege('anon', 'pool.card_crowd(uuid)', 'execute') = false, 'nor the crowd split signed out';
  assert has_function_privilege('authenticated', 'pool.card_crowd(uuid)', 'execute') = true, 'signed in, yes';
end $$;

select 'I18N TESTS PASSED' as result;
rollback;
