-- The Pool — the red card can carry a time: an optional 15-minute window, priced up by how rarely a
-- sending-off lands in it (reds cluster late). Stoppage time counts in its half's last window (45+2' → 31–45').
set search_path = pool, public, extensions;

alter table markets add column option_mult jsonb;   -- price multiplier per option, where an option narrows the call

update markets set
  options = '["0-15","16-30","31-45","46-60","61-75","76-90"]',
  option_mult = '{"0-15":12,"16-30":8,"31-45":6,"46-60":6,"61-75":5,"76-90":3.5}',
  description = 'One name. Add when it happens for a bigger price — the window has to be right.'
where sport = 'soccer' and call_type = 'red';

create or replace function call_price(m matches, mk markets, p_team int, p_pick text, p_yes boolean)
returns numeric language sql stable as $$
  select coalesce(
    case mk.call_type
      when 'winner' then (case when p_pick = 'draw' then m.odds->>'draw'
                               when p_team = m.home_team_id then m.odds->>'home'
                               when p_team = m.away_team_id then m.odds->>'away' end)::numeric
      when 'total'  then (m.odds->'total'->>(case when p_yes then 'over' else 'under' end))::numeric
      when 'spread' then (m.odds->'spread'->>(case when p_team = m.home_team_id then 'home' else 'away' end))::numeric
    end,
    -- a narrower call (the red card's time window) multiplies the standard price
    coalesce(mk.default_price, mk.points / 10.0) * coalesce((mk.option_mult->>p_pick)::numeric, 1))
$$;

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
  need int;
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
    select * into mk from markets where sport = m.sport and call_type = ct;
    if mk is null or not mk.enabled then raise exception 'call % is not available', ct; end if;
    if c.mode = 'simple' and not mk.simple then raise exception 'call % is not on a simple card', ct; end if;
    if ct = any(kept) then raise exception 'duplicate call %', ct; end if;

    v_team := null; v_player := null; v_yes := null; v_hg := null; v_ag := null; v_pick := null; v_line := null;
    case ct
      when 'winner' then
        if item->>'pick' = 'draw' then
          if m.sport <> 'soccer' then raise exception 'there is no draw in this sport'; end if;
          v_pick := 'draw';
        else
          v_team := (item->>'team_id')::int;
          if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then
            raise exception 'winner must be one of the two teams';
          end if;
        end if;
      when 'draw', 'distance' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception '% call needs yes/no', ct; end if;
      when 'total' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'over/under call needs a side'; end if;
        v_line := coalesce((m.odds->'total'->>'line')::numeric, m.total_line);
        if v_line is null then raise exception 'no line has been posted for this game yet'; end if;
      when 'spread' then
        v_team := (item->>'team_id')::int;
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then raise exception 'the spread must name one of the two sides'; end if;
        hl := (m.odds->'spread'->>'home_line')::numeric;
        if hl is null then raise exception 'no spread has been posted for this game yet'; end if;
        v_line := case when v_team = m.home_team_id then hl else -hl end;   -- the handicap on the side you back
      when 'score' then
        v_hg := (item->>'home_goals')::int; v_ag := (item->>'away_goals')::int;
        if v_hg is null or v_ag is null then raise exception 'score needs both sides'; end if;
        if m.sport <> 'soccer' and v_hg = v_ag then raise exception 'this game always has a winner — the score cannot be level'; end if;
      when 'sets' then
        v_hg := (item->>'home_goals')::int; v_ag := (item->>'away_goals')::int;
        need := (coalesce(m.best_of, 3) + 1) / 2;
        if v_hg is null or v_ag is null or greatest(v_hg, v_ag) <> need or least(v_hg, v_ag) >= need or least(v_hg, v_ag) < 0 then
          raise exception 'that is not a possible set score for a best of %', coalesce(m.best_of, 3);
        end if;
      when 'margin' then
        v_team := (item->>'team_id')::int; v_pick := item->>'pick';
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then raise exception 'margin must name one of the two sides'; end if;
        if v_pick is null or not (mk.options ? v_pick) then raise exception 'unknown margin band %', v_pick; end if;
      when 'method' then
        v_team := (item->>'team_id')::int; v_pick := item->>'pick';
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then raise exception 'pick the fighter who wins it'; end if;
        if v_pick is null or not (mk.options ? v_pick) then raise exception 'unknown method %', v_pick; end if;
      when 'round' then
        v_pick := item->>'pick';
        if v_pick is null or v_pick !~ '^\d$' or v_pick::int not between 1 and coalesce(m.best_of, 3) then
          raise exception 'pick a round between 1 and %', coalesce(m.best_of, 3);
        end if;
      when 'player_line' then
        v_player := (item->>'player_id')::int; v_pick := item->>'pick'; v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'a player line needs over or under'; end if;
        select p.line into v_line from match_props p where p.match_id = m.id and p.player_id = v_player and p.stat = v_pick;
        if v_line is null then raise exception 'that player line is not on the board for this game'; end if;
      else
        v_player := (item->>'player_id')::int;
        if v_player is null or not exists (
          select 1 from players p where p.id = v_player and p.team_id in (m.home_team_id, m.away_team_id)
        ) then
          raise exception 'player must be in one of the two squads';
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

  -- a boost on a call that no longer exists is released
  update entries set boost_call_type = null
   where id = e_id and boost_call_type is not null and not (boost_call_type = any(kept));

  return e_id;
end $$;

create or replace function score_call(c calls, m matches, boosted boolean)
returns table (result call_result, points int) language plpgsql stable as $$
declare
  mk markets; r call_result := 'pending'; final boolean := m.status in ('FINISHED', 'AWARDED');
  ev boolean; has_stats boolean; played boolean; top numeric; mine numeric; v numeric;
  win_team int; total int; diff int; cover numeric;
  method text := m.result_detail->>'method';
  retired boolean := coalesce((m.result_detail->>'retired')::boolean, false);
  v_stat text := case m.sport when 'hockey' then 'g' when 'american_football' then 'td' when 'baseball' then 'hr' end;
begin
  select * into mk from markets where sport = m.sport and call_type = c.call_type;
  -- who won: the provider's flag where the score cannot say (tennis retirement, MMA), else the score
  win_team := case m.result_detail->>'winner'
                when 'home' then m.home_team_id when 'away' then m.away_team_id when 'none' then null
                else case when m.home_score > m.away_score then m.home_team_id
                          when m.away_score > m.home_score then m.away_team_id end end;
  -- did the called player take part? With no lineup or box score for the game we cannot tell,
  -- so they count as played and the call is judged as before
  select exists (select 1 from player_stats s where s.match_id = m.id) into has_stats;
  played := c.player_id is null or not has_stats
            or exists (select 1 from player_stats s where s.match_id = m.id and s.player_id = c.player_id);
  total := m.home_score + m.away_score;
  diff  := abs(m.home_score - m.away_score);

  case c.call_type
    when 'scorer' then
      if m.sport = 'soccer' then
        select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                         and not e.own_goal and e.player_id = c.player_id) into ev;
      else
        select coalesce(sum(s.value), 0) > 0 into ev from player_stats s
         where s.match_id = m.id and s.player_id = c.player_id and s.stat = v_stat;
      end if;
      r := case when ev then 'hit' when not final then 'pending'
                when m.sport <> 'soccer' and not has_stats then 'void'      -- no box score to judge by
                when not played then 'void' else 'miss' end;
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
    when 'top_scorer' then
      if not final then r := 'pending';
      else
        select max(s.value) into top from player_stats s where s.match_id = m.id and s.stat = 'pts';
        select s.value into mine from player_stats s where s.match_id = m.id and s.stat = 'pts' and s.player_id = c.player_id;
        r := case when top is null or not played then 'void' when mine = top then 'hit' else 'miss' end;
      end if;
    when 'player_line' then
      if not final then r := 'pending';
      elsif not has_stats or not played then r := 'void';                      -- no box score, or never took part
      else
        select coalesce(sum(s.value), 0) into v from player_stats s
         where s.match_id = m.id and s.player_id = c.player_id and s.stat = c.pick;
        r := case when v = c.line then 'void' when (v > c.line) = c.yes then 'hit' else 'miss' end;
      end if;
    when 'winner' then
      if not final then r := 'pending';
      elsif c.pick = 'draw' then
        r := case when m.home_score is null then 'void' when m.home_score = m.away_score then 'hit' else 'miss' end;
      elsif win_team is null then
        -- football's result is 3-way: a draw beats both sides. Elsewhere a tie or no contest is a push.
        r := case when m.sport = 'soccer' and m.home_score is not null and m.home_score = m.away_score then 'miss' else 'void' end;
      elsif c.team_id = win_team then r := 'hit'; else r := 'miss'; end if;
    when 'spread' then
      if not final then r := 'pending';
      elsif m.home_score is null then r := 'void';
      else
        cover := (case when c.team_id = m.home_team_id then m.home_score - m.away_score else m.away_score - m.home_score end) + c.line;
        r := case when cover = 0 then 'void' when cover > 0 then 'hit' else 'miss' end;
      end if;
    when 'draw' then
      if not final then r := 'pending';
      elsif c.yes = (m.home_score = m.away_score) then r := 'hit'; else r := 'miss'; end if;
    when 'score' then
      if not final then r := 'pending';
      elsif c.home_goals = m.home_score and c.away_goals = m.away_score then r := 'hit'; else r := 'miss'; end if;
    when 'total' then
      if not final then r := 'pending';
      elsif total is null or c.line is null or total = c.line then r := 'void';   -- a push
      elsif (total > c.line) = c.yes then r := 'hit'; else r := 'miss'; end if;
    when 'margin' then
      if not final then r := 'pending';
      elsif win_team is null then r := 'void';
      elsif c.team_id = win_team and band_contains(c.pick, diff) then r := 'hit'; else r := 'miss'; end if;
    when 'sets' then
      if not final then r := 'pending';
      elsif retired or m.home_score is null then r := 'void';
      elsif c.home_goals = m.home_score and c.away_goals = m.away_score then r := 'hit'; else r := 'miss'; end if;
    when 'distance' then
      if not final then r := 'pending';
      elsif m.sport = 'tennis' then
        if retired or total is null then r := 'void';
        elsif c.yes = (total = coalesce(m.best_of, 3)) then r := 'hit'; else r := 'miss'; end if;
      else
        if method is null then r := 'void';
        elsif c.yes = (method = 'Decision') then r := 'hit'; else r := 'miss'; end if;
      end if;
    when 'method' then
      if not final then r := 'pending';
      elsif method is null or not (mk.options ? method) then r := 'void';
      elsif c.pick = method and (c.team_id is null or c.team_id = win_team) then r := 'hit'; else r := 'miss'; end if;
    when 'round' then
      if not final then r := 'pending';
      elsif method is null then r := 'void';
      elsif method = 'Decision' then r := 'miss';
      elsif c.pick = m.result_detail->>'round' then r := 'hit'; else r := 'miss'; end if;
    when 'motm' then
      if not final then r := 'pending';
      elsif m.motm_player_id is null then r := 'void';
      elsif m.motm_player_id = c.player_id then r := 'hit'; else r := 'miss'; end if;
  end case;
  result := r;
  points := case when r = 'hit'
                 then round(10 * coalesce(c.price, mk.default_price, mk.points / 10.0))::int * (case when boosted then 2 else 1 end)
                 else 0 end;
  return next;
