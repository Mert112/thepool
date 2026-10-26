-- The Pool — a real rewarded ad, and a reward that cannot be claimed twice.
--
-- The stub that has stood in since `0019` credited whoever called `rpc_watch_ad()`. That was
-- fine while the ad was a thirty-second countdown in our own page; it is not fine once there is
-- money behind it, because the call is a POST anyone can repeat.
--
-- Google Publisher Tag's rewarded format does not hand the page a token of its own: the
-- `rewardedSlotGranted` event carries `{type, amount}` and nothing that proves it happened.
-- (Server-side verification exists in Ad Manager, but it calls a URL of ours out of band and
-- cannot answer "credit this player now".) So the nonce is **ours**, minted before the ad is
-- asked for and spent when it is granted:
--
--   1. the player taps "Get points"
--   2. `rpc_ad_nonce()` checks the flag, the daily cap and the sixty-second spacing, and issues
--      a single-use nonce that expires in ten minutes
--   3. the page loads the rewarded slot and waits for `rewardedSlotGranted`
--   4. `rpc_watch_ad(nonce)` credits 0.2 points — once, for that nonce, inside the caps
--
-- A replayed nonce credits nothing. A nonce from another account credits nothing. A nonce
-- issued and never used costs nothing but a row. The daily cap stays where it was: a primary
-- key of (user, day, seq) with `seq between 1 and 10`, so two calls racing cannot both take the
-- same slot and an eleventh has nowhere to go.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- 1. What the page needs to know, and what it must not decide
-- ---------------------------------------------------------------------------
-- The ad unit is public: the browser has to pass it to GPT. The reward, the cap and the
-- spacing are in the same row for one place to read them, and the server is the only thing
-- that acts on them.
insert into config (key, value, public, note) values
  ('ads', jsonb_build_object(
      'provider', 'gam',
      'network_code', '',                  -- set per deployment: Ad Manager → Admin → Global settings
      'ad_unit_path', '',                  -- e.g. /21775744923/rewarded_thepool
      'reward', 0.2,
      'daily_cap', 10,
      'spacing_seconds', 60,
      'nonce_ttl_seconds', 600),
    true,
    'Google Ad Manager rewarded slot. Only the ad unit and the reward are public; the server enforces the rest.')
on conflict (key) do nothing;

create or replace function ad_settings() returns jsonb
language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce((select value from config where key = 'ads'), '{}'::jsonb)
$$;
create or replace function ad_reward() returns numeric
language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce((ad_settings()->>'reward')::numeric, 0.2)
$$;
create or replace function ad_cap() returns int
language sql stable security definer set search_path = pool, public, extensions as $$
  select least(coalesce((ad_settings()->>'daily_cap')::int, 10), 10)   -- the check constraint is the real ceiling
$$;

revoke execute on function ad_settings(), ad_reward(), ad_cap() from public, anon;
grant execute on function ad_settings(), ad_reward(), ad_cap() to authenticated, service_role;

-- the real thing, behind its own flag; the countdown stub stays behind the old one for testing
insert into app_flags (key, enabled, note) values
  ('gam_rewarded', false, 'serve Google Ad Manager''s rewarded slot instead of the 30-second countdown stub')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. The nonce
-- ---------------------------------------------------------------------------
create table ad_nonces (
  nonce      uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  issued_at  timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz,
  ad_view_id uuid
);

create index on ad_nonces (user_id, issued_at desc);

alter table ad_nonces enable row level security;
revoke all on ad_nonces from anon, authenticated;   -- the schema grants select on a new table by default

comment on table ad_nonces is
  'One row per rewarded ad we agreed to count. Issued before the ad loads, spent when it is granted, never twice.';

-- When the last ad actually paid out. The spacing rule is about credits, not about taps.
create or replace function ad_last_credit(p_user uuid) returns timestamptz
language sql stable security definer set search_path = pool, public, extensions as $$
  select max(created_at) from ad_views where user_id = p_user
$$;

-- Issue a nonce, or say why not. Every reason the credit could be refused is checked here too,
-- so the page does not load an ad it was never going to be paid for.
create or replace function rpc_ad_nonce() returns jsonb
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  u uuid := require_user(); d date := (now() at time zone 'utc')::date;
  s jsonb := ad_settings(); n int; last timestamptz; wait int; nonce uuid;
