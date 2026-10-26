-- The Pool — the pot pays, not the house.
--
-- 0019 minted points: a correct call returned stake × a fixed multiplier, conjured from nowhere.
-- That ends here. Every stake on a call type goes into one pot for that card, and the pot is all
-- there is to win.
--
--   · at final settlement a void is refunded in full and leaves the pot entirely
--   · 10% of what remains is the house's rake, recorded in the ledger
--   · the other 90%, plus any standing jackpot, is split among the correct calls in proportion to
--     what they staked, rounded down to the point of a point
--   · what rounding leaves behind goes to the jackpot rather than being invented or kept
--   · nobody correct and the whole 90% rolls into the competition's jackpot, exactly as before
--
-- Nothing mints any more. A balance can only rise four ways: the 100-point season start, a 0.5
-- point ad credit, a share of a pot, and a share of a jackpot. Everything else is players' money
-- moving between players, or the rake leaving for the house. The conservation test in
-- tests/economy_test.sql holds the line.
--
-- Money becomes numeric(14,2), because half a point is now a real amount.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Money gets a decimal point
-- ---------------------------------------------------------------------------
drop view v_entry_points;

alter table profiles     alter column balance        type numeric(14,2),
                         alter column balance        set default 100;
alter table ledger       alter column amount         type numeric(14,2);
alter table calls        alter column points_awarded type numeric(14,2);
alter table entries      alter column points         type numeric(14,2);
alter table jackpots     alter column amount         type numeric(14,2);
alter table jackpot_moves alter column amount        type numeric(14,2);
alter table ad_views     alter column reward         type numeric(14,2);
alter table prize_claims alter column balance_at_claim type numeric(14,2);

-- stakes stay whole: the six options are whole points, and a pot of whole numbers still splits
-- into fractions on the way out
create or replace function round_down2(x numeric) returns numeric
language sql immutable as $$ select floor(x * 100) / 100 $$;

-- 0020 declared this int; a jackpot now holds halves, and reading one as a rounded whole would
-- quietly pay out more than the jackpot contains
drop function if exists jackpot_of(text, call_type);
create function jackpot_of(p_competition text, p_call_type call_type) returns numeric
language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce((select amount from jackpots
                   where competition_code = p_competition and call_type = p_call_type), 0)
$$;
grant execute on function jackpot_of(text, call_type) to anon, authenticated;

create view v_entry_points with (security_invoker = true) as
select e.id as entry_id, e.user_id, e.card_id, c.crew_id, c.match_id, c.mode, c.status as card_status,
       m.competition_code, m.season, e.matchday, m.utc_date, e.points, e.hits,
       (select count(*) from calls k where k.entry_id = e.id) as n_calls,
       (select coalesce(sum(k.stake), 0) from calls k where k.entry_id = e.id) as staked
from entries e
join cards c on c.id = e.card_id
join matches m on m.id = c.match_id;
grant select on v_entry_points to authenticated;

-- ---------------------------------------------------------------------------
-- 2. A new season: everyone starts on 100
-- ---------------------------------------------------------------------------
insert into ledger (user_id, amount, reason, reference)
select id, 100 - balance, 'adjustment', 'season-2026-pari-mutuel'
from profiles where balance <> 100;
update profiles set balance = 100 where balance <> 100;

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  insert into profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  insert into notification_settings (user_id) values (new.id) on conflict (user_id) do nothing;
  insert into ledger (user_id, amount, reason, reference) values (new.id, 100, 'signup', new.id::text);
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 3. The ledger gains the house, and loses minting
-- ---------------------------------------------------------------------------
-- the house is not a player, so its rows carry no user
alter table ledger alter column user_id drop not null;
alter table ledger drop constraint ledger_reason_check;
alter table ledger add constraint ledger_reason_check
  check (reason in ('signup', 'adjustment', 'stake', 'pot', 'jackpot', 'refund', 'ad_reward', 'prize', 'house'));
alter table ledger add constraint ledger_house_has_no_user
  check ((reason = 'house') = (user_id is null));

create or replace function credit_house(p_reference text, p_target numeric) returns numeric
language plpgsql security definer set search_path = pool, public, extensions as $$
declare already numeric; delta numeric;
begin
  select coalesce(sum(amount), 0) into already from ledger where reason = 'house' and reference = p_reference;
  delta := p_target - already;
  if delta = 0 then return 0; end if;
  insert into ledger (user_id, amount, reason, reference) values (null, delta, 'house', p_reference);
  return delta;
