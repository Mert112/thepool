-- The Pool — points become a currency.
--
-- Until now a landed call simply minted points: there was nothing to lose, so a card cost nothing
-- to fill and a score meant only "how often was I right". This replaces that outright.
--
--   · everyone starts with 1,000 points (profiles.balance)
--   · every call carries a stake the player picks: 10, 25, 50, 100 or 200
--   · the stake leaves the balance when the card locks at kick-off, not when it is saved
--   · a landed call returns stake × the call's multiplier; a wrong one returns nothing;
--     a void one (the result on a draw, a push on the goals line, a player who never came on)
--     gives the stake back
--   · multipliers: result 1.5 (the draw 3) · handicap 2 · over/under 2 · exact scoreline 8 ·
--     goalscorer 4 · assist 6 · yellow 3 · red 10 (× the window factor when one is named)
--   · every movement is one row in an append-only ledger, written only by these functions
--   · 1,000,000 points claims a PlayStation 5
--
-- The boost goes with the old model. A free doubling of one call a day is exactly the minting this
-- migration removes, and the stake is the lever now: 10 → 200 is a twentyfold swing, chosen per call.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Balances and the ledger
-- ---------------------------------------------------------------------------
alter table profiles add column balance int not null default 1000;

create table ledger (
  id         bigserial primary key,
  user_id    uuid not null references profiles(id) on delete cascade,
  amount     int  not null check (amount <> 0),   -- signed; the running sum is the balance
  reason     text not null check (reason in ('signup', 'stake', 'win', 'refund', 'ad_reward', 'prize')),
  reference  text,                                 -- the call, the ad view or the claim it belongs to
  created_at timestamptz not null default now()
);
create index ledger_user_idx on ledger(user_id, created_at desc);
create index ledger_ref_idx  on ledger(reason, reference);

-- append-only: nothing rewrites history, not even the service role
create or replace function ledger_is_append_only() returns trigger
language plpgsql set search_path = pool, public, extensions as $$
begin raise exception 'the ledger is append-only'; end $$;
create trigger ledger_no_rewrite before update or delete on ledger
  for each row execute function ledger_is_append_only();

-- everyone who is already here starts where everyone new starts
insert into ledger (user_id, amount, reason, reference)
select id, 1000, 'signup', id::text from profiles;

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  insert into profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  insert into notification_settings (user_id) values (new.id) on conflict (user_id) do nothing;
  insert into ledger (user_id, amount, reason, reference) values (new.id, 1000, 'signup', new.id::text);
  return new;
end $$;

-- The only thing in the schema that moves a balance. Idempotent by (reason, reference): it writes
-- the difference between what that reason has already paid out and what it should have, so a
-- re-settlement after a provider correction adjusts rather than double-pays.
create or replace function apply_ledger(p_user uuid, p_reason text, p_reference text, p_target int)
returns int language plpgsql security definer set search_path = pool, public, extensions as $$
declare already int; delta int;
begin
  select coalesce(sum(amount), 0) into already from ledger
   where user_id = p_user and reason = p_reason and reference = p_reference;
  delta := p_target - already;
  if delta = 0 then return 0; end if;
  insert into ledger (user_id, amount, reason, reference) values (p_user, delta, p_reason, p_reference);
  update profiles set balance = balance + delta where id = p_user;
  return delta;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Multipliers replace the odds-driven price
-- ---------------------------------------------------------------------------
alter table markets add column multiplier numeric;
update markets set multiplier = v.m from (values
  ('winner', 1.5), ('draw', 3), ('spread', 2), ('total', 2), ('score', 8),
  ('scorer', 4), ('assist', 6), ('yellow', 3), ('red', 10), ('motm', 8)
) as v(ct, m) where markets.call_type = v.ct::call_type;
alter table markets alter column multiplier set not null;
alter table markets add constraint markets_multiplier_sane check (multiplier >= 1);