begin
  if not coalesce((select enabled from app_flags where key = 'rewarded_ads'), false) then
    raise exception 'Getting points by watching an ad is switched off right now.';
  end if;
  select count(*) into n from ad_views where user_id = u and day = d;
  if n >= ad_cap() then
    raise exception 'That is all ten of today''s ads. The counter resets at midnight UTC.';
  end if;
  last := ad_last_credit(u);
  wait := coalesce((s->>'spacing_seconds')::int, 60);
  if last is not null and last > now() - make_interval(secs => wait) then
    raise exception 'One ad a minute. Try again in % seconds.', ceil(extract(epoch from (last + make_interval(secs => wait)) - now()))::int;
  end if;
  insert into ad_nonces (user_id, expires_at)
  values (u, now() + make_interval(secs => coalesce((s->>'nonce_ttl_seconds')::int, 600)))
  returning ad_nonces.nonce into nonce;
  return jsonb_build_object('nonce', nonce, 'reward', ad_reward(),
                            'watched_today', n, 'left_today', ad_cap() - n);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Spending it
-- ---------------------------------------------------------------------------
-- The nonce must be this player's, unused and unexpired. `for update` is what makes a replay
-- lose the race rather than win it twice.
create or replace function rpc_watch_ad(p_nonce uuid default null) returns jsonb
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  u uuid := require_user(); d date := (now() at time zone 'utc')::date;
  s jsonb := ad_settings(); n int; v uuid; got text[]; r numeric := ad_reward();
  nz ad_nonces; last timestamptz; wait int;
begin
  if not coalesce((select enabled from app_flags where key = 'rewarded_ads'), false) then
    raise exception 'Getting points by watching an ad is switched off right now.';
  end if;

  if p_nonce is null then
    -- the countdown stub, which only exists while the real slot is switched off
    if coalesce((select enabled from app_flags where key = 'gam_rewarded'), false) then
      raise exception 'This ad was not counted. Close it and try again.';
    end if;
  else
    select * into nz from ad_nonces where nonce = p_nonce for update;
    if nz.nonce is null or nz.user_id <> u then
      raise exception 'This ad was not counted. Close it and try again.';
    end if;
    if nz.used_at is not null then
      raise exception 'That ad has already been counted.';
    end if;
    if nz.expires_at < now() then
      raise exception 'That ad took too long. Try another.';
    end if;
  end if;

  select count(*) into n from ad_views where user_id = u and day = d;
  if n >= ad_cap() then
    raise exception 'That is all ten of today''s ads. The counter resets at midnight UTC.';
  end if;
  last := ad_last_credit(u);
  wait := coalesce((s->>'spacing_seconds')::int, 60);
  if last is not null and last > now() - make_interval(secs => wait) then
    raise exception 'One ad a minute. Try again in % seconds.', ceil(extract(epoch from (last + make_interval(secs => wait)) - now()))::int;
  end if;

  begin
    insert into ad_views (user_id, day, seq, reward) values (u, d, n + 1, r) returning id into v;
  exception when unique_violation or check_violation then
    raise exception 'That is all ten of today''s ads. The counter resets at midnight UTC.';
  end;
  if p_nonce is not null then
    update ad_nonces set used_at = now(), ad_view_id = v where nonce = p_nonce;
  end if;
  perform apply_ledger(u, 'ad_reward', v::text, r);
  got := award_icons(u);
  return jsonb_build_object('credited', r, 'watched_today', n + 1, 'left_today', ad_cap() - (n + 1),
                            'balance', (select balance from profiles where id = u),
                            'unlocked', to_jsonb(got));
end $$;

revoke execute on function rpc_ad_nonce(), rpc_watch_ad(uuid) from public, anon;
grant execute on function rpc_ad_nonce(), rpc_watch_ad(uuid) to authenticated;
revoke execute on function ad_last_credit(uuid) from public, anon, authenticated;

-- the old no-argument form is gone: everything calls the one that can take a nonce
drop function if exists rpc_watch_ad();

-- ---------------------------------------------------------------------------
-- 4. The reward is read, not hard-coded
-- ---------------------------------------------------------------------------
create or replace function my_stats(p_season text default null) returns jsonb
language plpgsql stable security definer set search_path = pool, public, extensions as $$
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
    'ads_left', ad_cap() - ads_today(u),
    'ad_reward', ad_reward(),
    'ads_enabled', coalesce((select enabled from app_flags where key = 'rewarded_ads'), false),
    'ads_gam', coalesce((select enabled from app_flags where key = 'gam_rewarded'), false),
    'prize_target', 1000000,
    'prize_claim', (select jsonb_build_object('id', id, 'status', status, 'created_at', created_at)
                    from prize_claims where user_id = u order by created_at desc limit 1),
    'competitions', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'points', points, 'rank', rank) order by points desc) from comps), '[]'::jsonb),
    'recent', '[]'::jsonb
  ) into res;
  return res;
end $$;

notify pgrst, 'reload schema';