end $$;

drop function if exists apply_ledger(uuid, text, text, int);
create function apply_ledger(p_user uuid, p_reason text, p_reference text, p_target numeric)
returns numeric language plpgsql security definer set search_path = pool, public, extensions as $$
declare already numeric; delta numeric;
begin
  select coalesce(sum(amount), 0) into already from ledger
   where user_id = p_user and reason = p_reason and reference = p_reference;
  delta := p_target - already;
  if delta = 0 then return 0; end if;
  insert into ledger (user_id, amount, reason, reference) values (p_user, delta, p_reason, p_reference);
  update profiles set balance = balance + delta where id = p_user;
  return delta;
end $$;

-- the multipliers go, and with them the last thing that could conjure a point
alter table markets drop column multiplier;
alter table markets drop column pick_multiplier;
alter table markets drop column option_mult;
alter table calls   drop column multiplier;
drop function if exists call_multiplier(markets, text);

-- the red card's window no longer buys a bigger price; it buys a smaller field to share with
update markets set explainer = 'Name one player to be sent off, by a straight red or a second yellow; add a 15-minute window to narrow the call — fewer people will be right, so the pot splits fewer ways.'
 where call_type = 'red';
update markets set explainer = 'Pick home, draw or away: whoever is ahead after 90 minutes plus stoppage time, with extra time and penalties ignored.'
 where call_type = 'winner';

-- ---------------------------------------------------------------------------
-- 4. Scoring decides only what happened; the pot decides what it is worth
-- ---------------------------------------------------------------------------
drop function if exists score_call(calls, matches);
create function score_call(c calls, m matches) returns call_result
language plpgsql stable set search_path = pool, public, extensions as $$
declare
  r call_result := 'pending'; final boolean := m.status in ('FINISHED', 'AWARDED');
  ev boolean; has_stats boolean; played boolean;
  total int; cover numeric;
begin
  if not c.staked and c.created_at >= economy_start() and m.utc_date <= now() then
    return 'void';
  end if;
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
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('red', 'yellow_red') and e.player_id = c.player_id
                       and (c.pick is null or band_contains(c.pick, e.minute))) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'winner' then
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
      elsif total is null or c.line is null or total = c.line then r := 'void';
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
  return r;
end $$;

-- a call's own money: the stake out at lock, the stake back if it voided. Nothing else.
create or replace function sync_call_money(p_call uuid) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare k calls; u uuid;
begin
  select * into k from calls where id = p_call;
  if k is null then return; end if;
  select e.user_id into u from entries e where e.id = k.entry_id;
  perform apply_ledger(u, 'stake',  p_call::text, case when k.staked then -k.stake else 0 end);
  perform apply_ledger(u, 'refund', p_call::text, case when k.staked and k.result = 'void' then k.stake else 0 end);
end $$;

-- saving a card: the stake is the only number a call carries now
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
  bal numeric; elsewhere numeric; here numeric;
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
  for item in select * from jsonb_array_elements(coalesce(p_calls, '[]'::jsonb)) loop
    ct := (item->>'call_type')::call_type;
    select * into mk from markets where sport = 'soccer' and call_type = ct;
    if mk is null or not mk.enabled then raise exception 'call % is not available', ct; end if;
    if c.mode = 'simple' and not mk.simple then raise exception 'call % is not on a simple card', ct; end if;
    if ct = any(kept) then raise exception 'duplicate call %', ct; end if;
    v_stake := coalesce((item->>'stake')::int, 10);
    if not exists (select 1 from stakes where amount = v_stake) then
      raise exception 'a stake is 1, 2, 5, 10, 25 or 50 points — not %', v_stake;
    end if;
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
  select balance into bal from profiles where id = u;
  elsewhere := committed_stake(u, e_id);
  select coalesce(sum(stake), 0) into here from calls where entry_id = e_id;
  if elsewhere + here > bal then
    raise exception 'Not enough points: you hold %, this card stakes %, and % is already promised to other open cards. Lower a stake or drop a call.',
      trim_scale(bal), trim_scale(here), trim_scale(elsewhere);
  end if;
  return e_id;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Settling one pot
