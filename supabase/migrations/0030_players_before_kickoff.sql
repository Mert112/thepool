-- The Pool — the players are there to pick before the match, not after.
--
-- Squads came in at forty teams a day, oldest-checked first. The board carries about three
-- hundred teams, so half of them had never been fetched, and a match an hour away usually had
-- nobody to pick for a goalscorer, an assist or a card. Two changes, with the sync script:
--
--   · `sync_squads()` now orders teams by their next kick-off, soonest first, and the script asks
--     for a batch every minute instead of once a day. A team is still fetched at most once a day
--   · `sync_prematch_fixtures()` lists the fixtures kicking off in the next ninety minutes, so the
--     script can ask for their line-ups as soon as the provider publishes them. Those players are
--     added to the squads only; nothing is written that settlement reads (`player_stats`), which
--     still comes from the in-play and full-time passes
set search_path = pool, public, extensions;

create or replace function sync_squads(p_limit int default 40)
returns table (team_id int, af_id int, name text)
language sql stable security definer set search_path = pool, public, extensions as $$
  select t.id, t.af_id, t.name
    from teams t
    join lateral (
      select min(m.utc_date) as next_kickoff
        from matches m join competitions c on c.code = m.competition_code
       where (m.home_team_id = t.id or m.away_team_id = t.id)
         and c.active
         and m.utc_date between now() - interval '1 day' and now() + interval '8 days'
    ) nx on nx.next_kickoff is not null
   where t.af_id is not null
     and (t.roster_checked_at is null or t.roster_checked_at < now() - interval '1 day')
   order by (t.roster_checked_at is not null), nx.next_kickoff, t.id
   limit greatest(1, p_limit);
$$;

create or replace function sync_prematch_fixtures() returns table (match_id int, fixture_id int)
language sql stable security definer set search_path = pool, public, extensions as $$
  select m.id, m.af_fixture_id
    from matches m join competitions c on c.code = m.competition_code
   where m.af_fixture_id is not null and c.active
     and m.status in ('SCHEDULED', 'TIMED')
     and m.utc_date between now() and now() + interval '90 minutes'
   order by m.utc_date;
$$;

revoke execute on function sync_squads(int), sync_prematch_fixtures() from public, anon, authenticated;
grant execute on function sync_squads(int), sync_prematch_fixtures() to service_role;
