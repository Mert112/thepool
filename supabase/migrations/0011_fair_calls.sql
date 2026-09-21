-- The Pool — fairer cards.
--   · no hedging: calls on one card that cannot all land together are refused (call_conflict)
--   · a player who never took part (not in the lineup / box score) is void, not a miss;
--     the sync records appearances as player_stats 'app' rows
--   · scores outside football cannot be level; removing every call withdraws the entry
set search_path = pool, public, extensions;

-- Calls on one entry must be able to land together. Every rule is between two calls, and the app
-- mirrors them (web/src/lib/calls.ts: clashes) so a new pick replaces the one it contradicts.
create or replace function call_conflict(m matches, p_entry uuid) returns text
language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare
  w calls; d calls; s calls; t calls; mg calls; st calls; di calls; me calls; ro calls;
  side int;
begin
  select * into w  from calls where entry_id = p_entry and call_type = 'winner';
  select * into d  from calls where entry_id = p_entry and call_type = 'draw';
  select * into s  from calls where entry_id = p_entry and call_type = 'score';
  select * into t  from calls where entry_id = p_entry and call_type = 'total';
  select * into mg from calls where entry_id = p_entry and call_type = 'margin';
  select * into st from calls where entry_id = p_entry and call_type = 'sets';
  select * into di from calls where entry_id = p_entry and call_type = 'distance';
  select * into me from calls where entry_id = p_entry and call_type = 'method';
  select * into ro from calls where entry_id = p_entry and call_type = 'round';

  if w.id is not null and d.yes then return 'You called a winner and a draw — only one can happen. Drop one of them.'; end if;
  if s.id is not null then
    if s.home_goals = s.away_goals then
      if w.id is not null then return 'A level scoreline means nobody wins — it contradicts your winner.'; end if;
      if d.id is not null and not d.yes then return 'A level scoreline is a draw — it contradicts "Draw: no".'; end if;
    else
      side := case when s.home_goals > s.away_goals then m.home_team_id else m.away_team_id end;
      if w.id is not null and w.team_id <> side then return 'Your score has the other side winning.'; end if;
      if d.yes then return 'Your score has a winner — it contradicts "Draw: yes".'; end if;
    end if;
    -- a score exactly on a whole-number line is a push, not a contradiction
    if t.id is not null and ((t.yes and s.home_goals + s.away_goals < t.line) or (not t.yes and s.home_goals + s.away_goals > t.line)) then
      return 'Your exact score and your over/under disagree.';
    end if;
  end if;
  if mg.id is not null and w.id is not null and mg.team_id <> w.team_id then return 'Your winning margin backs the other side.'; end if;
  if st.id is not null then
    side := case when st.home_goals > st.away_goals then m.home_team_id else m.away_team_id end;
    if w.id is not null and w.team_id <> side then return 'Your set score has the other player winning.'; end if;
    if di.id is not null and di.yes <> (st.home_goals + st.away_goals = coalesce(m.best_of, 3)) then
      return 'Your set score and "goes the distance" disagree.';
    end if;
  end if;
  if m.sport = 'mma' then
    if di.id is not null and me.id is not null and di.yes <> (me.pick = 'Decision') then return 'How it ends and "goes the distance" disagree.'; end if;
    if ro.id is not null and di.yes then return 'A finishing round means it does not go the distance.'; end if;
    if ro.id is not null and me.pick = 'Decision' then return 'A decision has no finishing round.'; end if;
  end if;
  return null;
end $$;

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
        v_team := (item->>'team_id')::int;
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then
          raise exception 'winner must be one of the two teams';
        end if;
      when 'draw', 'distance' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception '% call needs yes/no', ct; end if;
      when 'total' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'over/under call needs a side'; end if;
        if m.total_line is null then raise exception 'no line has been posted for this game yet'; end if;
        v_line := m.total_line;                -- always the line on the board, never the client's
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
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then
          raise exception 'margin must name one of the two sides';
        end if;
        if v_pick is null or not (mk.options ? v_pick) then raise exception 'unknown margin band %', v_pick; end if;
      when 'method' then
        v_pick := item->>'pick';
        if v_pick is null or not (mk.options ? v_pick) then raise exception 'unknown method %', v_pick; end if;
      when 'round' then
        v_pick := item->>'pick';
        if v_pick is null or v_pick !~ '^\d$' or v_pick::int not between 1 and coalesce(m.best_of, 3) then
          raise exception 'pick a round between 1 and %', coalesce(m.best_of, 3);
        end if;
      else
        v_player := (item->>'player_id')::int;
        if v_player is null or not exists (
          select 1 from players p where p.id = v_player and p.team_id in (m.home_team_id, m.away_team_id)
        ) then
          raise exception 'player must be in one of the two squads';
        end if;
    end case;

    insert into calls (entry_id, call_type, team_id, yes, player_id, home_goals, away_goals, pick, line)
    values (e_id, ct, v_team, v_yes, v_player, v_hg, v_ag, v_pick, v_line)
    on conflict (entry_id, call_type) do update
      set team_id = excluded.team_id, yes = excluded.yes, player_id = excluded.player_id,
          home_goals = excluded.home_goals, away_goals = excluded.away_goals,
          pick = excluded.pick, line = excluded.line;
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
  ev boolean; has_stats boolean; played boolean; top numeric; mine numeric;
  win_team int; total int; diff int;
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
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('red', 'yellow_red') and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'top_scorer' then
      if not final then r := 'pending';
      else
        select max(s.value) into top from player_stats s where s.match_id = m.id and s.stat = 'pts';
        select s.value into mine from player_stats s where s.match_id = m.id and s.stat = 'pts' and s.player_id = c.player_id;
        r := case when top is null or not played then 'void' when mine = top then 'hit' else 'miss' end;
      end if;
    when 'winner' then
      if not final then r := 'pending';
      elsif win_team is null then r := 'void';                              -- §2: void if drawn
      elsif c.team_id = win_team then r := 'hit'; else r := 'miss'; end if;
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
      elsif c.pick = method then r := 'hit'; else r := 'miss'; end if;
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
  points := case when r = 'hit' then mk.points * (case when boosted then 2 else 1 end) else 0 end;
  return next;
end $$;

revoke execute on function call_conflict(matches, uuid) from public, anon, authenticated;
grant execute on function call_conflict(matches, uuid) to service_role;
