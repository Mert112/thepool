-- The Pool — football only.
-- The board carried seven sports (0008–0016). They are withdrawn: the data goes, the markets go,
-- the sports rows go, and every function that branched on `m.sport` is rewritten for football alone.
-- The `sport` columns stay (they are woven through the schema) but nothing but 'soccer' can live in them.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The data
--
-- What sport a row belongs to is decided by its *competition*, never by the denormalised `sport`
-- column, which has drifted: on the hosted project 468 matches in NBA, NCAAM, NHL, NFL, WTA and
-- MLB carry the column's 'soccer' default. Teams go by their espn_key namespace for the same
-- reason ('soccer:1234' against 'NBA:13'), and players by the team they belong to.
-- ---------------------------------------------------------------------------
create temp table gone_comps as select code from competitions where sport <> 'soccer';
create temp table gone_matches as select m.id from matches m join gone_comps g on g.code = m.competition_code;
create temp table gone_teams as
  select t.id from teams t where t.espn_key is not null and t.espn_key not like 'soccer:%';

-- album entries first: stickers reference both the competition and the match, with no cascade
delete from stickers where competition_code in (select code from gone_comps);
-- a receipt post is nothing but its call, and losing the call would break crew_posts' own check
delete from crew_posts p
 where p.body is null
   and p.call_id in (select k.id from calls k join entries e on e.id = k.entry_id
                     join cards cd on cd.id = e.card_id where cd.match_id in (select id from gone_matches));
-- cards cascade to entries, and entries to calls
delete from cards where match_id in (select id from gone_matches);
-- matches cascade to match_events, player_stats and match_props
delete from matches where id in (select id from gone_matches);

-- a player still named by a surviving call or event stays, whatever team they were on
delete from players p
 where p.team_id in (select id from gone_teams)
   and not exists (select 1 from calls c where c.player_id = p.id)
   and not exists (select 1 from match_events e where e.player_id = p.id or e.assist_player_id = p.id)
   and not exists (select 1 from player_stats s where s.player_id = p.id);
delete from teams t
 where t.id in (select id from gone_teams)
   and not exists (select 1 from matches m where t.id in (m.home_team_id, m.away_team_id))
   and not exists (select 1 from players p where p.team_id = t.id);
delete from competitions where code in (select code from gone_comps);
delete from markets where sport <> 'soccer';
delete from sports where code <> 'soccer';

-- player over/unders were a basketball and American-football market only
drop table if exists match_props;

-- the drifted column is corrected before it is constrained: everything left is football by
-- definition, because its competition is
update matches set sport = 'soccer' where sport <> 'soccer';
update teams    set sport = 'soccer' where sport is not null and sport <> 'soccer';
update players  set sport = 'soccer' where sport is not null and sport <> 'soccer';

-- nothing but football from here on
alter table competitions add constraint competitions_football_only check (sport = 'soccer');
alter table matches      add constraint matches_football_only      check (sport = 'soccer');
alter table markets      add constraint markets_football_only      check (sport = 'soccer');
alter table teams        add constraint teams_football_only        check (sport is null or sport = 'soccer');
alter table players      add constraint players_football_only      check (sport is null or sport = 'soccer');

-- the football card: the 3-way result, the total, the handicap, the scoreline and the four player calls
update markets set enabled = false where call_type in ('draw', 'motm', 'margin');
update markets set enabled = true  where call_type in ('winner', 'total', 'spread', 'score', 'scorer', 'assist', 'yellow', 'red');
update markets set simple = (call_type in ('winner', 'total'));

-- ---------------------------------------------------------------------------
-- 2. Saving a card — football markets only
-- ---------------------------------------------------------------------------
create or replace function rpc_save_calls(p_card uuid, p_calls jsonb) returns uuid
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  u uuid := require_user();
  c cards; m matches;
  e_id uuid;
  item jsonb;
  ct call_type;
  mk markets;
  kept call_type[] := '{}';
  conflict text;
  hl numeric;
  v_team int; v_player int; v_yes boolean; v_hg int; v_ag int; v_pick text; v_line numeric;
