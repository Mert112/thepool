-- One provider (0024): the request budget, the league catalogue, who follows what, which
-- fixtures are worth a request, and the rule that a call nobody can judge is void.
-- Run on a fresh local db:  psql pool -f tests/provider_test.sql
-- Every check raises on failure; a clean run prints "PROVIDER TESTS PASSED".
\set ON_ERROR_STOP on
begin;
set search_path = pool, public;

insert into teams (id, name, af_id) values (7001, 'Alanyaspor', 996), (7002, 'Kocaelispor', 7411);
insert into players (id, team_id, name, af_id) values (70011, 7001, 'Paulo Victor', 10476), (70021, 7002, 'B. Kutlu', 264627);
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

-- --- 1. the budget is the database's, not the script's -------------------------------------
do $$ declare b int; begin
  b := (select (value->>'daily_budget')::int from config where key = 'football_api');
  assert b = 7000, format('the budget is 7,000, not %s', b);
  assert (select count(*) from api_usage) = 0, 'nothing spent yet';
  assert api_left() = 7000, 'and all of it is left';

  assert api_take(10, 'fixtures'), 'ten requests fit';
  assert (select requests from api_usage where day = (now() at time zone 'utc')::date) = 10, 'and are counted';
  assert api_left() = 6990, 'leaving the rest';
  assert (select (detail->>'fixtures')::int from api_usage) = 10, 'counted by kind, so a pass can be read afterwards';

  assert api_take(5, 'live'), 'five more';
  assert (select (detail->>'live')::int from api_usage) = 5, 'under their own kind';
  assert (select requests from api_usage) = 15, 'and on the same total';
end $$;

-- --- 2. a request that would bust the budget is refused, and spends nothing -------------------
do $$ begin
  update api_usage set requests = 6999 where day = (now() at time zone 'utc')::date;
  assert api_take(1, 'live'), 'the last one fits exactly';
  assert (select requests from api_usage) = 7000, 'and takes the budget to the line';
  assert api_left() = 0, 'nothing left';
  assert not api_take(1, 'live'), 'the next is refused';
  assert (select requests from api_usage) = 7000, 'and nothing was spent on it';
  assert not api_take(500, 'fixtures'), 'a batch that cannot fit is refused whole';
  assert (select requests from api_usage) = 7000, 'still nothing';
  -- asking for nothing is not an error, and costs nothing
  assert api_take(0, 'live'), 'zero is free';
  update api_usage set requests = 0, detail = '{}'::jsonb where day = (now() at time zone 'utc')::date;
end $$;

-- --- 3. the budget is per UTC day ---------------------------------------------------------------
do $$ begin
  insert into api_usage (day, requests, budget) values ((now() at time zone 'utc')::date - 1, 7000, 7000);
  assert api_left() = 7000, 'yesterday''s spend is yesterday''s problem';
  assert api_take(1, 'live'), 'and today starts clear';
  delete from api_usage where day = (now() at time zone 'utc')::date - 1;
  update api_usage set requests = 0 where day = (now() at time zone 'utc')::date;
end $$;

-- --- 4. the catalogue lands, and a hand-written competition keeps its name -----------------------
do $$ declare c text; begin
  c := upsert_league(203, 'Süper Lig', 'League', 'logo.png', 'Turkey', 'TR', 'flag.svg', 2026, true, true);
  assert c = 'TR1', format('an existing competition keeps its code, got %s', c);
  assert (select name from competitions where code = 'TR1') = 'Süper Lig', 'and its name';
  assert (select country from competitions where code = 'TR1') = 'Turkey', 'the country comes from the provider';
  assert (select type from competitions where code = 'TR1') = 'league', 'and the type, lower-cased';
  assert (select has_events from competitions where code = 'TR1'), 'and whether it covers events';

  c := upsert_league(318, 'Cypriot First Division', 'League', null, 'Cyprus', 'CY', 'cy.svg', 2026, true, false);
  assert c = 'AF318', format('a new one is AF<id>, got %s', c);
  assert (select name from competitions where code = 'AF318') = 'Cypriot First Division', 'with the provider''s name';
  assert not (select active from competitions where code = 'AF318'), 'and nobody follows it, so it costs nothing';
  assert (select count(*) from competitions where af_league_id = 318) = 1, 'one row per league';

  -- the same league again is an update, not a second row
  c := upsert_league(318, 'Cyprus First Division', 'League', null, 'Cyprus', 'CY', 'cy.svg', 2027, true, false);
  assert (select count(*) from competitions where af_league_id = 318) = 1, 'still one row';
  assert (select season_year from competitions where code = 'AF318') = 2027, 'with the newer season';