--
-- Decided once, the first time the card settles final, and recorded in jackpot_moves — a zero row
-- included, because a jackpot is a sequence across cards in time and a card re-judged later could
-- otherwise scoop a pot that a later card had rolled in.
-- ---------------------------------------------------------------------------
create or replace function settle_pot(p_card uuid, p_call_type call_type) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  comp text; pot numeric := 0; rake numeric; net numeric; jack numeric; won numeric := 0;
  paid_pot numeric := 0; paid_jack numeric := 0; remainder numeric; r record;
  pot_share numeric; jack_share numeric;
begin
  if exists (select 1 from jackpot_moves where card_id = p_card and call_type = p_call_type) then
    return;
  end if;
  select m.competition_code into comp
    from cards cd join matches m on m.id = cd.match_id where cd.id = p_card;
  if comp is null then return; end if;

  -- a void left the pot entirely; its stake was handed straight back
  select coalesce(sum(c.stake) filter (where c.result in ('hit', 'miss')), 0),
         coalesce(sum(c.stake) filter (where c.result = 'hit'), 0)
    into pot, won
    from calls c join entries e on e.id = c.entry_id
   where e.card_id = p_card and c.call_type = p_call_type and c.staked;

  if pot = 0 then
    insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
    values (comp, p_call_type, p_card, 'rollover', 0);
    return;
  end if;

  rake := round_down2(pot * 0.10);
  net  := pot - rake;
  perform credit_house(p_card::text || ':' || p_call_type::text, rake);

  if won = 0 then
    -- nobody was right: the whole 90% rolls into the competition's jackpot
    insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
    values (comp, p_call_type, p_card, 'rollover', net);
    insert into jackpots (competition_code, call_type, amount) values (comp, p_call_type, net)
    on conflict (competition_code, call_type) do update
      set amount = jackpots.amount + excluded.amount, updated_at = now();
    return;
  end if;

  jack := jackpot_of(comp, p_call_type);
  for r in
    select c.id as call_id, e.user_id, c.stake
      from calls c join entries e on e.id = c.entry_id
     where e.card_id = p_card and c.call_type = p_call_type and c.staked and c.result = 'hit'
     order by c.stake desc, c.id
  loop
    pot_share  := round_down2(net  * r.stake / won);
    jack_share := round_down2(jack * r.stake / won);
    if pot_share  > 0 then perform apply_ledger(r.user_id, 'pot',     r.call_id::text, pot_share);  end if;
    if jack_share > 0 then perform apply_ledger(r.user_id, 'jackpot', r.call_id::text, jack_share); end if;
    update calls set points_awarded = pot_share + jack_share where id = r.call_id;
    paid_pot  := paid_pot  + pot_share;
    paid_jack := paid_jack + jack_share;
  end loop;

  -- the jackpot is emptied, and whatever rounding left behind goes straight back into it.
  -- Emptying and refilling are two statements: a single upsert of (remainder - jack) would be
  -- checked against amount >= 0 as a proposed row, before the conflict that makes it a subtraction.
  if jack > 0 then
    insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
    values (comp, p_call_type, p_card, 'payout', -jack);
    update jackpots set amount = amount - jack, updated_at = now()
     where competition_code = comp and call_type = p_call_type;
  end if;
  remainder := (net - paid_pot) + (jack - paid_jack);
  insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
  values (comp, p_call_type, p_card, 'rollover', remainder);
  if remainder > 0 then
    insert into jackpots (competition_code, call_type, amount) values (comp, p_call_type, remainder)
    on conflict (competition_code, call_type) do update
      set amount = jackpots.amount + excluded.amount, updated_at = now();
  end if;
end $$;

drop function if exists settle_jackpot(uuid, call_type);

-- ---------------------------------------------------------------------------
-- 6. Settlement
-- ---------------------------------------------------------------------------
create or replace function settle_match(p_match int, p_final boolean)
returns table (calls_changed int, entries_changed int)
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  m matches; rec record; sc call_result;
  n_calls int := 0; n_entries int := 0; rerun boolean;
