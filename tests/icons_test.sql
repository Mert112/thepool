-- Profile icons (0022): ten of them, nine earned, and the rarer the icon the harder the thing.
-- Run on a fresh db after the migrations:  psql pool -f tests/icons_test.sql
-- Every check raises on failure; a clean run prints "ICONS TESTS PASSED".
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
create or replace function has_icon(u text, c text) returns boolean language sql stable as $$
  select exists (select 1 from user_icons where user_id = u::uuid and code = c) $$;
create or replace function wearing(u text) returns text language sql stable as $$
  select icon from profiles where id = u::uuid $$;

\set A '11111111-aaaa-0000-0000-000000000001'
\set B '22222222-bbbb-0000-0000-000000000002'

insert into teams (id, name, sport) values (9001, 'Rovers', 'soccer'), (9002, 'Athletic', 'soccer');
insert into players (id, team_id, name, sport) values (90011, 9001, 'Okafor', 'soccer');

-- --- 1. ten icons, and the rarity climbs with the difficulty ------------------------
do $$ begin
  assert (select count(*) from icons) = 10, 'ten icons';
  assert (select array_agg(rarity order by sort_order) from icons)
       = array['common','common','common','uncommon','uncommon','rare','rare','epic','epic','legendary'],
    'the rarity climbs with the sort order';
  assert (select rarity from icons where code = 'console') = 'legendary', 'the PlayStation is the rarest';
  assert (select rarity from icons where code = 'jackpot') = 'epic', 'a big jackpot is epic';
  assert (select rarity from icons where code = 'watcher') = 'uncommon', 'a pile of ads is only uncommon';
  assert (select rarity from icons where code = 'rookie') = 'common', 'and the football is free';
  assert (select count(*) from icons where how is null or length(how) < 10) = 0, 'each one says how to get it';
  assert (select count(distinct glyph) from icons) = 10, 'and each one looks different';
end $$;

-- --- 2. a new account holds the football, and wears it -------------------------------
do $$ begin
  assert has_icon('11111111-aaaa-0000-0000-000000000001', 'rookie'), 'Ana has the football';
  assert wearing('11111111-aaaa-0000-0000-000000000001') = 'rookie', 'and is wearing it';
  assert (select count(*) from user_icons where user_id = '11111111-aaaa-0000-0000-000000000001') = 1, 'and nothing else';
end $$;

-- --- 3. you cannot wear what you have not earned --------------------------------------
do $$ begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  begin
    perform rpc_set_icon('console');
    raise exception 'a legendary icon was worn without earning it';
  exception when others then if sqlerrm not like '%not unlocked%' then raise; end if; end;
  assert wearing('11111111-aaaa-0000-0000-000000000001') = 'rookie', 'still the football';
  perform test_reset();
end $$;

-- --- 4. the scarf: join a crew ---------------------------------------------------------
do $$ declare code text; begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  perform rpc_create_crew('Desk XI', 'CL nights', 'complex');
  perform test_reset();
  assert has_icon('11111111-aaaa-0000-0000-000000000001', 'crew'), 'making a crew earns the scarf';
  select invite_code into code from crews limit 1;
  perform test_as('22222222-bbbb-0000-0000-000000000002');
  perform rpc_join_crew(code);
  perform test_reset();
  assert has_icon('22222222-bbbb-0000-0000-000000000002', 'crew'), 'and so does joining one';
end $$;

-- --- 5. and now you can wear it ---------------------------------------------------------
do $$ begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  perform rpc_set_icon('crew');
  perform test_reset();
  assert wearing('11111111-aaaa-0000-0000-000000000001') = 'crew', 'Ana is wearing the scarf';
end $$;

-- --- 6. the set: fifty ads ---------------------------------------------------------------
do $$ begin
  -- ten a day is the cap, so fifty is five days; the days are written straight in
  for d in 1..5 loop
    for i in 1..10 loop
      insert into ad_views (user_id, day, seq, reward)
      values ('11111111-aaaa-0000-0000-000000000001', (now() at time zone 'utc')::date - d, i, 0.5);
    end loop;
  end loop;
  assert not has_icon('11111111-aaaa-0000-0000-000000000001', 'watcher'), 'not until it is counted';
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  perform rpc_refresh_icons();
  perform test_reset();
  assert has_icon('11111111-aaaa-0000-0000-000000000001', 'watcher'), 'fifty ads earns the set';
  assert not has_icon('22222222-bbbb-0000-0000-000000000002', 'watcher'), 'and Ben watched none';
