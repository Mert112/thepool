-- The Pool — ten profile icons, and the achievements that unlock them.
--
-- Everyone starts with the football. The other nine are earned, and the harder the thing is to do
-- the rarer the icon: watching a lot of ads is a grind anyone can finish, landing an exact
-- scoreline takes nerve, taking a big jackpot takes luck as well, and claiming the PlayStation is
-- the one icon almost nobody will ever wear.
--
-- Criteria are checked against what the database already records — settled entries, landed calls,
-- ad views, ledger rows, prize claims — so nothing has to be tracked separately and an icon can
-- never be awarded for something that did not happen.
set search_path = pool, public, extensions;

create table icons (
  code       text primary key,
  name       text not null,
  rarity     text not null check (rarity in ('common', 'uncommon', 'rare', 'epic', 'legendary')),
  how        text not null,          -- how you get it, in plain English
  glyph      text not null,
  sort_order int  not null
);

insert into icons (code, name, rarity, how, glyph, sort_order) values
  ('rookie',  'The Football',   'common',    'Yours from the moment you sign up.',                                  '⚽', 1),
  ('regular', 'The Clipboard',  'common',    'Play five cards through to full time.',                               '📋', 2),
  ('crew',    'The Scarf',      'common',    'Join a crew, or start one.',                                          '🧣', 3),
  ('watcher', 'The Set',        'uncommon',  'Sit through fifty ads. It is a grind, and that is the point.',        '📺', 4),
  ('caller',  'The Target',     'uncommon',  'Land ten calls.',                                                     '🎯', 5),
  ('sniper',  'The Eight Ball', 'rare',      'Call an exact scoreline and watch it come in.',                       '🎱', 6),
  ('banker',  'The Bag',        'rare',      'Hold 500 points at once, from a season that starts you on 100.',      '💰', 7),
  ('jackpot', 'The Machine',    'epic',      'Take a share of a jackpot worth 100 points or more.',                 '🎰', 8),
  ('whale',   'The Whale',      'epic',      'Take 250 points or more out of a single pot.',                        '🐋', 9),
  ('console', 'The Console',    'legendary', 'Claim the PlayStation 5. Almost nobody will ever wear this one.',      '🎮', 10);

create table user_icons (
  user_id   uuid not null references profiles(id) on delete cascade,
  code      text not null references icons(code) on delete cascade,
  earned_at timestamptz not null default now(),
  primary key (user_id, code)
);
create index user_icons_user_idx on user_icons(user_id, earned_at desc);

alter table profiles add column icon text not null default 'rookie' references icons(code);

-- everyone already here has the football, and is wearing it
insert into user_icons (user_id, code) select id, 'rookie' from profiles on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Earning them
-- ---------------------------------------------------------------------------
-- Every criterion is a question asked of data the game already keeps. Running this twice awards
-- nothing twice; running it for somebody who has earned nothing does nothing at all.
create or replace function award_icons(p_user uuid) returns text[]
language plpgsql security definer set search_path = pool, public, extensions as $$
declare earned text[];
begin
  if p_user is null then return '{}'; end if;
  with won as (
    select 'rookie'::text as code
    union all select 'regular' where (
      select count(*) from entries e join cards c on c.id = e.card_id
      where e.user_id = p_user and c.status in ('settled', 'disputed')) >= 5
    union all select 'crew' where exists (select 1 from crew_members where user_id = p_user)
    union all select 'watcher' where (select count(*) from ad_views where user_id = p_user) >= 50
    union all select 'caller' where (
      select count(*) from calls k join entries e on e.id = k.entry_id
      where e.user_id = p_user and k.result = 'hit') >= 10
    union all select 'sniper' where exists (
      select 1 from calls k join entries e on e.id = k.entry_id
      where e.user_id = p_user and k.call_type = 'score' and k.result = 'hit')
    union all select 'banker' where (select balance from profiles where id = p_user) >= 500
    union all select 'jackpot' where exists (
      select 1 from ledger where user_id = p_user and reason = 'jackpot' and amount >= 100)
    union all select 'whale' where exists (
      select 1 from ledger where user_id = p_user and reason = 'pot' and amount >= 250)
    union all select 'console' where exists (select 1 from prize_claims where user_id = p_user)
  ),
  ins as (
    insert into user_icons (user_id, code)
    select p_user, won.code from won
    on conflict (user_id, code) do nothing
    returning code
  )
  select coalesce(array_agg(ins.code), '{}') into earned from ins;
  return earned;
end $$;