begin
  select * into c from cards where id = p_card;
  if c is null then raise exception 'unknown card'; end if;
  if c.crew_id is not null and not is_crew_member(c.crew_id, u) then
    raise exception 'you are not a member of this crew' using errcode = '42501';
  end if;
  if not card_is_editable(p_card) then raise exception 'this card is locked'; end if;
  select * into m from matches where id = c.match_id;

  insert into entries (card_id, user_id, matchday)
  values (p_card, u, (m.utc_date at time zone 'utc')::date)
  on conflict (card_id, user_id) do update set updated_at = now()
  returning id into e_id;

  for item in select * from jsonb_array_elements(coalesce(p_calls, '[]'::jsonb)) loop
    ct := (item->>'call_type')::call_type;
    select * into mk from markets where sport = 'soccer' and call_type = ct;
    if mk is null or not mk.enabled then raise exception 'call % is not available', ct; end if;
    if c.mode = 'simple' and not mk.simple then raise exception 'call % is not on a simple card', ct; end if;
    if ct = any(kept) then raise exception 'duplicate call %', ct; end if;

    v_team := null; v_player := null; v_yes := null; v_hg := null; v_ag := null; v_pick := null; v_line := null;
    case ct
      when 'winner' then
        if item->>'pick' = 'draw' then
          v_pick := 'draw';
        else
          v_team := (item->>'team_id')::int;
          if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then
            raise exception 'the result must name one of the two teams, or the draw';
          end if;
        end if;
      when 'draw' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'draw call needs yes/no'; end if;
      when 'total' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'over/under call needs a side'; end if;
        v_line := coalesce((m.odds->'total'->>'line')::numeric, m.total_line);
        if v_line is null then raise exception 'no goals line has been posted for this match yet'; end if;
      when 'spread' then
        v_team := (item->>'team_id')::int;
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then raise exception 'the handicap must name one of the two teams'; end if;
        hl := (m.odds->'spread'->>'home_line')::numeric;
        if hl is null then raise exception 'no handicap has been posted for this match yet'; end if;
        v_line := case when v_team = m.home_team_id then hl else -hl end;   -- the handicap on the side you back
      when 'score' then
        v_hg := (item->>'home_goals')::int; v_ag := (item->>'away_goals')::int;
        if v_hg is null or v_ag is null then raise exception 'the scoreline needs both sides'; end if;
      else
        v_player := (item->>'player_id')::int;
        if v_player is null or not exists (
          select 1 from players p where p.id = v_player and p.team_id in (m.home_team_id, m.away_team_id)
        ) then
          raise exception 'the player must be in one of the two squads';
        end if;
        -- optional time window on the red card
        v_pick := nullif(item->>'pick', '');
        if v_pick is not null and (ct <> 'red' or not coalesce(mk.options ? v_pick, false)) then
          raise exception 'unknown time window %', v_pick;
        end if;
    end case;

    insert into calls (entry_id, call_type, team_id, yes, player_id, home_goals, away_goals, pick, line, price)
    values (e_id, ct, v_team, v_yes, v_player, v_hg, v_ag, v_pick, v_line, call_price(m, mk, v_team, v_pick, v_yes))
    on conflict (entry_id, call_type) do update
      set team_id = excluded.team_id, yes = excluded.yes, player_id = excluded.player_id,
          home_goals = excluded.home_goals, away_goals = excluded.away_goals,
          pick = excluded.pick, line = excluded.line,
          -- an unchanged pick keeps the price it was taken at; a changed one takes today's
          price = case when (calls.team_id, calls.yes, calls.player_id, calls.home_goals, calls.away_goals, calls.pick, calls.line)
                            is not distinct from (excluded.team_id, excluded.yes, excluded.player_id, excluded.home_goals, excluded.away_goals, excluded.pick, excluded.line)
                       then calls.price else excluded.price end;
    kept := kept || ct;
  end loop;

  delete from calls where entry_id = e_id and not (call_type = any(kept));

  -- every call removed: the entry goes too (and with it any boost)
  if cardinality(kept) = 0 then
    delete from entries where id = e_id;
    return null;
  end if;

  -- one card, one story: calls that cannot all land would be a hedge
  conflict := call_conflict(m, e_id);
  if conflict is not null then raise exception '%', conflict; end if;

  update entries set boost_call_type = null
   where id = e_id and boost_call_type is not null and not (boost_call_type = any(kept));

  return e_id;
end $$;

-- ---------------------------------------------------------------------------
-- 3. No hedging — football pairs only
-- ---------------------------------------------------------------------------
create or replace function call_conflict(m matches, p_entry uuid) returns text
language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare
  w calls; d calls; s calls; t calls; sp calls;
  side int; w_draw boolean; w_team int;
