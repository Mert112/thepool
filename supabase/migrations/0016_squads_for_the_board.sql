-- The Pool — load squads for every team-sport game on the board (8 days out), not just the next 36 hours:
-- cards open days ahead, and a player call needs the squad. Carded games still go first, then by kickoff.
set search_path = pool, public, extensions;

create or replace function sync_roster_needs(p_limit int default 25)
returns table (team_id int, espn_key text, espn_path text)
language sql stable security definer set search_path = pool, public, extensions as $$
  with upcoming as (
    select m.competition_code, m.utc_date, x.team_id,
           exists (select 1 from cards c where c.match_id = m.id) as carded
    from matches m
    cross join lateral (values (m.home_team_id), (m.away_team_id)) as x(team_id)
    where m.sport in ('soccer', 'basketball', 'american_football', 'baseball', 'hockey')
      and m.status in ('SCHEDULED', 'TIMED')
      and m.utc_date between now() and now() + interval '8 days'
  ),
  need as (
    select u.team_id, bool_or(u.carded) as carded, min(u.utc_date) as first_game, min(u.competition_code) as comp
    from upcoming u group by u.team_id
  )
  select n.team_id, t.espn_key, cp.espn_path
  from need n join teams t on t.id = n.team_id join competitions cp on cp.code = n.comp
  where t.espn_key is not null
    and (t.roster_checked_at is null or t.roster_checked_at < now() - interval '24 hours')
  order by n.carded desc, n.first_game
  limit p_limit
$$;