-- the client can ask for a recount; it can never award anything the data does not support
create or replace function rpc_refresh_icons() returns text[]
language sql security definer set search_path = pool, public, extensions as $$
  select award_icons(require_user())
$$;

create or replace function rpc_set_icon(p_code text) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user();
begin
  perform award_icons(u);
  if not exists (select 1 from user_icons where user_id = u and code = p_code) then
    raise exception 'You have not unlocked that icon yet.';
  end if;
  update profiles set icon = p_code where id = u;
end $$;

-- what you are wearing, what you have, and what the rest would take
create or replace function my_icons()
returns table (code text, name text, rarity text, how text, glyph text, sort_order int,
               earned_at timestamptz, wearing boolean)
language sql stable security definer set search_path = pool, public, extensions as $$
  select i.code, i.name, i.rarity, i.how, i.glyph, i.sort_order,
         ui.earned_at, (p.icon = i.code) as wearing
  from icons i
  cross join profiles p
  left join user_icons ui on ui.code = i.code and ui.user_id = p.id
  where p.id = require_user()
  order by i.sort_order
$$;

-- ---------------------------------------------------------------------------
-- The moments something can be earned
-- ---------------------------------------------------------------------------
create or replace function rpc_watch_ad() returns jsonb
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); d date := (now() at time zone 'utc')::date; n int; v uuid; got text[];
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
  got := award_icons(u);
  return jsonb_build_object('credited', 0.5, 'watched_today', n + 1, 'left_today', 10 - (n + 1),
                            'balance', (select balance from profiles where id = u),
                            'unlocked', to_jsonb(got));
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
  perform award_icons(u);
  return new_id;
end $$;

create or replace function rpc_create_crew(p_name text, p_description text, p_mode card_mode default 'complex')
returns uuid language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); new_id uuid;
begin
  insert into crews (name, description, mode, invite_code, owner_id)
  values (trim(p_name), nullif(trim(p_description), ''), p_mode, gen_invite_code(), u)
  returning id into new_id;
  insert into crew_members (crew_id, user_id, role) values (new_id, u, 'owner');
  perform award_icons(u);
  return new_id;
end $$;

create or replace function rpc_join_crew(p_code text) returns uuid
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); c crews;
begin
  select * into c from crews where invite_code = upper(trim(p_code));
  if c is null then raise exception 'no crew has that code'; end if;
  insert into crew_members (crew_id, user_id) values (c.id, u) on conflict do nothing;
  perform award_icons(u);
  return c.id;
end $$;

-- a new account gets the football, and wears it
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  insert into profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  insert into notification_settings (user_id) values (new.id) on conflict (user_id) do nothing;
  insert into ledger (user_id, amount, reason, reference) values (new.id, 100, 'signup', new.id::text);
  insert into user_icons (user_id, code) values (new.id, 'rookie') on conflict do nothing;
  return new;
end $$;

-- settlement is where most of them land: a card played out, a call landed, a pot taken
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

  -- an icon can be earned by playing the card out, landing the call, or taking the pot
  perform award_icons(e.user_id)
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
-- The icon travels with the name, so a crew room and a table can show it
-- ---------------------------------------------------------------------------
drop function if exists leaderboard(text, text, text);
create function leaderboard(p_scope text, p_key text default null, p_season text default null)
returns table (
  user_id uuid, display_name text, icon text, balance numeric, points numeric, points_prev numeric,
  cards bigint, hits bigint, calls bigint, hit_rate numeric, best_call call_type, best_points numeric
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
    select p.id as user_id, p.display_name, p.icon, p.balance from profiles p
    where p_scope = 'overall' or p.id in (select agg.user_id from agg)
  )
  select pe.user_id, pe.display_name, pe.icon, pe.balance,
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

-- ---------------------------------------------------------------------------
-- Access. An icon is earned, never set from the client except by choosing one you hold.
-- ---------------------------------------------------------------------------
alter table icons      enable row level security;
alter table user_icons enable row level security;
create policy "public read" on icons      for select using (true);
create policy "own icons"   on user_icons for select to authenticated using (user_id = auth.uid());
grant select on icons to anon, authenticated;
grant select on user_icons to authenticated;
grant all on icons, user_icons to service_role;
grant select (icon) on profiles to anon, authenticated;

revoke execute on function award_icons(uuid) from public, anon, authenticated;
grant execute on function award_icons(uuid) to service_role;
grant execute on function rpc_set_icon(text), rpc_refresh_icons(), my_icons() to authenticated;
grant execute on function leaderboard(text, text, text) to authenticated;

notify pgrst, 'reload schema';