end $$;

-- --- 5. the defaults are the twelve, plus the national-team competitions -------------------------
do $$ declare n int; begin
  assert (select count(*) from competitions where default_follow and code in
    ('TR1','TR2','TRC','CL','UEL','UECL','PL','PD','SA','BL1','FL1','BG1')) = 12,
    'the twelve club competitions are on by default';
  assert (select count(*) from competitions where default_follow and team_filter is not null) = 5,
    'and the national-team ones, for two sides only';
  assert (select team_filter from competitions where code = 'WCQE') = array[777, 1103],
    'Türkiye and Bulgaria, nobody else in the group';
  assert (select tier from competitions where code = 'TR2') = 2, '1. Lig is the second tier';
  assert (select tier from competitions where code = 'TR1') = 1, 'the Süper Lig the first';
  assert (select type from competitions where code = 'TRC') = 'cup', 'and the cup is a cup';
  -- only what is followed is synced
  select count(*) into n from competitions where active and not default_follow;
  assert n = 0, format('%s competitions are active that nobody follows', n);
end $$;

-- --- 6. a new account starts on the defaults ------------------------------------------------------
do $$ declare d int; begin
  select count(*) into d from competitions where default_follow;
  assert (select count(*) from competition_follows where user_id = '11111111-1111-1111-1111-111111111111') = d,
    'a new account follows every default';
  assert exists (select 1 from competition_follows where user_id = '11111111-1111-1111-1111-111111111111' and competition_code = 'TR1'),
    'including the Süper Lig';
  assert not exists (select 1 from competition_follows where user_id = '11111111-1111-1111-1111-111111111111' and competition_code = 'AF318'),
    'and nothing from "More leagues"';
end $$;

-- --- 7. following one turns the sync on for it, and it reads back ------------------------------------
do $$ declare j jsonb; begin
  perform test_as('11111111-1111-1111-1111-111111111111');
  perform rpc_follow_competition('AF318');
  perform test_reset();
  assert (select active from competitions where code = 'AF318'), 'a followed league is synced';

  perform test_as('11111111-1111-1111-1111-111111111111');
  select my_competitions() into j;
  assert (select count(*) from jsonb_array_elements(j->'following') x where x->>'code' = 'AF318') = 1,
    'and shows up in what I follow';
  select competitions_in('Cyprus') into j;
  assert (j->0->>'following')::boolean, 'and "More leagues" says so too';
  perform test_reset();
end $$;

-- --- 8. unfollowing turns it off again, unless somebody else is still on it --------------------------
do $$ begin
  perform test_as('22222222-2222-2222-2222-222222222222');
  perform rpc_follow_competition('AF318');
  perform test_reset();
  perform test_as('11111111-1111-1111-1111-111111111111');
  perform rpc_unfollow_competition('AF318');
  perform test_reset();
  assert (select active from competitions where code = 'AF318'), 'Tobias still follows it';

  perform test_as('22222222-2222-2222-2222-222222222222');
  perform rpc_unfollow_competition('AF318');
  perform test_reset();
  assert not (select active from competitions where code = 'AF318'), 'now nobody does, so it stops costing requests';

  -- a default cannot be switched off for everyone by one person leaving it
  perform test_as('11111111-1111-1111-1111-111111111111');
  perform rpc_unfollow_competition('TR1');
  perform test_reset();
  assert (select active from competitions where code = 'TR1'), 'a default stays synced';