begin
  select * into m from matches where id = p_match;
  if m is null then raise exception 'unknown match'; end if;
  if p_final and m.status not in ('FINISHED', 'AWARDED') then
    raise exception 'match % is not finished', p_match;
  end if;
  if not p_final then m.status := 'IN_PLAY'; end if;
  rerun := p_final and m.settled_at is not null;

  for rec in
    select c as call from calls c join entries e on e.id = c.entry_id
    join cards cd on cd.id = e.card_id
    where cd.match_id = p_match
  loop
    sc := score_call(rec.call, m);
    if sc is distinct from (rec.call).result then
      update calls set result = sc,
             settled_at = case when sc = 'pending' then null else now() end
       where id = (rec.call).id;
      perform sync_call_money((rec.call).id);
      n_calls := n_calls + 1;
    end if;
  end loop;

  -- the pots pay out before the entries are totalled, so a share counts on the card it fell on
  if p_final then
    for rec in
      select distinct cd.id as card_id, c.call_type
        from calls c join entries e on e.id = c.entry_id join cards cd on cd.id = e.card_id
       where cd.match_id = p_match and c.staked
    loop
      perform settle_pot(rec.card_id, rec.call_type);
    end loop;
  end if;

  for rec in
    select e.id, e.user_id, e.points as old_points, e.hits as old_hits, e.card_id, cd.crew_id,
           (coalesce((select sum(l.amount) from ledger l
                      where l.reason in ('pot', 'jackpot', 'refund')
                        and l.reference in (select k.id::text from calls k where k.entry_id = e.id)), 0)
            - coalesce(sum(c.stake) filter (where c.staked), 0)) as pts,
           coalesce(count(*) filter (where c.result = 'hit'), 0)::int as hits
    from entries e join cards cd on cd.id = e.card_id
    left join calls c on c.entry_id = e.id
    where cd.match_id = p_match
    group by e.id, e.user_id, e.points, e.hits, e.card_id, cd.crew_id
  loop
    if rec.pts <> rec.old_points or rec.hits <> rec.old_hits then
      update entries set points = rec.pts, hits = rec.hits where id = rec.id;
      n_entries := n_entries + 1;
      if rerun then
        insert into notifications (user_id, type, dedupe_key, payload)
        values (rec.user_id, 'correction', p_match || ':' || (m.settlement_version + 1),
                jsonb_build_object('match_id', p_match, 'card_id', rec.card_id, 'from', rec.old_points, 'to', rec.pts))
        on conflict do nothing;
      end if;
    end if;
  end loop;

  if not p_final then
    return query select n_calls, n_entries; return;
  end if;

  update cards set status = 'settled', settled_at = coalesce(settled_at, now()), locked_at = coalesce(locked_at, now())
   where match_id = p_match;

  insert into stickers (user_id, competition_code, season, call_type, match_id)
  select e.user_id, m.competition_code, coalesce(m.season, 'unknown'), c.call_type, p_match
  from calls c join entries e on e.id = c.entry_id join cards cd on cd.id = e.card_id
  where cd.match_id = p_match and c.result = 'hit'
  on conflict do nothing;

  insert into crew_posts (crew_id, user_id, call_id)
  select cd.crew_id, e.user_id, c.id
  from calls c join entries e on e.id = c.entry_id join cards cd on cd.id = e.card_id
  where cd.match_id = p_match and cd.crew_id is not null and c.result = 'hit'
    and not exists (select 1 from crew_posts p where p.call_id = c.id);

  perform recompute_streak(e.user_id)
  from (select distinct e.user_id from entries e join cards cd on cd.id = e.card_id where cd.match_id = p_match) e;

  insert into notifications (user_id, type, dedupe_key, payload)
  select e.user_id, 'result', p_match::text || ':' || cd.id, jsonb_build_object('match_id', p_match, 'card_id', cd.id)
  from entries e join cards cd on cd.id = e.card_id
  join notification_settings ns on ns.user_id = e.user_id
  where cd.match_id = p_match and ns.result
  on conflict do nothing;

  update matches set settled_at = greatest(clock_timestamp(), coalesce(provider_updated, clock_timestamp())),
                     settlement_version = settlement_version + 1
   where id = p_match;

  return query select n_calls, n_entries;
end $$;

-- ---------------------------------------------------------------------------
-- 7. What a pick is worth right now (§4): the pot on each call, and what a point
--    staked on each pick would return if that pick came in at the current split
-- ---------------------------------------------------------------------------
create or replace function card_pots(p_card uuid)
returns table (call_type call_type, key text, label text, pick_stake numeric,
               pot numeric, jackpot numeric, purse numeric, per_point numeric)