begin
  select * into w  from calls where entry_id = p_entry and call_type = 'winner';
  select * into d  from calls where entry_id = p_entry and call_type = 'draw';
  select * into s  from calls where entry_id = p_entry and call_type = 'score';
  select * into t  from calls where entry_id = p_entry and call_type = 'total';
  select * into sp from calls where entry_id = p_entry and call_type = 'spread';
  w_draw := w.id is not null and coalesce(w.pick = 'draw', false);   -- pick is null for a team pick: null is not false
  w_team := case when w.id is not null and not w_draw then w.team_id end;

  if w_team is not null and d.yes then return 'You called a winner and a draw — only one can happen. Drop one of them.'; end if;
  if s.id is not null then
    if s.home_goals = s.away_goals then
      if w_team is not null then return 'A level scoreline means nobody wins — it contradicts your result.'; end if;
      if d.id is not null and not d.yes then return 'A level scoreline is a draw — it contradicts "Draw: no".'; end if;
    else
      side := case when s.home_goals > s.away_goals then m.home_team_id else m.away_team_id end;
      if w_team is not null and w_team <> side then return 'Your scoreline has the other side winning.'; end if;
      if w_draw then return 'Your scoreline has a winner — it contradicts your draw.'; end if;
      if d.yes then return 'Your scoreline has a winner — it contradicts "Draw: yes".'; end if;
    end if;
    -- a scoreline exactly on a whole-number line is a push, not a contradiction
    if t.id is not null and ((t.yes and s.home_goals + s.away_goals < t.line) or (not t.yes and s.home_goals + s.away_goals > t.line)) then
      return 'Your scoreline and your over/under disagree.';
    end if;
    if sp.id is not null and
       (case when sp.team_id = m.home_team_id then s.home_goals - s.away_goals else s.away_goals - s.home_goals end) + sp.line < 0 then
      return 'Your scoreline loses your handicap.';
    end if;
  end if;
  -- backing a side that gives goals away means that side has to win
  if sp.id is not null and sp.line < 0 and w.id is not null and (w_draw or w_team <> sp.team_id) then
    return 'Your handicap needs the other side to win.';
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Scoring — the 90-minute state and the event feed, nothing else
-- ---------------------------------------------------------------------------
create or replace function score_call(c calls, m matches, boosted boolean)
returns table (result call_result, points int) language plpgsql stable as $$
declare
  mk markets; r call_result := 'pending'; final boolean := m.status in ('FINISHED', 'AWARDED');
  ev boolean; has_stats boolean; played boolean;
  total int; cover numeric;
begin
  select * into mk from markets where sport = 'soccer' and call_type = c.call_type;
  -- did the called player take part? With no lineup for the match we cannot tell,
  -- so they count as played and the call is judged as before
  select exists (select 1 from player_stats s where s.match_id = m.id) into has_stats;
  played := c.player_id is null or not has_stats
            or exists (select 1 from player_stats s where s.match_id = m.id and s.player_id = c.player_id);
  total := m.home_score + m.away_score;

  case c.call_type
    when 'scorer' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                       and not e.own_goal and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'assist' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                       and e.assist_player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'yellow' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('yellow', 'yellow_red') and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'red' then
      -- with a time window, the sending-off has to come inside it (stoppage time counts in its half's last window)
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('red', 'yellow_red') and e.player_id = c.player_id
                       and (c.pick is null or band_contains(c.pick, e.minute))) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'winner' then
      -- the result is 3-way: a draw beats both sides
      if not final or m.home_score is null then r := case when final then 'void' else 'pending' end;
      elsif c.pick = 'draw' then r := case when m.home_score = m.away_score then 'hit' else 'miss' end;
      elsif m.home_score = m.away_score then r := 'miss';
      elsif (m.home_score > m.away_score and c.team_id = m.home_team_id)
         or (m.away_score > m.home_score and c.team_id = m.away_team_id) then r := 'hit';
      else r := 'miss'; end if;
    when 'spread' then
      if not final then r := 'pending';
      elsif m.home_score is null then r := 'void';
      else
        cover := (case when c.team_id = m.home_team_id then m.home_score - m.away_score else m.away_score - m.home_score end) + c.line;
        r := case when cover = 0 then 'void' when cover > 0 then 'hit' else 'miss' end;
      end if;
    when 'total' then
      if not final then r := 'pending';
      elsif total is null or c.line is null or total = c.line then r := 'void';   -- a push
      elsif (total > c.line) = c.yes then r := 'hit'; else r := 'miss'; end if;
    when 'draw' then
      if not final then r := 'pending';
      elsif c.yes = (m.home_score = m.away_score) then r := 'hit'; else r := 'miss'; end if;
    when 'score' then
      if not final then r := 'pending';
      elsif c.home_goals = m.home_score and c.away_goals = m.away_score then r := 'hit'; else r := 'miss'; end if;
    when 'motm' then
      if not final then r := 'pending';
      elsif m.motm_player_id is null then r := 'void';
      elsif m.motm_player_id = c.player_id then r := 'hit'; else r := 'miss'; end if;
    else r := 'pending';
  end case;
  result := r;
  points := case when r = 'hit'
                 then round(10 * coalesce(c.price, mk.default_price, mk.points / 10.0))::int * (case when boosted then 2 else 1 end)
                 else 0 end;
  return next;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Crowd labels — football calls only