-- the result is one 3-way market, so the draw's multiplier lives on its pick
alter table markets add column pick_multiplier jsonb;
update markets set pick_multiplier = '{"draw": 3}' where call_type = 'winner';
update markets set explainer = 'Pick home, draw or away: whoever is ahead after 90 minutes plus stoppage time, with extra time and penalties ignored. A team pays 1.5× your stake, the draw 3×.'
 where call_type = 'winner';

-- option_mult kept its numbers but changes meaning: it now scales the call's multiplier, not a price
comment on column markets.option_mult is 'multiplier scale per option — the red card''s 15-minute windows';

-- the odds-as-points machinery goes; matches.odds stays, because it still posts the goals line
-- and the handicap the card is played against
alter table calls   drop column price;
alter table markets drop column default_price;
alter table markets drop column points;
drop function if exists call_price(matches, markets, int, text, boolean);

create or replace function call_multiplier(mk markets, p_pick text) returns numeric
language sql stable as $$
  select coalesce((mk.pick_multiplier->>p_pick)::numeric,
                  mk.multiplier * coalesce((mk.option_mult->>p_pick)::numeric, 1))
$$;

-- ---------------------------------------------------------------------------
-- 3. Stakes on the call
-- ---------------------------------------------------------------------------
create table stakes (amount int primary key, sort_order int not null);
insert into stakes values (10, 1), (25, 2), (50, 3), (100, 4), (200, 5);

alter table calls
  add column stake      int not null default 10 references stakes(amount),
  add column multiplier numeric,                      -- locked in when the call is saved
  add column staked     boolean not null default false;   -- true once the stake has left the balance
comment on column calls.staked is 'the stake was debited at lock; an uncovered call is never staked and settles void';

update calls k set multiplier = call_multiplier(mk, k.pick)
from entries e, cards cd, matches m, markets mk
where k.entry_id = e.id and e.card_id = cd.id and cd.match_id = m.id and mk.call_type = k.call_type;
alter table calls alter column multiplier set not null;
-- cards already locked keep their old free-points settlement; nothing historical is re-banked
update calls k set staked = false;

-- ---------------------------------------------------------------------------
-- 4. The boost retires with the old economy
-- ---------------------------------------------------------------------------
drop view v_entry_points;
alter table entries drop column boost_call_type;
drop function if exists rpc_set_boost(uuid, call_type);

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
-- 5. Saving a card: the stake comes with the call, and has to be affordable
-- ---------------------------------------------------------------------------
-- what the player has already promised to cards that have not locked yet
create or replace function committed_stake(p_user uuid, p_except_entry uuid default null) returns int
language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce(sum(k.stake), 0)::int
  from calls k join entries e on e.id = k.entry_id join cards cd on cd.id = e.card_id
  where e.user_id = p_user and cd.status = 'open' and not k.staked
    and (p_except_entry is null or e.id <> p_except_entry)
$$;

-- your own, for the card page's "you have X left to stake"
create or replace function my_committed_stake() returns int
language sql stable security definer set search_path = pool, public, extensions as $$
  select committed_stake(require_user(), null)
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
      raise exception 'a stake is 10, 25, 50, 100 or 200 points — not %', v_stake;
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

  -- every call removed: the entry goes too
  if cardinality(kept) = 0 then
    delete from entries where id = e_id;
    return null;
  end if;

  -- one card, one story: calls that cannot all land would be a hedge
  conflict := call_conflict(m, e_id);
  if conflict is not null then raise exception '%', conflict; end if;

  -- and you cannot promise more than you hold. Stakes leave the balance at kick-off, so what is
  -- already promised to other open cards counts against this one.
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
-- 6. Money moves: at lock, at settlement, and back again if a match is called off
-- ---------------------------------------------------------------------------
-- One call's three possible movements, each kept at its correct total.
create or replace function sync_call_money(p_call uuid) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare k calls; u uuid;
begin
  select * into k from calls where id = p_call;
  if k is null then return; end if;
  select e.user_id into u from entries e where e.id = k.entry_id;
  perform apply_ledger(u, 'stake',  p_call::text, case when k.staked then -k.stake else 0 end);
  perform apply_ledger(u, 'win',    p_call::text, case when k.staked and k.result = 'hit'  then round(k.stake * k.multiplier)::int else 0 end);
  perform apply_ledger(u, 'refund', p_call::text, case when k.staked and k.result = 'void' then k.stake else 0 end);
