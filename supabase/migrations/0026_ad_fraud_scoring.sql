-- The Pool — fraud scoring replaces the minute between ads, and a phone before the first claim.
--
-- `0025` refused a credit inside sixty seconds of the last one. That rule cost every honest
-- player a wait after each ad and stopped nobody with ten accounts. It is gone. In its place:
--
--   · every ad credit records the device fingerprint the page sends, and the IP and user-agent
--     the request arrived with (read from PostgREST's request headers, not from the page)
--   · an account is **flagged** when it shares a fingerprint or an IP with three or more other
--     accounts, or when its credits average under twenty seconds apart on the same day
--   · flagged accounts still play and still earn. What changes is that their prize claims carry
--     a warning in `admin_prize_claims`, where claims are handled by hand
--   · a verified phone (SMS code through Twilio Verify, edge function `phone-verify`) is needed
--     once, before the first prize claim — one number per account, one account per number.
--     Behind the `phone_verification` flag, off until the TWILIO_* secrets are in place.
--
-- The nonce rules and the ten-a-day cap are unchanged. The stub ad is twenty-five seconds now,
-- so the next one can start the moment one finishes.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The spacing rule goes; the thresholds live server-side only
-- ---------------------------------------------------------------------------
update config set value = (value - 'spacing_seconds') || jsonb_build_object('stub_seconds', 25),
                  note = 'Google Ad Manager rewarded slot. Only the ad unit, the reward and the stub length are public; the server enforces the rest.',
                  updated_at = now()
 where key = 'ads';

-- not public: there is no reason to tell anyone where the line is
insert into config (key, value, public, note) values
  ('ad_fraud', jsonb_build_object('shared_with', 3, 'min_avg_gap_seconds', 20), false,
   'An account is flagged when it shares a device fingerprint or an IP with this many other accounts, or its ad credits average under this many seconds apart.')
on conflict (key) do nothing;

drop function if exists ad_last_credit(uuid);

-- ---------------------------------------------------------------------------
-- 2. What each credit came from
-- ---------------------------------------------------------------------------
alter table ad_views
  add column fingerprint text check (fingerprint is null or fingerprint ~ '^[0-9a-f]{16,128}$'),
  add column ip          text check (ip is null or length(ip) <= 64),
  add column user_agent  text check (user_agent is null or length(user_agent) <= 512);

comment on column ad_views.fingerprint is 'A hash of stable browser traits, sent by the page. Used only for fraud scoring.';
comment on column ad_views.ip is 'The client IP as the API gateway saw it (cf-connecting-ip, else x-real-ip, else the first x-forwarded-for).';

create index on ad_views (fingerprint) where fingerprint is not null;
create index on ad_views (ip) where ip is not null;

-- The gateway's headers, as PostgREST hands them to the transaction. Cloudflare's header is the
-- one a client cannot forge; x-forwarded-for's first entry can be, so it is the last resort.
create or replace function request_header(p_name text) returns text
language sql stable set search_path = pool, public, extensions as $$
  select nullif(current_setting('request.headers', true), '')::jsonb ->> p_name
$$;
create or replace function request_ip() returns text
language sql stable set search_path = pool, public, extensions as $$
  select left(nullif(trim(coalesce(request_header('cf-connecting-ip'), request_header('x-real-ip'),
                                   split_part(request_header('x-forwarded-for'), ',', 1))), ''), 64)
$$;
revoke execute on function request_header(text), request_ip() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The nonce, without the minute
-- ---------------------------------------------------------------------------
create or replace function rpc_ad_nonce() returns jsonb
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  u uuid := require_user(); d date := (now() at time zone 'utc')::date;
  s jsonb := ad_settings(); n int; nonce uuid;
begin
  if not coalesce((select enabled from app_flags where key = 'rewarded_ads'), false) then
    raise exception 'Getting points by watching an ad is switched off right now.';
  end if;
  select count(*) into n from ad_views where user_id = u and day = d;
  if n >= ad_cap() then
    raise exception 'That is all ten of today''s ads. The counter resets at midnight UTC.';
  end if;
  insert into ad_nonces (user_id, expires_at)
  values (u, now() + make_interval(secs => coalesce((s->>'nonce_ttl_seconds')::int, 600)))
  returning ad_nonces.nonce into nonce;
  return jsonb_build_object('nonce', nonce, 'reward', ad_reward(),
                            'watched_today', n, 'left_today', ad_cap() - n);
end $$;

-- the credit takes the fingerprint now; the old one-argument form goes so there is one signature
drop function if exists rpc_watch_ad(uuid);
create function rpc_watch_ad(p_nonce uuid default null, p_fingerprint text default null) returns jsonb
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  u uuid := require_user(); d date := (now() at time zone 'utc')::date;
  n int; v uuid; got text[]; r numeric := ad_reward(); nz ad_nonces;
  fp text := lower(nullif(trim(p_fingerprint), ''));
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

  -- a malformed fingerprint is dropped, not refused: it is evidence, not a ticket
  if fp is not null and fp !~ '^[0-9a-f]{16,128}$' then fp := null; end if;

  select count(*) into n from ad_views where user_id = u and day = d;
  if n >= ad_cap() then
    raise exception 'That is all ten of today''s ads. The counter resets at midnight UTC.';
  end if;

  begin
    insert into ad_views (user_id, day, seq, reward, fingerprint, ip, user_agent)
    values (u, d, n + 1, r, fp, request_ip(), left(request_header('user-agent'), 512))
    returning id into v;
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

revoke execute on function rpc_ad_nonce(), rpc_watch_ad(uuid, text) from public, anon;
grant execute on function rpc_ad_nonce(), rpc_watch_ad(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The score
-- ---------------------------------------------------------------------------
-- One row per account that has ever been credited for an ad. "Shares with" counts distinct other
-- accounts across every fingerprint (or IP) this one has used. The gap is measured between
-- consecutive credits on the same UTC day, so a night's sleep does not pad the average.
create or replace function ad_fraud_scores()
returns table (user_id uuid, credits int, fingerprint_shared_with int, ip_shared_with int,
               avg_gap_seconds numeric, flagged boolean, reasons text[])
language sql stable security definer set search_path = pool, public, extensions as $$
  with cfg as (
    select coalesce((c.value->>'shared_with')::int, 3) as sw,
           coalesce((c.value->>'min_avg_gap_seconds')::numeric, 20) as mg
      from (select 1) one left join config c on c.key = 'ad_fraud'
  ),
  fps as (select distinct v.user_id, v.fingerprint from ad_views v where v.fingerprint is not null),
  ips as (select distinct v.user_id, v.ip from ad_views v where v.ip is not null),
  fp as (select a.user_id, count(distinct b.user_id)::int as n
           from fps a join fps b on b.fingerprint = a.fingerprint and b.user_id <> a.user_id
          group by a.user_id),
  ip as (select a.user_id, count(distinct b.user_id)::int as n
           from ips a join ips b on b.ip = a.ip and b.user_id <> a.user_id
          group by a.user_id),
  gaps as (select v.user_id,
                  extract(epoch from v.created_at - lag(v.created_at) over (partition by v.user_id, v.day order by v.created_at, v.seq)) as g
             from ad_views v),
  gap as (select gaps.user_id, round(avg(gaps.g)::numeric, 1) as a from gaps where gaps.g is not null group by gaps.user_id),
  acc as (select v.user_id, count(*)::int as credits from ad_views v group by v.user_id),
  scored as (
    select acc.user_id, acc.credits, coalesce(fp.n, 0) as fpn, coalesce(ip.n, 0) as ipn, gap.a,
           array_remove(array[
             case when coalesce(fp.n, 0) >= cfg.sw then format('device shared with %s other accounts', fp.n) end,
             case when coalesce(ip.n, 0) >= cfg.sw then format('IP shared with %s other accounts', ip.n) end,
             case when gap.a < cfg.mg then format('ads average %ss apart', trim_scale(gap.a)) end
           ], null) as reasons
      from acc cross join cfg
      left join fp on fp.user_id = acc.user_id
      left join ip on ip.user_id = acc.user_id
      left join gap on gap.user_id = acc.user_id
  )
  select s.user_id, s.credits, s.fpn, s.ipn, s.a, cardinality(s.reasons) > 0, s.reasons from scored s
$$;

revoke execute on function ad_fraud_scores() from public, anon, authenticated;
grant execute on function ad_fraud_scores() to service_role;

-- ---------------------------------------------------------------------------
-- 5. A phone, once, before the first claim
-- ---------------------------------------------------------------------------
insert into app_flags (key, enabled, note) values
  ('phone_verification', false, 'require a phone verified by SMS (Twilio Verify, TWILIO_* secrets) before the first prize claim')
on conflict (key) do nothing;

-- one row per account, one account per number: the primary key and the unique index say both
create table phone_verifications (
  user_id     uuid primary key references profiles(id) on delete cascade,
  phone       text not null unique check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  verified_at timestamptz not null default now()
);
alter table phone_verifications enable row level security;
revoke all on phone_verifications from anon, authenticated;
comment on table phone_verifications is
  'A phone number confirmed by SMS code. Written only by the phone-verify edge function, through phone_mark_verified().';

-- every code sent, so one account cannot run up an SMS bill
create table phone_attempts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles(id) on delete cascade,
  phone      text not null,
  created_at timestamptz not null default now()
);
create index on phone_attempts (user_id, created_at desc);
create index on phone_attempts (phone, created_at desc);
alter table phone_attempts enable row level security;
revoke all on phone_attempts from anon, authenticated;

create or replace function phone_needed(p_user uuid) returns boolean
language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce((select enabled from app_flags where key = 'phone_verification'), false)
     and not exists (select 1 from phone_verifications where user_id = p_user)
$$;

-- Before a code goes out: null to go ahead, or the reason not to. Records the attempt.
create or replace function phone_can_start(p_user uuid, p_phone text) returns text
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  if p_phone !~ '^\+[1-9][0-9]{6,14}$' then
    return 'Enter the number with its country code, like +90 555 123 4567.';
  end if;
  if exists (select 1 from phone_verifications where user_id = p_user) then
    return 'Your phone is already verified.';
  end if;
  if exists (select 1 from phone_verifications where phone = p_phone) then
    return 'That phone number is already on another account.';
  end if;
  if (select count(*) from phone_attempts where user_id = p_user and created_at > now() - interval '1 day') >= 5
     or (select count(*) from phone_attempts where phone = p_phone and created_at > now() - interval '1 day') >= 3 then
    return 'Too many codes today. Try again tomorrow.';
  end if;
  insert into phone_attempts (user_id, phone) values (p_user, p_phone);
  return null;
end $$;

create or replace function phone_mark_verified(p_user uuid, p_phone text) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  insert into phone_verifications (user_id, phone) values (p_user, p_phone);
exception when unique_violation then
  if exists (select 1 from phone_verifications where user_id = p_user) then
    raise exception 'Your phone is already verified.';
  end if;
  raise exception 'That phone number is already on another account.';
end $$;

revoke execute on function phone_needed(uuid), phone_can_start(uuid, text), phone_mark_verified(uuid, text)
  from public, anon, authenticated;
grant execute on function phone_can_start(uuid, text), phone_mark_verified(uuid, text) to service_role;

-- the claim itself: the balance first (so the reason you hear is the one that matters), then the phone
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
  if phone_needed(u) then
    raise exception 'Verify your phone number before your first claim.';
  end if;
  insert into prize_claims (user_id, balance_at_claim) values (u, bal) returning id into new_id;
  perform award_icons(u);
  return new_id;
end $$;

-- ---------------------------------------------------------------------------
-- 6. The admin view: every claim, with its warning
-- ---------------------------------------------------------------------------
-- Read in the Supabase dashboard (SQL editor / table editor as postgres) — nobody else can.
create or replace view admin_prize_claims with (security_invoker = true) as
select pc.id, pc.created_at, pc.status, pc.balance_at_claim,
       p.id as user_id, p.email, p.display_name,
       pv.phone, pv.verified_at as phone_verified_at,
       coalesce(f.flagged, false) as flagged,
       case when f.flagged then '⚠ ' || array_to_string(f.reasons, '; ') end as warning,
       f.credits as ad_credits, f.fingerprint_shared_with, f.ip_shared_with, f.avg_gap_seconds
  from prize_claims pc
  join profiles p on p.id = pc.user_id
  left join phone_verifications pv on pv.user_id = pc.user_id
  left join ad_fraud_scores() f on f.user_id = pc.user_id
 order by pc.created_at desc;

create or replace view admin_ad_fraud with (security_invoker = true) as
select f.*, p.email, p.display_name
  from ad_fraud_scores() f join profiles p on p.id = f.user_id
 order by f.flagged desc, f.credits desc;

revoke all on admin_prize_claims, admin_ad_fraud from public, anon, authenticated;
grant select on admin_prize_claims, admin_ad_fraud to service_role;

-- ---------------------------------------------------------------------------
-- 7. The profile needs to know whether to ask for the phone
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
    'phone_needed', phone_needed(u),
    'prize_target', 1000000,
    'prize_claim', (select jsonb_build_object('id', id, 'status', status, 'created_at', created_at)
                    from prize_claims where user_id = u order by created_at desc limit 1),
    'competitions', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'points', points, 'rank', rank) order by points desc) from comps), '[]'::jsonb),
    'recent', '[]'::jsonb
  ) into res;
  return res;
end $$;

notify pgrst, 'reload schema';
