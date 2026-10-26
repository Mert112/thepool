-- The Pool — a call nobody lands rolls its losses forward.
--
-- The multipliers are untouched: a correct call still returns stake × multiplier, minted. What
-- changes is where the *losing* stakes go. Until now they simply vanished.
--
--   · the pot on a call = the stakes actually lost on it (a void was refunded, a hit was paid)
--   · nobody correct on that call → the house takes a 10% rake and the rest becomes a jackpot,
--     held per competition per call type
--   · the next card in that competition shows "Jackpot: +N points" on the call while it is open
--   · the first card where somebody does land it shares the jackpot out among the winners, in
--     proportion to what they staked, on top of their multiplier payout
--   · nobody lands it again → that card's pot is added and the jackpot compounds
--
-- Stakes drop to 1, 2, 5, 10, 25, 50: a point is now a real unit, and a card can be played for
-- almost nothing.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Stakes from a single point
-- ---------------------------------------------------------------------------
delete from stakes where amount in (100, 200);
insert into stakes (amount, sort_order) values (1, 1), (2, 2), (5, 3)
  on conflict (amount) do nothing;
update stakes set sort_order = v.o from (values (1, 1), (2, 2), (5, 3), (10, 4), (25, 5), (50, 6)) as v(a, o)
 where stakes.amount = v.a;

-- ---------------------------------------------------------------------------
-- 2. The jackpot, and an audit trail for every point that moves through it
-- ---------------------------------------------------------------------------
create table jackpots (
  competition_code text not null references competitions(code) on delete cascade,
  call_type        call_type not null,
  amount           int not null default 0 check (amount >= 0),
  updated_at       timestamptz not null default now(),
  primary key (competition_code, call_type)
);

-- One row per card per call type per kind of movement, so a jackpot can always be explained and a
-- re-settlement can never roll the same pot forward twice.
create table jackpot_moves (
  id               bigserial primary key,
  competition_code text not null references competitions(code) on delete cascade,
  call_type        call_type not null,
  card_id          uuid not null references cards(id) on delete cascade,
  kind             text not null check (kind in ('rollover', 'rake', 'payout')),
  amount           int  not null,     -- what the jackpot gained; a payout is negative
  created_at       timestamptz not null default now(),
  unique (card_id, call_type, kind)
);
create index jackpot_moves_pot_idx on jackpot_moves(competition_code, call_type, created_at desc);

-- the ledger gains one more reason: a player's share of a jackpot
alter table ledger drop constraint ledger_reason_check;
alter table ledger add constraint ledger_reason_check
  check (reason in ('signup', 'stake', 'win', 'refund', 'ad_reward', 'prize', 'jackpot'));

create or replace function jackpot_of(p_competition text, p_call_type call_type) returns int
language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce((select amount from jackpots
                   where competition_code = p_competition and call_type = p_call_type), 0)
$$;

-- ---------------------------------------------------------------------------
-- 3. Settling one call type on one card against the jackpot
--
-- A jackpot is a sequence across cards in time, so a card's part in it is decided once — the first
-- time it settles final — and never revised, including when the decision was "nothing moved". That
-- last part matters: without it, a card re-settled after a correction would be judged against
-- today's jackpot and could scoop a pot that a *later* card had since rolled in.
--
-- So a provider correction still re-scores the card and adjusts the multiplier payouts through the
-- ledger, but it never moves the jackpot. `jackpot_moves` carries a row for every decision, zero
-- included, and is the record of what was decided and when.
-- ---------------------------------------------------------------------------
create or replace function settle_jackpot(p_card uuid, p_call_type call_type) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  comp text; pot int; rake int; rolled int; jack int; won int; paid int := 0; share int;
  r record;
