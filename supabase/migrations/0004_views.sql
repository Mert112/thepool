-- The Pool — read models for the screens (§5). Views run as the caller (RLS applies);
-- Installed in its own schema so it never touches the other tables in this project.
create schema if not exists pool;
set search_path = pool, public, extensions;
-- leaderboards need every entry regardless of audience, so they are security-definer functions.

-- Counts everyone can see (the sign-in teaser is anonymous), without exposing rows
create or replace function match_card_count(p_match int) returns bigint
language sql stable security definer set search_path = pool, public, extensions as $$
  select count(*) from cards where match_id = p_match $$;
create or replace function match_playing(p_match int) returns bigint
language sql stable security definer set search_path = pool, public, extensions as $$
  select count(*) from entries e join cards c on c.id = e.card_id where c.match_id = p_match $$;

-- §5.2 The board: one row per fixture with what the row needs to render
create view v_board with (security_invoker = true) as
select
  m.id as match_id, m.competition_code, cp.name as competition_name, m.season, m.matchday, m.stage,
  m.utc_date, m.status, m.minute, m.home_score, m.away_score, m.ft_home, m.ft_away, m.duration,
  m.home_team_id, ht.name as home_team, ht.short_name as home_short, ht.tla as home_tla, ht.crest_url as home_crest,
  m.away_team_id, at.name as away_team, at.short_name as away_short, at.tla as away_tla, at.crest_url as away_crest,
  pc.id  as public_card_id, pc.mode as public_card_mode, pc.status as public_card_status,
  match_card_count(m.id) as card_count,
  match_playing(m.id) as playing,
  case when m.status in ('IN_PLAY', 'PAUSED', 'EXTRA_TIME', 'PENALTY_SHOOTOUT') then 'live'
       when m.status in ('FINISHED', 'AWARDED') then 'settled'
       else 'upcoming' end as phase
from matches m
join competitions cp on cp.code = m.competition_code
left join teams ht on ht.id = m.home_team_id
left join teams at on at.id = m.away_team_id
left join cards pc on pc.match_id = m.id and pc.crew_id is null;

-- Entries with everything needed to total them
create view v_entry_points with (security_invoker = true) as
select e.id as entry_id, e.user_id, e.card_id, c.crew_id, c.match_id, c.mode, c.status as card_status,
       m.competition_code, m.season, e.matchday, m.utc_date, e.points, e.hits, e.boost_call_type,
       (select count(*) from calls k where k.entry_id = e.id) as n_calls
from entries e
join cards c on c.id = e.card_id
join matches m on m.id = c.match_id;

-- §5.8 Table. scope: overall | competition (key = code) | crew (key = crew id) | week
-- points_prev = points as of 7 days ago, so the client can show rank movement.
create or replace function leaderboard(p_scope text, p_key text default null, p_season text default null)
returns table (
  user_id uuid, display_name text, points bigint, points_prev bigint, cards bigint,
  hits bigint, calls bigint, hit_rate numeric, best_call call_type, best_points int
)
language plpgsql stable security definer set search_path = pool, public, extensions as $$
begin
  if p_scope = 'crew' and not is_crew_member(p_key::uuid) then
    raise exception 'not a member of this crew' using errcode = '42501';
  end if;
  return query
  with ent as (
    select e.id, e.user_id, e.points, e.hits, e.matchday, m.utc_date, m.competition_code, m.season, c.crew_id
    from entries e join cards c on c.id = e.card_id join matches m on m.id = c.match_id
    where c.status in ('settled', 'disputed')
      and (p_season is null or m.season = p_season)
      and (p_scope <> 'competition' or m.competition_code = p_key)
      and (p_scope <> 'crew' or c.crew_id = p_key::uuid)
      and (p_scope <> 'week' or m.utc_date > now() - interval '7 days')
  ),
  agg as (
    select ent.user_id,
      sum(ent.points) as points,
      sum(ent.points) filter (where ent.utc_date < now() - interval '7 days') as points_prev,
      count(*) as cards, sum(ent.hits) as hits
    from ent group by ent.user_id
  ),
  ncalls as (
    select ent.user_id, count(*) as calls from ent join calls k on k.entry_id = ent.id group by ent.user_id
  ),
  best as (
    select distinct on (ent.user_id) ent.user_id, k.call_type, k.points_awarded
    from ent join calls k on k.entry_id = ent.id where k.result = 'hit'
    order by ent.user_id, k.points_awarded desc
  )
  select a.user_id, p.display_name, a.points, coalesce(a.points_prev, 0), a.cards, a.hits,
         coalesce(n.calls, 0),
         case when coalesce(n.calls, 0) = 0 then 0 else round(100.0 * a.hits / n.calls, 0) end,
         b.call_type, b.points_awarded
  from agg a
  join profiles p on p.id = a.user_id
  left join ncalls n on n.user_id = a.user_id
  left join best b on b.user_id = a.user_id
  order by a.points desc, a.hits desc, p.display_name;
end $$;

-- §5.6 crew-v-crew: each crew's season points on its own cards
create or replace function crew_score(p_crew uuid, p_season text default null)
returns bigint language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce(sum(e.points), 0)
  from entries e join cards c on c.id = e.card_id join matches m on m.id = c.match_id
  where c.crew_id = p_crew and c.status in ('settled', 'disputed')
    and (p_season is null or m.season = p_season)
$$;

-- §5.8 Profile: season points, overall rank, per-competition rank, recent cards
create or replace function my_stats(p_season text default null)
returns jsonb language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare u uuid := auth.uid(); res jsonb;
begin
  with lb as (select *, row_number() over (order by points desc, hits desc) as rank from leaderboard('overall', null, p_season)),
  me as (select * from lb where user_id = u),
  comps as (
    select cp.code, cp.name, x.points, x.rank from competitions cp
    cross join lateral (
      select l.points, row_number() over (order by l.points desc, l.hits desc) as rank, l.user_id
      from leaderboard('competition', cp.code, p_season) l
    ) x where x.user_id = u
  ),
  recent as (
    select m.id as match_id, ht.name as home, at.name as away, m.home_score, m.away_score, m.utc_date,
           e.points, e.hits, c.mode, m.competition_code
    from entries e join cards c on c.id = e.card_id join matches m on m.id = c.match_id
    left join teams ht on ht.id = m.home_team_id left join teams at on at.id = m.away_team_id
    where e.user_id = u and c.status in ('settled', 'disputed')
    order by m.utc_date desc limit 8
  )
  select jsonb_build_object(
    'points', coalesce((select points from me), 0),
    'rank', (select rank from me),
    'players', (select count(*) from lb),
    'cards', coalesce((select cards from me), 0),
    'hit_rate', coalesce((select hit_rate from me), 0),
    'streak', (select streak from profiles where id = u),
    'competitions', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'points', points, 'rank', rank) order by points desc) from comps), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(to_jsonb(recent)) from recent), '[]'::jsonb)
  ) into res;
  return res;
end $$;

revoke execute on all functions in schema pool from public, anon;
grant execute on all functions in schema pool to service_role;
grant select on v_board to anon, authenticated;
grant execute on function match_card_count(int), match_playing(int) to anon, authenticated;
grant select on v_entry_points to authenticated;
grant execute on function leaderboard(text, text, text) to authenticated;
grant execute on function crew_score(uuid, text) to authenticated;
grant execute on function my_stats(text) to authenticated;
