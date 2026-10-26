-- The Pool — say what every call means, and let people look back at the ones they made.
--   · markets.explainer: one plain-English line per call, shown under its title on the card
--   · call_label(): one place that turns a saved call into the words people read (the crowd split,
--     the history, anywhere else), instead of the same CASE written out again per screen
--   · my_history(): past cards with every call and whether it hit or missed, for the profile page
set search_path = pool, public, extensions;

alter table markets add column explainer text;

update markets set explainer = v.text from (values
  ('winner', 'Pick home, draw or away: whoever is ahead after 90 minutes plus stoppage time, with extra time and penalties ignored.'),
  ('draw',   'Say whether the two teams will be level when the 90 minutes plus stoppage time are up.'),
  ('total',  'Add both teams'' goals together: your call wins if the total finishes above the line for over, or below it for under, and a total landing exactly on the line gives your stake back.'),
  ('spread', 'Your team starts the match with a virtual head start or deficit of N goals; your call wins if they are still ahead after the handicap is applied.'),
  ('score',  'Name the exact final score: 2–1 only wins on 2–1, and there is no credit for being close.'),
  ('scorer', 'Name one player to score at any point in the 90 minutes plus stoppage time; own goals do not count for the scorer.'),
  ('assist', 'Name one player to lay on a goal — the pass the feed credits as the assist is the one that counts.'),
  ('yellow', 'Name one player to be shown a yellow card in the 90 minutes plus stoppage time.'),
  ('red',    'Name one player to be sent off, by a straight red or a second yellow; add a 15-minute window for a bigger return and the sending-off has to fall inside it.'),
  ('motm',   'Name the player the match officials give the official man-of-the-match award to.')
) as v(ct, text) where markets.call_type = v.ct::call_type;

alter table markets alter column explainer set not null;

-- ---------------------------------------------------------------------------
-- One call, in words
-- ---------------------------------------------------------------------------
create or replace function call_label(c calls, m matches) returns text
language sql stable security definer set search_path = pool, public, extensions as $$
  select case c.call_type
    when 'winner' then case when c.pick = 'draw' then 'Draw' else (select t.name from teams t where t.id = c.team_id) end
    when 'draw'   then case when c.yes then 'Yes — level at 90' else 'No — someone wins' end
    when 'total'  then (case when c.yes then 'Over ' else 'Under ' end) || trim_scale(c.line)::text
    when 'spread' then (select t.name from teams t where t.id = c.team_id) || ' '
                       || case when c.line > 0 then '+' else '' end || trim_scale(c.line)::text
    when 'score'  then c.home_goals || '–' || c.away_goals
    else coalesce((select p.name from players p where p.id = c.player_id), 'Player')
         || coalesce(' · ' || c.pick || '''', '')
  end
$$;

create or replace function card_crowd(p_card uuid)
returns table (call_type call_type, label text, key text, n bigint, pct numeric)
language sql stable security definer set search_path = pool, public, extensions as $$
  with m as (select mt.* from cards cd join matches mt on mt.id = cd.match_id where cd.id = p_card),
  e as (select id from entries where card_id = p_card),
  total as (select count(*)::numeric as t from e),
  v as (
    select c.call_type, call_label(c, m.*) as label,
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
  select v.call_type, v.label, v.key, count(*) as n,
         round(100 * count(*) / greatest((select t from total), 1), 0) as pct
  from v
  where can_see_card(p_card)
  group by v.call_type, v.label, v.key
  order by v.call_type, n desc;
$$;

-- ---------------------------------------------------------------------------
-- Prediction history: every card you have played, newest first, with each call's fate
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
                 'call_type', k.call_type, 'title', mk.title, 'label', call_label(k, m),
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

revoke execute on function call_label(calls, matches) from public, anon, authenticated;
grant execute on function call_label(calls, matches) to service_role;
grant execute on function my_history(int) to authenticated;

notify pgrst, 'reload schema';