-- ---------------------------------------------------------------------------
create or replace function card_crowd(p_card uuid)
returns table (call_type call_type, label text, key text, n bigint, pct numeric)
language sql stable security definer set search_path = pool, public, extensions as $$
  with e as (select id from entries where card_id = p_card),
  total as (select count(*)::numeric as t from e),
  v as (
    select c.call_type,
      case c.call_type
        when 'winner' then case when c.pick = 'draw' then 'Draw' else t.name end
        when 'draw'   then case when c.yes then 'Yes' else 'No' end
        when 'total'  then case when c.yes then 'Over ' else 'Under ' end || trim_scale(c.line)::text
        when 'spread' then t.name || ' ' || case when c.line > 0 then '+' else '' end || trim_scale(c.line)::text
        when 'score'  then c.home_goals || '–' || c.away_goals
        when 'red'    then p.name || coalesce(' · ' || c.pick || '''', '')
        else p.name end as label,
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
    left join teams t on t.id = c.team_id
    left join players p on p.id = c.player_id
  )
  select v.call_type, v.label, v.key, count(*) as n,
         round(100 * count(*) / greatest((select t from total), 1), 0) as pct
  from v
  where can_see_card(p_card)
  group by v.call_type, v.label, v.key
  order by v.call_type, n desc;
$$;

-- ---------------------------------------------------------------------------
-- 6. Read models and the sync's work lists
-- ---------------------------------------------------------------------------
drop view v_board;
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
       else 'upcoming' end as phase,
  m.clock, m.event_name, m.total_line, m.result_detail, m.odds
from matches m
join competitions cp on cp.code = m.competition_code
left join teams ht on ht.id = m.home_team_id
left join teams at on at.id = m.away_team_id
left join cards pc on pc.match_id = m.id and pc.crew_id is null
where m.sport = 'soccer' and m.status <> 'CANCELLED';

-- the sport scope is gone with the sports
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

create or replace function enqueue_deadline_reminders() returns int
language plpgsql security definer set search_path = pool, public, extensions as $$
declare n int;
begin
  with soon as (
    select m.id as match_id, m.utc_date from matches m
    where m.utc_date between now() + interval '45 minutes' and now() + interval '65 minutes'
      and m.status in ('SCHEDULED', 'TIMED')
  ),
  incomplete as (
    select e.user_id, c.id as card_id, s.match_id
    from soon s join cards c on c.match_id = s.match_id join entries e on e.card_id = c.id
    where (select count(*) from calls x where x.entry_id = e.id)
        < (select count(*) from markets k where k.enabled and (c.mode = 'complex' or k.simple))
  ),
  absent as (
    select cm.user_id, c.id as card_id, s.match_id
    from soon s join cards c on c.match_id = s.match_id and c.crew_id is not null
    join crew_members cm on cm.crew_id = c.crew_id
    where not exists (select 1 from entries e where e.card_id = c.id and e.user_id = cm.user_id)
  ),
  targets as (select * from incomplete union select * from absent),
  ins as (
    insert into notifications (user_id, type, dedupe_key, payload)
    select t.user_id, 'deadline_reminder', t.match_id::text,
           jsonb_build_object('match_id', t.match_id, 'card_ids', jsonb_agg(t.card_id))
    from targets t join notification_settings ns on ns.user_id = t.user_id
    where ns.deadline_reminder
    group by t.user_id, t.match_id
    on conflict do nothing
    returning 1
  )
  select count(*) into n from ins;
  return n;
end $$;

-- the sync only ever asks about football now
create or replace function sync_tracked_matches()
returns table (id int, espn_key text, competition_code text, sport text, status match_status, utc_date timestamptz)
language sql stable security definer set search_path = pool, public, extensions as $$
  select m.id, m.espn_key, m.competition_code, m.sport, m.status, m.utc_date
  from matches m
  where m.espn_key is not null and m.sport = 'soccer'
    and m.utc_date between now() - interval '2 days' and now() + interval '1 day'
    and exists (select 1 from cards c join entries e on e.card_id = c.id where c.match_id = m.id)
$$;

create or replace function sync_roster_needs(p_limit int default 25)
returns table (team_id int, espn_key text, espn_path text)
language sql stable security definer set search_path = pool, public, extensions as $$
  with upcoming as (
    select m.competition_code, m.utc_date, x.team_id,
           exists (select 1 from cards c where c.match_id = m.id) as carded
    from matches m
    cross join lateral (values (m.home_team_id), (m.away_team_id)) as x(team_id)
    where m.sport = 'soccer'
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

grant select on v_board to anon, authenticated;
revoke execute on function sync_tracked_matches(), sync_roster_needs(int), enqueue_deadline_reminders() from public, anon, authenticated;
grant execute on function sync_tracked_matches(), sync_roster_needs(int) to service_role;

notify pgrst, 'reload schema';