end $$;

-- --- 7. the bag: hold 500 at once ---------------------------------------------------------
do $$ begin
  assert not has_icon('11111111-aaaa-0000-0000-000000000001', 'banker'), 'not on 100';
  perform apply_ledger('11111111-aaaa-0000-0000-000000000001', 'adjustment', 'test-rich', 400);
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  perform rpc_refresh_icons();
  perform test_reset();
  assert has_icon('11111111-aaaa-0000-0000-000000000001', 'banker'), '500 points earns the bag';
end $$;

-- --- 8. the eight ball: call an exact scoreline and watch it come in ------------------------
insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, odds) values
  (9600, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, '{}');
do $$ declare card uuid; begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  card := rpc_open_card(9600, 'complex', null);
  perform rpc_save_calls(card, '[{"call_type":"score","home_goals":2,"away_goals":1,"stake":5}]');
  perform test_reset();
  assert not has_icon('11111111-aaaa-0000-0000-000000000001', 'sniper'), 'not for calling it';
end $$;
update matches set utc_date = now() - interval '1 minute' where id = 9600;
select sync_card_status();
update matches set status = 'FINISHED', utc_date = now() - interval '3 hours', home_score = 2, away_score = 1,
       ft_home = 2, ft_away = 1, duration = 'REGULAR', provider_updated = now() where id = 9600;
select process_match_updates();
do $$ begin
  assert has_icon('11111111-aaaa-0000-0000-000000000001', 'sniper'), 'landing it earns the eight ball';
  -- settlement awards without being asked
  assert (select result from calls k join entries e on e.id = k.entry_id join cards c on c.id = e.card_id
          where c.match_id = 9600) = 'hit', 'the scoreline landed';
end $$;

-- --- 9. the machine and the whale: a big jackpot share, and a big pot share -----------------
do $$ declare k uuid; begin
  select c.id into k from calls c join entries e on e.id = c.entry_id join cards cd on cd.id = e.card_id
   where cd.match_id = 9600;
  assert not has_icon('11111111-aaaa-0000-0000-000000000001', 'jackpot'), 'not yet';
  perform apply_ledger('11111111-aaaa-0000-0000-000000000001', 'jackpot', k::text || ':test', 120);
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  perform rpc_refresh_icons();
  perform test_reset();
  assert has_icon('11111111-aaaa-0000-0000-000000000001', 'jackpot'), 'a 120-point jackpot share earns the machine';
  assert not has_icon('11111111-aaaa-0000-0000-000000000001', 'whale'), 'but the whale wants a pot';
  perform apply_ledger('11111111-aaaa-0000-0000-000000000001', 'pot', k::text || ':test2', 250);
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  perform rpc_refresh_icons();
  perform test_reset();
  assert has_icon('11111111-aaaa-0000-0000-000000000001', 'whale'), '250 out of one pot earns the whale';
end $$;

-- --- 10. a near miss earns nothing -----------------------------------------------------------
do $$ declare k uuid; begin
  select c.id into k from calls c join entries e on e.id = c.entry_id join cards cd on cd.id = e.card_id
   where cd.match_id = 9600;
  perform apply_ledger('22222222-bbbb-0000-0000-000000000002', 'jackpot', k::text || ':ben', 99.99);
  perform test_as('22222222-bbbb-0000-0000-000000000002');
  perform rpc_refresh_icons();
  perform test_reset();
  assert not has_icon('22222222-bbbb-0000-0000-000000000002', 'jackpot'), '99.99 is not 100';
end $$;

-- --- 11. the console: claim the PlayStation ---------------------------------------------------
do $$ begin
  perform apply_ledger('11111111-aaaa-0000-0000-000000000001', 'adjustment', 'test-million', 1000000);
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  perform rpc_claim_prize();
  perform test_reset();
  assert has_icon('11111111-aaaa-0000-0000-000000000001', 'console'), 'claiming the PlayStation earns the console';
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  perform rpc_set_icon('console');
  perform test_reset();
  assert wearing('11111111-aaaa-0000-0000-000000000001') = 'console', 'and she wears it';
end $$;