end $$;

-- Kick-off: take every stake on the card. An entry the player can no longer cover is not staked at
-- all — its calls settle void rather than taking a balance below zero.
create or replace function take_stakes(p_card uuid) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare r record; k uuid;
begin
  for r in
    select e.id as entry_id, e.user_id, coalesce(sum(c.stake), 0)::int as total, p.balance
    from entries e join calls c on c.entry_id = e.id join profiles p on p.id = e.user_id
    where e.card_id = p_card and not c.staked
    group by e.id, e.user_id, p.balance
  loop
    if r.total <= r.balance then
      update calls set staked = true where entry_id = r.entry_id and not staked;
    else
      update calls set staked = false, result = 'void', points_awarded = 0, settled_at = now()
       where entry_id = r.entry_id and not staked;
    end if;
    for k in select id from calls where entry_id = r.entry_id loop perform sync_call_money(k); end loop;
  end loop;
end $$;

-- A match called off before it started hands every stake back.
create or replace function release_stakes(p_card uuid) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare k uuid;
begin
  update calls set staked = false, result = 'pending', points_awarded = 0, settled_at = null
   where entry_id in (select id from entries where card_id = p_card);
  for k in select c.id from calls c join entries e on e.id = c.entry_id where e.card_id = p_card loop
    perform sync_call_money(k);
  end loop;
end $$;

create or replace function sync_card_status() returns int
language plpgsql security definer set search_path = pool, public, extensions as $$
declare n int := 0; c uuid;
begin
  -- postponed before it started: reopen and hand the stakes back
  for c in
    select cd.id from cards cd join matches m on m.id = cd.match_id
    where cd.status = 'locked' and m.utc_date > now() and m.status in ('SCHEDULED', 'TIMED', 'POSTPONED')
  loop
    update cards set status = 'open', locked_at = null where id = c;
    perform release_stakes(c);
  end loop;

  -- open → locked when kick-off passes, and the stakes leave the balances
  for c in
    select cd.id from cards cd join matches m on m.id = cd.match_id
    where cd.status = 'open' and m.utc_date <= now()
  loop
    update cards set status = 'locked', locked_at = now() where id = c;
    perform take_stakes(c);
    n := n + 1;
  end loop;

  -- locked → live while the provider reports play (a card that never locked locks here too)
  for c in
    select cd.id from cards cd join matches m on m.id = cd.match_id
    where cd.status in ('open', 'locked') and m.status in ('IN_PLAY', 'PAUSED', 'EXTRA_TIME', 'PENALTY_SHOOTOUT')
  loop
    update cards set status = 'live', locked_at = coalesce(locked_at, now()) where id = c;
    perform take_stakes(c);
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Scoring: a hit returns stake × multiplier
-- ---------------------------------------------------------------------------
drop function if exists score_call(calls, matches, boolean);

create or replace function score_call(c calls, m matches)
returns table (result call_result, points int) language plpgsql stable
set search_path = pool, public, extensions as $$
declare
  r call_result := 'pending'; final boolean := m.status in ('FINISHED', 'AWARDED');
  ev boolean; has_stats boolean; played boolean;
  total int; cover numeric;
begin
  -- a call whose stake was never covered at kick-off cannot win or lose
  if not c.staked and m.utc_date <= now() then
    result := 'void'; points := 0; return next; return;
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
  points := case when r = 'hit' then round(c.stake * c.multiplier)::int else 0 end;
  return next;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Settlement moves the money