begin
  -- decided once per card per call type
  if exists (select 1 from jackpot_moves where card_id = p_card and call_type = p_call_type) then
    return;
  end if;
  select m.competition_code into comp
    from cards cd join matches m on m.id = cd.match_id where cd.id = p_card;
  if comp is null then return; end if;

  select coalesce(sum(c.stake) filter (where c.result = 'hit'), 0)
    into won
    from calls c join entries e on e.id = c.entry_id
   where e.card_id = p_card and c.call_type = p_call_type and c.staked;

  if won > 0 then
    -- somebody landed it: the standing jackpot goes to them, in proportion to what they staked
    jack := jackpot_of(comp, p_call_type);
    if jack > 0 then
      for r in
        select c.id as call_id, e.user_id, c.stake
          from calls c join entries e on e.id = c.entry_id
         where e.card_id = p_card and c.call_type = p_call_type and c.staked and c.result = 'hit'
         order by c.stake desc, c.id
      loop
        -- floor each share; the few points left over stay in the pot rather than being invented
        share := (jack::bigint * r.stake / won)::int;
        if share > 0 then
          perform apply_ledger(r.user_id, 'jackpot', r.call_id::text, share);
          paid := paid + share;
        end if;
      end loop;
    end if;
    -- recorded even when the jackpot was empty, so this card is never judged again
    insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
    values (comp, p_call_type, p_card, 'payout', -paid);
    if paid > 0 then
      update jackpots set amount = amount - paid, updated_at = now()
       where competition_code = comp and call_type = p_call_type;
    end if;
    return;
  end if;

  -- nobody landed it: what was actually lost rolls forward, less the rake
  select coalesce(sum(c.stake) filter (where c.result = 'miss'), 0)
    into pot
    from calls c join entries e on e.id = c.entry_id
   where e.card_id = p_card and c.call_type = p_call_type and c.staked;
  rake   := round(pot * 0.10)::int;
  rolled := pot - rake;
  insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
  values (comp, p_call_type, p_card, 'rake', rake);
  insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
  values (comp, p_call_type, p_card, 'rollover', rolled);
  if rolled > 0 then
    insert into jackpots (competition_code, call_type, amount)
    values (comp, p_call_type, rolled)
    on conflict (competition_code, call_type) do update
      set amount = jackpots.amount + excluded.amount, updated_at = now();
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Settlement runs it for every call type that was played on the card
-- ---------------------------------------------------------------------------
create or replace function settle_match(p_match int, p_final boolean)
returns table (calls_changed int, entries_changed int)
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  m matches; rec record; sc record;
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
    select * into sc from score_call(rec.call, m);
    if sc.result is distinct from (rec.call).result or sc.points is distinct from (rec.call).points_awarded then
      update calls set result = sc.result, points_awarded = sc.points,
             settled_at = case when sc.result = 'pending' then null else now() end
       where id = (rec.call).id;
      perform sync_call_money((rec.call).id);
      n_calls := n_calls + 1;
    end if;
  end loop;

  -- the jackpot is decided before the entries are totalled, so a share counts on the card it fell on
  if p_final then
    for rec in
      select distinct cd.id as card_id, c.call_type
        from calls c join entries e on e.id = c.entry_id join cards cd on cd.id = e.card_id
       where cd.match_id = p_match and c.staked
    loop
      perform settle_jackpot(rec.card_id, rec.call_type);
    end loop;
  end if;

  for rec in
    select e.id, e.user_id, e.points as old_points, e.hits as old_hits, e.card_id, cd.crew_id,
           (coalesce(sum(c.points_awarded), 0)
            + coalesce(sum(c.stake) filter (where c.staked and c.result = 'void'), 0)
            - coalesce(sum(c.stake) filter (where c.staked), 0)
            + coalesce((select sum(l.amount) from ledger l
                        where l.reason = 'jackpot'
                          and l.reference in (select k.id::text from calls k where k.entry_id = e.id)), 0))::int as pts,
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
-- 5. The stake message, now that a point will do
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
  bal int; elsewhere int; here int;
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
    insert into calls (entry_id, call_type, team_id, yes, player_id, home_goals, away_goals, pick, line, stake, multiplier)
    values (e_id, ct, v_team, v_yes, v_player, v_hg, v_ag, v_pick, v_line, v_stake, call_multiplier(mk, v_pick))
    on conflict (entry_id, call_type) do update
      set team_id = excluded.team_id, yes = excluded.yes, player_id = excluded.player_id,
          home_goals = excluded.home_goals, away_goals = excluded.away_goals,
          pick = excluded.pick, line = excluded.line,
          stake = excluded.stake, multiplier = excluded.multiplier;
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
      bal, here, elsewhere;
  end if;
  return e_id;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Access
-- ---------------------------------------------------------------------------
alter table jackpots      enable row level security;
alter table jackpot_moves enable row level security;
create policy "public read" on jackpots      for select using (true);
create policy "public read" on jackpot_moves for select using (true);
grant select on jackpots, jackpot_moves to anon, authenticated;
grant all on jackpots, jackpot_moves to service_role;
grant usage, select on sequence jackpot_moves_id_seq to service_role;

revoke execute on function settle_jackpot(uuid, call_type) from public, anon, authenticated;
grant execute on function settle_jackpot(uuid, call_type) to service_role;
grant execute on function jackpot_of(text, call_type) to anon, authenticated;

notify pgrst, 'reload schema';