end $$;

create or replace function card_crowd(p_card uuid)
returns table (call_type call_type, label text, key text, n bigint, pct numeric)
language sql stable security definer set search_path = pool, public, extensions as $$
  with e as (select id from entries where card_id = p_card),
  total as (select count(*)::numeric as t from e),
  v as (
    select c.call_type,
      case c.call_type
        when 'winner'      then case when c.pick = 'draw' then 'Draw' else t.name end
        when 'draw'        then case when c.yes then 'Yes' else 'No' end
        when 'distance'    then case when c.yes then 'Yes' else 'No' end
        when 'total'       then case when c.yes then 'Over ' else 'Under ' end || trim_scale(c.line)::text
        when 'spread'      then t.name || ' ' || case when c.line > 0 then '+' else '' end || trim_scale(c.line)::text
        when 'score'       then c.home_goals || '–' || c.away_goals
        when 'sets'        then c.home_goals || '–' || c.away_goals
        when 'margin'      then t.name || ' by ' || c.pick
        when 'method'      then coalesce(t.name || ' by ', '') || c.pick
        when 'round'       then 'Round ' || c.pick
        when 'player_line' then p.name || ' ' || case when c.yes then 'over ' else 'under ' end || trim_scale(c.line)::text || ' ' || stat_label(c.pick)
        when 'red'         then p.name || coalesce(' · ' || c.pick || '''', '')
        else p.name end as label,
      case c.call_type
        when 'winner'      then coalesce(c.team_id::text, 'draw')
        when 'draw'        then c.yes::text
        when 'distance'    then c.yes::text
        when 'total'       then c.yes::text
        when 'spread'      then c.team_id::text
        when 'score'       then c.home_goals || '-' || c.away_goals
        when 'sets'        then c.home_goals || '-' || c.away_goals
        when 'margin'      then c.team_id || ':' || c.pick
        when 'method'      then coalesce(c.team_id::text, '') || ':' || c.pick
        when 'round'       then c.pick
        when 'player_line' then c.player_id || ':' || c.pick || ':' || c.yes
        when 'red'         then c.player_id || ':' || coalesce(c.pick, 'any')
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

notify pgrst, 'reload schema';