-- ---------------------------------------------------------------------------
create or replace function settle_match(p_match int, p_final boolean)
returns table (calls_changed int, entries_changed int)
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  m matches;
  rec record;
  sc record;
  n_calls int := 0; n_entries int := 0;
  rerun boolean;
begin
  select * into m from matches where id = p_match;
  if m is null then raise exception 'unknown match'; end if;
  if p_final and m.status not in ('FINISHED', 'AWARDED') then
    raise exception 'match % is not finished', p_match;
  end if;
  if not p_final then
    m.status := 'IN_PLAY';   -- a live pass must never mark result calls
  end if;
  rerun := p_final and m.settled_at is not null;

  -- 1. calls, and the money each one owes or is owed
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
      n_calls := n_calls + 1;
    end if;
    perform sync_call_money((rec.call).id);
  end loop;

  -- 2. entries. points is now net: everything that came back — winnings and refunded stakes —
  --    less everything that was staked. It matches the card's effect on the balance exactly.
  for rec in
    select e.id, e.user_id, e.points as old_points, e.hits as old_hits, e.card_id, cd.crew_id,
           (coalesce(sum(c.points_awarded), 0)
            + coalesce(sum(c.stake) filter (where c.staked and c.result = 'void'), 0)
            - coalesce(sum(c.stake) filter (where c.staked), 0))::int as pts,
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
-- 9. Rewarded ads: 100 points a time, ten a day, counted by the database
-- ---------------------------------------------------------------------------
create table app_flags (
  key     text primary key,
  enabled boolean not null default false,
  note    text
);
insert into app_flags (key, enabled, note) values
  ('rewarded_ads', true, 'the 30-second countdown stub stands in for a real rewarded-video provider');

create table ad_views (
  user_id    uuid not null references profiles(id) on delete cascade,
  day        date not null,
  seq        int  not null check (seq between 1 and 10),   -- the cap, as a constraint
  id         uuid not null default gen_random_uuid(),
  reward     int  not null,
  created_at timestamptz not null default now(),
  primary key (user_id, day, seq)
);

create or replace function ads_today(p_user uuid default auth.uid()) returns int
language sql stable security definer set search_path = pool, public, extensions as $$
  select count(*)::int from ad_views where user_id = p_user and day = (now() at time zone 'utc')::date
$$;

-- The cap is the primary key plus `seq between 1 and 10`: two calls racing cannot both take the same
-- slot, and an eleventh has nowhere to go. The client is not trusted with any of it.
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
    insert into ad_views (user_id, day, seq, reward) values (u, d, n + 1, 100) returning id into v;
  exception when unique_violation or check_violation then
    raise exception 'That is all ten of today''s ads. The counter resets at midnight UTC.';
  end;
  perform apply_ledger(u, 'ad_reward', v::text, 100);
  return jsonb_build_object('credited', 100, 'watched_today', n + 1, 'left_today', 10 - (n + 1),
                            'balance', (select balance from profiles where id = u));
end $$;

-- ---------------------------------------------------------------------------
-- 10. The prize
-- ---------------------------------------------------------------------------
create table prize_claims (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references profiles(id) on delete cascade,
  prize            text not null default 'PlayStation 5',
  balance_at_claim int  not null,
  status           text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'fulfilled')),
  note             text,
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz
);
create index prize_claims_user_idx on prize_claims(user_id, created_at desc);
-- one claim in flight per person; we settle them by hand
create unique index prize_claims_one_open on prize_claims(user_id) where status = 'pending';

create or replace function rpc_claim_prize() returns uuid
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); bal int; new_id uuid;
begin
  select balance into bal from profiles where id = u;
  if bal < 1000000 then
    raise exception 'A PlayStation 5 takes 1,000,000 points. You hold %.', bal;
  end if;
  if exists (select 1 from prize_claims where user_id = u and status = 'pending') then
    raise exception 'Your claim is already with us — we will be in touch by email.';
  end if;
  insert into prize_claims (user_id, balance_at_claim) values (u, bal) returning id into new_id;
  return new_id;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Read models: the table ranks by balance, the profile shows the climb