-- --- 12. the clipboard: five cards played out --------------------------------------------------
do $$ declare card uuid; begin
  for n in 1..5 loop
    insert into matches (id, competition_code, sport, season, utc_date, status, home_team_id, away_team_id, odds)
    values (9700 + n, 'PL', 'soccer', '2026', now() + interval '2 hours', 'TIMED', 9001, 9002, '{}');
    perform test_as('22222222-bbbb-0000-0000-000000000002');
    card := rpc_open_card(9700 + n, 'complex', null);
    perform rpc_save_calls(card, '[{"call_type":"winner","team_id":9001,"stake":1}]');
    perform test_reset();
    update matches set utc_date = now() - interval '1 minute' where id = 9700 + n;
    perform sync_card_status();
    update matches set status = 'FINISHED', utc_date = now() - interval '3 hours', home_score = 1, away_score = 0,
           ft_home = 1, ft_away = 0, duration = 'REGULAR', provider_updated = now() where id = 9700 + n;
    perform process_match_updates();
    if n < 5 then assert not has_icon('22222222-bbbb-0000-0000-000000000002', 'regular'), format('not after %s cards', n); end if;
  end loop;
  assert has_icon('22222222-bbbb-0000-0000-000000000002', 'regular'), 'five cards earns the clipboard';
end $$;

-- --- 13. awarding twice awards nothing twice ----------------------------------------------------
do $$ declare before int; begin
  select count(*) into before from user_icons;
  perform award_icons('11111111-aaaa-0000-0000-000000000001');
  perform award_icons('11111111-aaaa-0000-0000-000000000001');
  perform award_icons('22222222-bbbb-0000-0000-000000000002');
  assert (select count(*) from user_icons) = before, 'nothing is earned twice';
end $$;

-- --- 14. my_icons shows the locked ones and how to get them ----------------------------------------
do $$ declare locked int; begin
  perform test_as('22222222-bbbb-0000-0000-000000000002');
  assert (select count(*) from my_icons()) = 10, 'all ten are listed';
  select count(*) into locked from my_icons() where earned_at is null;
  assert locked > 0, 'with the ones Ben has not earned still locked';
  assert (select count(*) from my_icons() where wearing) = 1, 'and exactly one is being worn';
  assert (select how from my_icons() where code = 'console') like '%PlayStation%', 'the locked ones say what it takes';
  perform test_reset();
end $$;

-- --- 15. the icon travels with the name ------------------------------------------------------------
do $$ begin
  perform test_as('11111111-aaaa-0000-0000-000000000001');
  assert (select icon from leaderboard('overall') where user_id = '11111111-aaaa-0000-0000-000000000001') = 'console',
    'the table carries the icon';
  perform test_reset();
  assert has_table_privilege('authenticated', 'pool.user_icons', 'insert') = false, 'the client cannot award itself an icon';
  assert has_function_privilege('authenticated', 'pool.award_icons(uuid)', 'execute') = false, 'nor call the awarder';
  assert has_column_privilege('authenticated', 'pool.profiles', 'icon', 'update') = false, 'nor set the column directly';
end $$;

-- --- 16. an uploaded picture (0031): only from your own folder, and only through the RPC ------------
do $$ declare ana text := '11111111-aaaa-0000-0000-000000000001'; begin
  perform test_as(ana);
  begin perform rpc_set_avatar('22222222-bbbb-0000-0000-000000000002/1.jpg'); raise exception 'Ana wore Ben''s picture';
  exception when others then if sqlerrm not like '%your own folder%' then raise; end if; end;
  begin perform rpc_set_avatar(ana || '/../x.jpg'); raise exception 'a path escaped the folder';
  exception when others then if sqlerrm not like '%your own folder%' then raise; end if; end;
  perform rpc_set_avatar(ana || '/1730000000000.jpg');
  assert (select avatar_path from leaderboard('overall') where user_id = ana::uuid) = ana || '/1730000000000.jpg',
    'the table carries the picture';
  perform rpc_set_avatar(null);
  assert (select avatar_path from profiles where id = ana::uuid) is null, 'and it can be taken off';
  perform test_reset();
  assert has_column_privilege('authenticated', 'pool.profiles', 'avatar_path', 'select'), 'everybody sees the picture';
  assert has_column_privilege('authenticated', 'pool.profiles', 'avatar_path', 'update') = false, 'nobody sets it directly';
  assert has_function_privilege('anon', 'pool.rpc_set_avatar(text)', 'execute') = false, 'and a visitor cannot call the RPC';
end $$;

select 'ICONS TESTS PASSED' as result;
rollback;
