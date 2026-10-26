-- The Pool in three languages (§i18n).
--
-- The words themselves live in the web app, one file per language, because that is where they are
-- read. Two things have to live here:
--
--   · profiles.language — the choice follows the player, not the browser, so the mail we send at
--     full time is in the same language as the screen they filled the card on. Null means "never
--     chosen": the app then takes the browser's preference and writes it back on the first visit.
--   · call_parts() — a call in pieces instead of a sentence. call_label() builds English prose
--     ("Over 2.5", "Yes — level at 90"), which cannot be translated after the fact without
--     guessing. The pieces can: the team and player names come straight from the provider and
--     are passed through untouched, and the words around them are the app's to say in any
--     language. card_crowd() and my_history() now carry both, so nothing that reads the old
--     `label` breaks.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- The language a player has chosen
-- ---------------------------------------------------------------------------
alter table profiles add column language text
  check (language in ('en', 'tr', 'bg'));

comment on column profiles.language is
  'en | tr | bg, or null when the player has never chosen: the app then follows the browser.';

grant select (language) on profiles to authenticated;

create or replace function rpc_set_language(p_lang text) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user();
begin
  if p_lang is null or p_lang not in ('en', 'tr', 'bg') then
    raise exception 'unknown language %', p_lang;
  end if;
  update profiles set language = p_lang where id = u;
end $$;

revoke execute on function rpc_set_language(text) from public, anon;
grant execute on function rpc_set_language(text) to authenticated;

-- ---------------------------------------------------------------------------
-- One call, in pieces
-- ---------------------------------------------------------------------------
-- Everything the app needs to say what a call is, in whatever language it is speaking. Names are
-- the provider's and are not translated; the rest are keys and numbers.
create or replace function call_parts(c calls, m matches) returns jsonb
language sql stable security definer set search_path = pool, public, extensions as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'call_type', c.call_type,
    'team',      (select t.name from teams t where t.id = c.team_id),
    'side',      case when c.team_id = m.home_team_id then 'home'
                      when c.team_id = m.away_team_id then 'away' end,
    'player',    (select p.name from players p where p.id = c.player_id),
    'yes',       c.yes,
    'line',      case when c.line is not null then trim_scale(c.line)::text end,
    'home_goals', c.home_goals,
    'away_goals', c.away_goals,
    -- 'draw' on a result call, a minute window on a red card, null everywhere else
    'pick',      c.pick
  ))
$$;

revoke execute on function call_parts(calls, matches) from public, anon, authenticated;
grant execute on function call_parts(calls, matches) to service_role;

-- ---------------------------------------------------------------------------
-- The crowd split, with the pieces alongside the English
-- ---------------------------------------------------------------------------
drop function if exists card_crowd(uuid);

create function card_crowd(p_card uuid)
returns table (call_type call_type, label text, parts jsonb, key text, n bigint, pct numeric)
language sql stable security definer set search_path = pool, public, extensions as $$
  with m as (select mt.* from cards cd join matches mt on mt.id = cd.match_id where cd.id = p_card),
  e as (select id from entries where card_id = p_card),
  total as (select count(*)::numeric as t from e),
  v as (
    select c.call_type, call_label(c, m.*) as label, call_parts(c, m.*) as parts,
      case c.call_type
        when 'winner' then coalesce(c.team_id::text, 'draw')
        when 'draw'   then c.yes::text
        when 'total'  then c.yes::text
        when 'spread' then c.team_id::text
        when 'score'  then c.home_goals || '-' || c.away_goals
        when 'red'    then c.player_id || ':' || coalesce(c.pick, 'any')
        else c.player_id::text end as key
    from calls c
    join e on e.id = c.entry_id
    cross join m
  )
  select v.call_type, v.label, v.parts, v.key, count(*) as n,
         round(100 * count(*) / greatest((select t from total), 1), 0) as pct
  from v
  where can_see_card(p_card)
  group by v.call_type, v.label, v.parts, v.key
  order by v.call_type, n desc;
$$;

revoke execute on function card_crowd(uuid) from public, anon;
grant execute on function card_crowd(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Prediction history, likewise
-- ---------------------------------------------------------------------------
create or replace function my_history(p_limit int default 40)
returns jsonb language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); res jsonb;
begin
  select coalesce(jsonb_agg(h order by h->>'utc_date' desc), '[]'::jsonb) into res from (
    select jsonb_build_object(
      'entry_id', e.id, 'card_id', cd.id, 'match_id', m.id, 'mode', cd.mode,
      'crew', cr.name, 'card_status', cd.status,
      'competition', cp.name, 'utc_date', m.utc_date,
      'home', ht.name, 'away', at.name, 'home_score', m.home_score, 'away_score', m.away_score,
      'points', e.points, 'hits', e.hits,
      'calls', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'call_type', k.call_type, 'title', mk.title,
                 'label', call_label(k, m), 'parts', call_parts(k, m),
                 'result', k.result, 'points', k.points_awarded) order by mk.sort_order)
        from calls k join markets mk on mk.call_type = k.call_type and mk.sport = 'soccer'
        where k.entry_id = e.id), '[]'::jsonb)
    ) as h
    from entries e
    join cards cd on cd.id = e.card_id
    join matches m on m.id = cd.match_id
    join competitions cp on cp.code = m.competition_code
    left join crews cr on cr.id = cd.crew_id
    left join teams ht on ht.id = m.home_team_id
    left join teams at on at.id = m.away_team_id
    where e.user_id = u
    order by m.utc_date desc
    limit greatest(1, least(p_limit, 200))
  ) x;
  return res;
end $$;

grant execute on function my_history(int) to authenticated;

notify pgrst, 'reload schema';
