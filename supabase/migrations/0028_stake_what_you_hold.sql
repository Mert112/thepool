-- The Pool — stake whatever you hold, and no handicap.
--
--   · 0027 capped one stake at half of what the others had in the pot, plus 10. On a fresh card
--     that meant 10 at most, and the free-amount field looked like it did nothing. The cap is gone:
--     a stake is any whole number of points from 1 up to what the player has free (balance less
--     what other open cards already promise). That check, and the whole-card total, stay
--   · the handicap call is switched off. Its four settled calls keep their history and their
--     settlement code; nothing open held one (checked in production before this ran). The
--     market row stays, disabled, like motm and the other retired ones, so it can come back
set search_path = pool, public, extensions;

update markets set enabled = false where sport = 'soccer' and call_type = 'spread';

drop function if exists stake_cap(uuid, call_type, uuid);

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
  bal numeric; elsewhere numeric; here numeric; playable numeric;
  raw numeric;
  v_team int; v_player int; v_yes boolean; v_hg int; v_ag int; v_pick text; v_line numeric; v_stake int;
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
  select balance into bal from profiles where id = u;
  elsewhere := committed_stake(u, e_id);
  playable := floor(bal - elsewhere);
  for item in select * from jsonb_array_elements(coalesce(p_calls, '[]'::jsonb)) loop
    ct := (item->>'call_type')::call_type;
    select * into mk from markets where sport = 'soccer' and call_type = ct;
    if mk is null or not mk.enabled then raise exception 'call % is not available', ct; end if;
    if c.mode = 'simple' and not mk.simple then raise exception 'call % is not on a simple card', ct; end if;
    if ct = any(kept) then raise exception 'duplicate call %', ct; end if;

    -- the stake: a whole number from 1, no more than is free
    if item ? 'stake' and jsonb_typeof(item->'stake') <> 'number' then
      raise exception 'A stake is a whole number of points — not %', item->>'stake';
    end if;
    raw := coalesce((item->>'stake')::numeric, 10);
    if raw <> trunc(raw) or raw < 1 then
      raise exception 'A stake is a whole number of points — not %', trim_scale(raw);
    end if;
    if raw > playable then
      raise exception 'You can stake at most % on one call — that is what you have free.', greatest(playable, 0);
    end if;
    v_stake := raw::int;

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
        v_line := case when v_team = m.home_team_id then hl else -hl end;
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
        v_pick := nullif(item->>'pick', '');
        if v_pick is not null and (ct <> 'red' or not coalesce(mk.options ? v_pick, false)) then
          raise exception 'unknown time window %', v_pick;
        end if;
    end case;
    insert into calls (entry_id, call_type, team_id, yes, player_id, home_goals, away_goals, pick, line, stake)
    values (e_id, ct, v_team, v_yes, v_player, v_hg, v_ag, v_pick, v_line, v_stake)
    on conflict (entry_id, call_type) do update
      set team_id = excluded.team_id, yes = excluded.yes, player_id = excluded.player_id,
          home_goals = excluded.home_goals, away_goals = excluded.away_goals,
          pick = excluded.pick, line = excluded.line, stake = excluded.stake;
    kept := kept || ct;
  end loop;
  delete from calls where entry_id = e_id and not (call_type = any(kept));
  if cardinality(kept) = 0 then
    delete from entries where id = e_id;
    return null;
  end if;
  conflict := call_conflict(m, e_id);
  if conflict is not null then raise exception '%', conflict; end if;
  select coalesce(sum(stake), 0) into here from calls where entry_id = e_id;
  if elsewhere + here > bal then
    raise exception 'Not enough points: you hold %, this card stakes %, and % is already promised to other open cards. Lower a stake or drop a call.',
      trim_scale(bal), trim_scale(here), trim_scale(elsewhere);
  end if;
  return e_id;
end $$;

notify pgrst, 'reload schema';
