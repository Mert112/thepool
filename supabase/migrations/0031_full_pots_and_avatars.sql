-- The Pool — pots pay out in full, and a player can upload a picture.
--
--   · the house no longer takes 10% of a pot: everything staked on a call is shared among the
--     right answers (or rolls into the jackpot when nobody is right). settle_pot and card_pots
--     lose their × 0.90. Pots already settled keep their history; this applies from the next one
--   · profiles.avatar_path: a picture the player uploaded to the public `avatars` bucket, under a
--     folder named by their own id. It is set only through rpc_set_avatar, which accepts a path
--     in the player's own folder (and, on the hosted database, only one that was uploaded). A
--     picture shows in place of the icon wherever the icon showed, the table included
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Full pots
-- ---------------------------------------------------------------------------
create or replace function settle_pot(p_card uuid, p_call_type call_type) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  comp text; pot numeric := 0; jack numeric; won numeric := 0;
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

  if won = 0 then
    -- nobody was right: the whole pot rolls into the competition's jackpot
    insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
    values (comp, p_call_type, p_card, 'rollover', pot);
    insert into jackpots (competition_code, call_type, amount) values (comp, p_call_type, pot)
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
    pot_share  := round_down2(pot  * r.stake / won);
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
  remainder := (pot - paid_pot) + (jack - paid_jack);
  insert into jackpot_moves (competition_code, call_type, card_id, kind, amount)
  values (comp, p_call_type, p_card, 'rollover', remainder);
  if remainder > 0 then
    insert into jackpots (competition_code, call_type, amount) values (comp, p_call_type, remainder)
    on conflict (competition_code, call_type) do update
      set amount = jackpots.amount + excluded.amount, updated_at = now();
  end if;
end $$;

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
         p.pot + jackpot_of((select competition_code from m), b.call_type) as purse,
         round_down2((p.pot + jackpot_of((select competition_code from m), b.call_type)) / b.pick_stake) as per_point
  from by_pick b join pots p on p.call_type = b.call_type
  where can_see_card(p_card)
  order by b.call_type, b.pick_stake desc;
$$;

-- ---------------------------------------------------------------------------
-- 2. Avatars
-- ---------------------------------------------------------------------------
alter table profiles add column avatar_path text;
grant select (avatar_path) on profiles to anon, authenticated;

-- the bucket and its rules exist only on the hosted database (the local test build has no
-- storage schema). Public to read; a player writes and deletes only inside their own folder
do $$
begin
  if to_regclass('storage.objects') is null then return; end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('avatars', 'avatars', true, 1048576, array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;
  execute $p$create policy "avatars: own folder read" on storage.objects for select to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  execute $p$create policy "avatars: own folder upload" on storage.objects for insert to authenticated
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  execute $p$create policy "avatars: own folder delete" on storage.objects for delete to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
end $$;

-- null clears the picture, and the icon shows again
create or replace function rpc_set_avatar(p_path text) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); uploaded boolean := true;
begin
  if p_path is not null then
    if p_path !~ ('^' || u::text || '/[a-z0-9_-]{1,40}\.(webp|jpe?g|png)$') then
      raise exception 'A picture goes in your own folder' using errcode = '42501';
    end if;
    -- dynamic, because the local build has no storage schema to plan this against
    if to_regclass('storage.objects') is not null then
      execute 'select exists (select 1 from storage.objects where bucket_id = ''avatars'' and name = $1)'
        into uploaded using p_path;
    end if;
    if not uploaded then raise exception 'That picture has not been uploaded'; end if;
  end if;
  update profiles set avatar_path = p_path where id = u;
end $$;
revoke all on function rpc_set_avatar(text) from public, anon;
grant execute on function rpc_set_avatar(text) to authenticated;

-- the table and crew rooms show the picture beside the name: same as 0022, plus avatar_path
drop function if exists leaderboard(text, text, text);
create function leaderboard(p_scope text, p_key text default null, p_season text default null)
returns table (
  user_id uuid, display_name text, icon text, balance numeric, points numeric, points_prev numeric,
  cards bigint, hits bigint, calls bigint, hit_rate numeric, best_call call_type, best_points numeric,
  avatar_path text
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
    select p.id as user_id, p.display_name, p.icon, p.balance, p.avatar_path from profiles p
    where p_scope = 'overall' or p.id in (select agg.user_id from agg)
  )
  select pe.user_id, pe.display_name, pe.icon, pe.balance,
         coalesce(a.points, 0), coalesce(a.points_prev, 0), coalesce(a.cards, 0), coalesce(a.hits, 0),
         coalesce(n.calls, 0),
         case when coalesce(n.calls, 0) = 0 then 0 else round(100.0 * a.hits / n.calls, 0) end,
         b.call_type, b.points_awarded, pe.avatar_path
  from people pe
  left join agg a on a.user_id = pe.user_id
  left join ncalls n on n.user_id = pe.user_id
  left join best b on b.user_id = pe.user_id
  order by case when p_scope = 'overall' then pe.balance else coalesce(a.points, 0) end desc,
           coalesce(a.hits, 0) desc, pe.display_name;
end $$;

notify pgrst, 'reload schema';