end $$;

-- --- 9. following is your own business --------------------------------------------------------------
do $$ begin
  assert has_table_privilege('authenticated', 'pool.competition_follows', 'insert') = false, 'no direct insert';
  assert has_table_privilege('authenticated', 'pool.competition_follows', 'delete') = false, 'no direct delete';
  assert has_function_privilege('anon', 'pool.rpc_follow_competition(text)', 'execute') = false, 'signed out, nothing to follow';
  assert has_function_privilege('anon', 'pool.api_take(int, text)', 'execute') = false, 'and the budget is not the client''s';
  assert has_function_privilege('authenticated', 'pool.api_take(int, text)', 'execute') = false, 'nor a signed-in client''s';
  assert has_function_privilege('authenticated', 'pool.sync_live_fixtures()', 'execute') = false, 'nor the sync''s work list';
end $$;

-- --- fixtures for the rest ----------------------------------------------------------------------------
insert into matches (id, competition_code, season, utc_date, status, home_team_id, away_team_id, af_fixture_id)
values (8100, 'TR1', '2026', now() + interval '2 hours', 'TIMED', 7001, 7002, 1584439),      -- not started
       (8101, 'TR1', '2026', now() + interval '2 hours', 'TIMED', 7001, 7002, 1584441),      -- Mina's card goes on this one
       (8102, 'TR1', '2026', now() - interval '1 hour',  'IN_PLAY', 7002, 7001, 1584443),     -- in play, nobody on it
       (8103, 'TR1', '2026', now() - interval '3 hours', 'TIMED', 7001, 7002, 1584445);       -- kicked off, no word since

-- a card, filled before kick-off, then the match goes in play
select test_as(:'A');
select rpc_set_display_name('Mina');
select rpc_open_card(8101, 'complex', null) as c1 \gset
select rpc_save_calls(:'c1', '[{"call_type":"scorer","player_id":70011,"stake":10},
                               {"call_type":"winner","team_id":7001,"stake":10}]'::jsonb);
select test_reset();
update matches set utc_date = now() - interval '1 hour', status = 'IN_PLAY' where id = 8101;
select sync_card_status();

-- --- 9b. the operational tables are not the client's ---------------------------------------------
-- The schema grants select on a new table to anon by default (0003). `0022` was caught by it
-- once; this is the check that catches it next time.
do $$ begin
  assert (select relrowsecurity from pg_class where oid = 'pool.api_usage'::regclass), 'the spend counter is behind RLS';
  assert (select count(*) from information_schema.role_table_grants
           where table_schema = 'pool' and table_name = 'api_usage' and grantee in ('anon','authenticated')) = 0,
    'and nobody outside the server can read it';
  assert (select relrowsecurity from pg_class where oid = 'pool.config'::regclass), 'config is too';
  assert (select count(*) from config where public) = 0, 'and nothing in it is public yet';
  assert (select count(*) from information_schema.role_table_grants
           where table_schema = 'pool' and table_name = 'config'
             and grantee in ('anon','authenticated') and privilege_type <> 'SELECT') = 0,
    'and no client can write it';
end $$;

-- --- 10. a minute-by-minute look costs a request, so only matches somebody is playing get one -----------
do $$ begin
  assert (select count(*) from sync_live_fixtures()) = 1, 'one live match has a card on it';
  assert (select fixture_id from sync_live_fixtures()) = 1584441, 'and it is that one';
  assert not exists (select 1 from sync_live_fixtures() where match_id = 8102),
    'a live match nobody is playing is not worth a request a minute';
  assert not exists (select 1 from sync_live_fixtures() where match_id = 8100), 'nor one that has not kicked off';
end $$;