language sql stable security definer set search_path = pool, public, extensions as $$
  with m as (select mt.* from cards cd join matches mt on mt.id = cd.match_id where cd.id = p_card),
  picks as (
    select c.call_type, call_label(c, m.*) as label,
      case c.call_type
        when 'winner' then coalesce(c.team_id::text, 'draw')
        when 'draw'   then c.yes::text
        when 'total'  then c.yes::text
        when 'spread' then c.team_id::text
        when 'score'  then c.home_goals || '-' || c.away_goals
        when 'red'    then c.player_id || ':' || coalesce(c.pick, 'any')
        else c.player_id::text end as key,
      c.stake
    from calls c
    join entries e on e.id = c.entry_id
    cross join m
    where e.card_id = p_card
  ),
  pots as (select picks.call_type, sum(picks.stake) as pot from picks group by picks.call_type),
  by_pick as (select picks.call_type, picks.key, min(picks.label) as label, sum(picks.stake) as pick_stake
              from picks group by picks.call_type, picks.key)
  select b.call_type, b.key, b.label, b.pick_stake,
         p.pot,
         jackpot_of((select competition_code from m), b.call_type) as jackpot,
         round_down2(p.pot * 0.90) + jackpot_of((select competition_code from m), b.call_type) as purse,
         round_down2((round_down2(p.pot * 0.90) + jackpot_of((select competition_code from m), b.call_type)) / b.pick_stake) as per_point
  from by_pick b join pots p on p.call_type = b.call_type
  where can_see_card(p_card)
  order by b.call_type, b.pick_stake desc;
$$;

-- ---------------------------------------------------------------------------
-- 8. An ad is worth half a point now
-- ---------------------------------------------------------------------------
create or replace function rpc_watch_ad() returns jsonb
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); d date := (now() at time zone 'utc')::date; n int; v uuid;
begin
  if not coalesce((select enabled from app_flags where key = 'rewarded_ads'), false) then
    raise exception 'Getting points by watching an ad is switched off right now.';
  end if;
  select count(*) into n from ad_views where user_id = u and day = d;
  if n >= 10 then
    raise exception 'That is all ten of today''s ads. The counter resets at midnight UTC.';
  end if;
  begin
    insert into ad_views (user_id, day, seq, reward) values (u, d, n + 1, 0.5) returning id into v;
  exception when unique_violation or check_violation then
    raise exception 'That is all ten of today''s ads. The counter resets at midnight UTC.';
  end;
  perform apply_ledger(u, 'ad_reward', v::text, 0.5);
  return jsonb_build_object('credited', 0.5, 'watched_today', n + 1, 'left_today', 10 - (n + 1),
                            'balance', (select balance from profiles where id = u));
end $$;

create or replace function rpc_claim_prize() returns uuid
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); bal numeric; new_id uuid;
begin
  select balance into bal from profiles where id = u;
  if bal < 1000000 then
    raise exception 'A PlayStation 5 takes 1,000,000 points. You hold %.', trim_scale(bal);
  end if;
  if exists (select 1 from prize_claims where user_id = u and status = 'pending') then
    raise exception 'Your claim is already with us — we will be in touch by email.';
  end if;
  insert into prize_claims (user_id, balance_at_claim) values (u, bal) returning id into new_id;
  return new_id;
end $$;

drop function if exists my_ledger(int);
create function my_ledger(p_limit int default 30)
returns table (amount numeric, reason text, created_at timestamptz)
language sql stable security definer set search_path = pool, public, extensions as $$
  select l.amount, l.reason, l.created_at from ledger l
  where l.user_id = require_user()
  order by l.created_at desc, l.id desc
  limit greatest(1, least(p_limit, 200))
$$;

-- ---------------------------------------------------------------------------
-- 9. Read models carry decimals
-- ---------------------------------------------------------------------------
-- function bodies are not tracked as dependencies, so these drop and recreate cleanly
drop function if exists committed_stake(uuid, uuid);
create function committed_stake(p_user uuid, p_except_entry uuid default null) returns numeric
language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce(sum(k.stake), 0)::numeric
  from calls k join entries e on e.id = k.entry_id join cards cd on cd.id = e.card_id
  where e.user_id = p_user and cd.status = 'open' and not k.staked
    and (p_except_entry is null or e.id <> p_except_entry)