-- ---------------------------------------------------------------------------
drop function if exists leaderboard(text, text, text);
create function leaderboard(p_scope text, p_key text default null, p_season text default null)
returns table (
  user_id uuid, display_name text, balance int, points bigint, points_prev bigint, cards bigint,
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
  ),
  -- the overall table is everyone who holds points; a scoped one is everyone who played in it
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
  -- points are a currency: overall, the richest leads. A scoped table ranks on what was won in it.
  order by case when p_scope = 'overall' then pe.balance else coalesce(a.points, 0)::int end desc,
           coalesce(a.hits, 0) desc, pe.display_name;
end $$;

create or replace function my_stats(p_season text default null)
returns jsonb language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare u uuid := auth.uid(); res jsonb;
begin
  with lb as (select *, row_number() over () as rank from leaderboard('overall', null, p_season)),
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
    'ads_enabled', coalesce((select enabled from app_flags where key = 'rewarded_ads'), false),
    'prize_target', 1000000,
    'prize_claim', (select jsonb_build_object('id', id, 'status', status, 'created_at', created_at)
                    from prize_claims where user_id = u order by created_at desc limit 1),
    'competitions', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'points', points, 'rank', rank) order by points desc) from comps), '[]'::jsonb),
    'recent', '[]'::jsonb
  ) into res;
  return res;
end $$;

-- the money, for the profile page
create or replace function my_ledger(p_limit int default 30)
returns table (amount int, reason text, created_at timestamptz)
language sql stable security definer set search_path = pool, public, extensions as $$
  select l.amount, l.reason, l.created_at from ledger l
  where l.user_id = require_user()
  order by l.created_at desc, l.id desc
  limit greatest(1, least(p_limit, 200))
$$;

-- ---------------------------------------------------------------------------
-- 12. Access. The client reads balances; only these functions write them.
-- ---------------------------------------------------------------------------
alter table ledger       enable row level security;
alter table ad_views     enable row level security;
alter table prize_claims enable row level security;
alter table app_flags    enable row level security;
alter table stakes       enable row level security;

create policy "own ledger"  on ledger       for select to authenticated using (user_id = auth.uid());
create policy "own ads"     on ad_views     for select to authenticated using (user_id = auth.uid());
create policy "own claims"  on prize_claims for select to authenticated using (user_id = auth.uid());
create policy "public read" on app_flags    for select using (true);
create policy "public read" on stakes       for select using (true);

grant select on ledger, ad_views, prize_claims to authenticated;
grant select on app_flags, stakes to anon, authenticated;
grant all on ledger, ad_views, prize_claims, app_flags, stakes to service_role;
grant usage, select on sequence ledger_id_seq to service_role;
-- balances are readable (the table ranks by them); no write grant exists anywhere
grant select (balance) on profiles to authenticated;

revoke execute on function apply_ledger(uuid, text, text, int), sync_call_money(uuid),
  take_stakes(uuid), release_stakes(uuid), call_multiplier(markets, text), committed_stake(uuid, uuid),
  score_call(calls, matches), settle_match(int, boolean), sync_card_status()
  from public, anon, authenticated;
grant execute on function apply_ledger(uuid, text, text, int), sync_call_money(uuid),
  take_stakes(uuid), release_stakes(uuid), call_multiplier(markets, text), committed_stake(uuid, uuid),
  score_call(calls, matches), settle_match(int, boolean), sync_card_status()
  to service_role;
grant execute on function rpc_watch_ad(), rpc_claim_prize(), ads_today(uuid), my_ledger(int), my_committed_stake() to authenticated;
grant execute on function leaderboard(text, text, text), my_stats(text) to authenticated;

notify pgrst, 'reload schema';