-- --- 11. everything else gets one look after the whistle -------------------------------------------------
do $$ begin
  assert exists (select 1 from sync_result_checks() where match_id = 8103),
    'a match that kicked off and went quiet is checked once';
  assert not exists (select 1 from sync_result_checks() where match_id = 8100),
    'a fixture that has not started is not';
  update matches set status = 'FINISHED', home_score = 1, away_score = 0, settled_at = now() where id = 8103;
  assert not exists (select 1 from sync_result_checks() where match_id = 8103),
    'and once it is settled it is never asked for again';
end $$;

-- --- 11b. odds are asked for once, not once a minute ------------------------------------------
-- A fixture nobody has priced yet is the normal case the day before. Asking again every minute
-- cost eight requests a minute and learned nothing — 11,500 a day against a budget of 7,000.
do $$ begin
  assert exists (select 1 from sync_odds_needs() where match_id = 8100), 'an unpriced fixture tomorrow is worth asking about';
  update matches set odds_checked_at = now() where id = 8100;
  assert not exists (select 1 from sync_odds_needs() where match_id = 8100), 'but only once';
  update matches set odds_checked_at = now() - interval '7 hours' where id = 8100;
  assert exists (select 1 from sync_odds_needs() where match_id = 8100), 'and again six hours later';
  update matches set odds = '{"provider":"Book","home":1.9}'::jsonb where id = 8100;
  assert not exists (select 1 from sync_odds_needs() where match_id = 8100), 'once priced, never again';
end $$;

-- --- 12. a player call nobody can judge is void, not a miss ------------------------------------------------
-- The provider covers events for most leagues and not all, and a feed can fail. Before this, a
-- goalscorer call on a match whose events never arrived was scored a miss and the stake was lost.
do $$ declare e uuid; begin
  update matches set utc_date = now() - interval '3 hours' where id = 8101;
  update matches set status = 'FINISHED', home_score = 1, away_score = 0, ft_home = 1, ft_away = 0,
                     provider_updated = now() where id = 8101;
  assert (select detail_at from matches where id = 8101) is null, 'the provider never sent the detail';
  perform settle_match(8101, true);

  select id into e from entries where card_id = (select id from cards where match_id = 8101);
  assert (select result from calls where entry_id = e and call_type = 'scorer') = 'void',
    'the goalscorer call is void: nobody can say whether it was right';
  assert (select result from calls where entry_id = e and call_type = 'winner') = 'hit',
    'but the result is on the scoreline, and still stands';
  -- void means the stake comes back, which is what the ledger has to show
  assert (select coalesce(sum(amount), 0) from ledger
           where reason = 'refund' and reference = (select id::text from calls where entry_id = e and call_type = 'scorer')) = 10,
    'and the ten points are handed back';
end $$;

-- --- 13. with the detail in hand, the same call is judged normally --------------------------------------------
do $$ declare e uuid; begin
  -- the line-ups arriving is what stamps detail_at, so this is the sync writing one row
  insert into player_stats values (8101, 70011, 'app', 1), (8101, 70021, 'app', 1);
  assert (select detail_at from matches where id = 8101) is not null, 'writing the line-ups stamps the coverage';
  update matches set provider_updated = now() + interval '1 second' where id = 8101;
  perform resettle_match(8101);
  select id into e from entries where card_id = (select id from cards where match_id = 8101);
  assert (select result from calls where entry_id = e and call_type = 'scorer') = 'miss',
    'he played and did not score, so now it is a miss';
end $$;

-- --- 14. the 90-minute rule is untouched -------------------------------------------------------------------
do $$ begin
  insert into match_events (match_id, type, minute, injury_time, team_id, player_id, provider_key)
  values (8101, 'goal', 90, 3, 7001, 70011, 'a'), (8101, 'goal', 97, null, 7001, 70021, 'b');
  assert (select counts from match_events where provider_key = 'a'), '90+3 counts';
  assert not (select counts from match_events where provider_key = 'b'), '97 does not';
end $$;

select 'PROVIDER TESTS PASSED' as result;
rollback;