$$;
drop function if exists my_committed_stake();
create function my_committed_stake() returns numeric
language sql stable security definer set search_path = pool, public, extensions as $$
  select committed_stake(require_user(), null)
$$;

drop function if exists crew_score(uuid, text);
create function crew_score(p_crew uuid, p_season text default null)
returns numeric language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce(sum(e.points), 0)
  from entries e join cards c on c.id = e.card_id join matches m on m.id = c.match_id
  where c.crew_id = p_crew and c.status in ('settled', 'disputed')
    and (p_season is null or m.season = p_season)
$$;

drop function if exists leaderboard(text, text, text);
create function leaderboard(p_scope text, p_key text default null, p_season text default null)
returns table (
  user_id uuid, display_name text, balance numeric, points numeric, points_prev numeric, cards bigint,
  hits bigint, calls bigint, hit_rate numeric, best_call call_type, best_points numeric
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
  ),
  people as (
    select p.id as user_id, p.display_name, p.balance from profiles p
    where p_scope = 'overall' or p.id in (select agg.user_id from agg)
  )
  select pe.user_id, pe.display_name, pe.balance,
         coalesce(a.points, 0), coalesce(a.points_prev, 0), coalesce(a.cards, 0), coalesce(a.hits, 0),
         coalesce(n.calls, 0),
         case when coalesce(n.calls, 0) = 0 then 0 else round(100.0 * a.hits / n.calls, 0) end,
         b.call_type, b.points_awarded
  from people pe
  left join agg a on a.user_id = pe.user_id
  left join ncalls n on n.user_id = pe.user_id
  left join best b on b.user_id = pe.user_id
  order by case when p_scope = 'overall' then pe.balance else coalesce(a.points, 0) end desc,
           coalesce(a.hits, 0) desc, pe.display_name;
end $$;

create or replace function my_stats(p_season text default null)
returns jsonb language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare u uuid := auth.uid(); res jsonb;
begin
  with lb as (select *, row_number() over (order by balance desc, points desc, display_name) as rank
              from leaderboard('overall', null, p_season)),
  me as (select * from lb where user_id = u),
  comps as (
    select cp.code, cp.name, x.points, x.rank from competitions cp
    cross join lateral (
      select l.points, row_number() over (order by l.points desc, l.hits desc) as rank, l.user_id
      from leaderboard('competition', cp.code, p_season) l
    ) x where x.user_id = u
  )
  select jsonb_build_object(
    'balance', coalesce((select balance from profiles where id = u), 0),
    'points', coalesce((select points from me), 0),
    'rank', (select rank from me),
    'players', (select count(*) from lb),
    'cards', coalesce((select cards from me), 0),
    'hit_rate', coalesce((select hit_rate from me), 0),
    'streak', (select streak from profiles where id = u),
    'committed', committed_stake(u),
    'ads_today', ads_today(u),
    'ads_left', 10 - ads_today(u),
    'ad_reward', 0.5,
    'ads_enabled', coalesce((select enabled from app_flags where key = 'rewarded_ads'), false),
    'prize_target', 1000000,
    'prize_claim', (select jsonb_build_object('id', id, 'status', status, 'created_at', created_at)
                    from prize_claims where user_id = u order by created_at desc limit 1),
    'competitions', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'points', points, 'rank', rank) order by points desc) from comps), '[]'::jsonb),
    'recent', '[]'::jsonb
  ) into res;
  return res;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Access
-- ---------------------------------------------------------------------------
revoke execute on function apply_ledger(uuid, text, text, numeric), credit_house(text, numeric),
  sync_call_money(uuid), settle_pot(uuid, call_type), committed_stake(uuid, uuid),
  score_call(calls, matches), settle_match(int, boolean), round_down2(numeric)
  from public, anon, authenticated;
grant execute on function apply_ledger(uuid, text, text, numeric), credit_house(text, numeric),
  sync_call_money(uuid), settle_pot(uuid, call_type), committed_stake(uuid, uuid),
  score_call(calls, matches), settle_match(int, boolean), round_down2(numeric)
  to service_role;
grant execute on function leaderboard(text, text, text), my_stats(text), crew_score(uuid, text),
  my_ledger(int), my_committed_stake(), card_pots(uuid) to authenticated;

notify pgrst, 'reload schema';
