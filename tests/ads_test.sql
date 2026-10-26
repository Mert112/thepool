-- Rewarded ads (0025): the nonce rules. Google's rewarded slot hands the page no token of its
-- own, so the nonce is ours — issued before the ad loads, spent when it is granted, never twice.
-- Run on a fresh local db:  psql pool -f tests/ads_test.sql
-- Every check raises on failure; a clean run prints "ADS TESTS PASSED".
\set ON_ERROR_STOP on
begin;
set search_path = pool, public;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'ana@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'ben@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'cem@example.com');

create or replace function test_as(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, true), set_config('role', 'authenticated', true);
$$;
create or replace function test_reset() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', true), set_config('role', 'postgres', true);
$$;
create or replace function bal(u text) returns numeric language sql stable
security definer set search_path = pool, public as $$
  select balance from profiles where id = u::uuid $$;
-- the client cannot read ad_nonces, which is the point; the test needs to all the same
create or replace function spare_nonce(u text) returns uuid language sql stable
security definer set search_path = pool, public as $$
  select nonce from ad_nonces where user_id = u::uuid and used_at is null order by issued_at limit 1 $$;
-- the spacing rule is about when the last ad *paid*, so winding that back is how a test waits
create or replace function wind_back(u text, secs int) returns void
language sql security definer set search_path = pool, public as $$
  update ad_views set created_at = created_at - make_interval(secs => secs) where user_id = u::uuid;
$$;

\set A '11111111-1111-1111-1111-111111111111'
\set B '22222222-2222-2222-2222-222222222222'

-- --- 1. the settings are read, not hard-coded ----------------------------------------------
do $$ begin
  assert ad_reward() = 0.2, format('an ad is worth 0.2, not %s', ad_reward());
  assert ad_cap() = 10, 'ten a day';
  assert (ad_settings()->>'spacing_seconds')::int = 60, 'one a minute';
  assert (select public from config where key = 'ads'), 'the ad unit has to reach the browser';
  -- and the browser gets the unit, not the right to decide what it is worth
  assert has_table_privilege('authenticated', 'pool.config', 'update') = false, 'the client cannot reprice an ad';
  assert has_table_privilege('authenticated', 'pool.ad_nonces', 'select') = false, 'nor read the nonces';
  assert has_table_privilege('authenticated', 'pool.ad_nonces', 'insert') = false, 'nor mint one';
  assert has_function_privilege('anon', 'pool.rpc_ad_nonce()', 'execute') = false, 'signed out, no nonce';
  assert has_function_privilege('authenticated', 'pool.rpc_ad_nonce()', 'execute'), 'signed in, one';
end $$;

-- --- 2. a nonce, then the reward ---------------------------------------------------------------
do $$ declare j jsonb; nz uuid; r jsonb; before numeric; begin
  before := bal('11111111-1111-1111-1111-111111111111');
  perform test_as('11111111-1111-1111-1111-111111111111');
  j := rpc_ad_nonce();
  nz := (j->>'nonce')::uuid;
  assert nz is not null, 'a nonce comes back';
  assert (j->>'reward')::numeric = 0.2, 'and says what the ad is worth';
  assert (j->>'left_today')::int = 10, 'and how many are left';
  assert bal('11111111-1111-1111-1111-111111111111') = before, 'issuing a nonce credits nothing';

  r := rpc_watch_ad(nz);
  assert (r->>'credited')::numeric = 0.2, 'granted: 0.2 points';
  assert (r->>'watched_today')::int = 1, 'the first of the day';
  assert bal('11111111-1111-1111-1111-111111111111') = before + 0.2, 'and the balance moved by exactly that';
  perform test_reset();
  assert (select used_at from ad_nonces where nonce = nz) is not null, 'the nonce is spent';
  assert (select ad_view_id from ad_nonces where nonce = nz) is not null, 'and says which view it paid for';
end $$;

-- --- 3. a replayed nonce pays nothing ------------------------------------------------------------
-- This is the whole reason the nonce exists: rpc_watch_ad() is a POST, and a POST can be repeated.
do $$ declare nz uuid; before numeric; begin
  select nonce into nz from ad_nonces where user_id = '11111111-1111-1111-1111-111111111111' limit 1;
  before := bal('11111111-1111-1111-1111-111111111111');
  perform test_as('11111111-1111-1111-1111-111111111111');
  begin
    perform rpc_watch_ad(nz);
    raise exception 'a nonce was spent twice';
  exception when others then if sqlerrm not like '%already been counted%' then raise; end if; end;
  perform test_reset();
  assert bal('11111111-1111-1111-1111-111111111111') = before, 'and nothing was credited';
  assert (select count(*) from ad_views where user_id = '11111111-1111-1111-1111-111111111111') = 1, 'one view, not two';
end $$;

-- --- 4. somebody else's nonce pays nothing --------------------------------------------------------
do $$ declare nz uuid; before numeric; begin
  perform test_as('11111111-1111-1111-1111-111111111111');
  perform wind_back('11111111-1111-1111-1111-111111111111', 120);
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  perform test_reset();
  before := bal('22222222-2222-2222-2222-222222222222');
  perform test_as('22222222-2222-2222-2222-222222222222');
  begin
    perform rpc_watch_ad(nz);
    raise exception 'Ben spent Ana''s nonce';
  exception when others then if sqlerrm not like '%not counted%' then raise; end if; end;
  perform test_reset();
  assert bal('22222222-2222-2222-2222-222222222222') = before, 'and was credited nothing';
  assert (select used_at from ad_nonces where nonce = nz) is null, 'and Ana''s nonce is still hers to spend';
end $$;

-- --- 5. a nonce nobody issued pays nothing ----------------------------------------------------------
do $$ declare before numeric; begin
  before := bal('22222222-2222-2222-2222-222222222222');
  perform test_as('22222222-2222-2222-2222-222222222222');
  begin
    perform rpc_watch_ad('00000000-0000-0000-0000-000000000000'::uuid);
    raise exception 'an invented nonce was accepted';
  exception when others then if sqlerrm not like '%not counted%' then raise; end if; end;
  perform test_reset();
  assert bal('22222222-2222-2222-2222-222222222222') = before, 'nothing credited';
end $$;

-- --- 6. an expired nonce pays nothing -----------------------------------------------------------------
do $$ declare nz uuid; before numeric; begin
  perform test_as('22222222-2222-2222-2222-222222222222');
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  perform test_reset();
  update ad_nonces set expires_at = now() - interval '1 second' where nonce = nz;
  before := bal('22222222-2222-2222-2222-222222222222');
  perform test_as('22222222-2222-2222-2222-222222222222');
  begin
    perform rpc_watch_ad(nz);
    raise exception 'a stale nonce was accepted';
  exception when others then if sqlerrm not like '%took too long%' then raise; end if; end;
  perform test_reset();
  assert bal('22222222-2222-2222-2222-222222222222') = before, 'nothing credited';
end $$;

-- --- 7. one ad a minute ---------------------------------------------------------------------------------
do $$ declare nz uuid; begin
  perform test_as('22222222-2222-2222-2222-222222222222');
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  perform rpc_watch_ad(nz);                                   -- Ben's first, and it pays
  begin
    perform rpc_ad_nonce();
    raise exception 'a second ad was offered inside the minute';
  exception when others then if sqlerrm not like '%One ad a minute%' then raise; end if; end;
  perform test_reset();

  -- a nonce issued *before* the last credit is no way round it either
  perform test_as('22222222-2222-2222-2222-222222222222');
  begin
    perform rpc_watch_ad(spare_nonce('22222222-2222-2222-2222-222222222222'));
    raise exception 'an older nonce beat the spacing rule';
  exception when others then if sqlerrm not like '%One ad a minute%' and sqlerrm not like '%took too long%' then raise; end if; end;
  perform test_reset();

  perform wind_back('22222222-2222-2222-2222-222222222222', 61);
  perform test_as('22222222-2222-2222-2222-222222222222');
  nz := (rpc_ad_nonce()->>'nonce')::uuid;                     -- a minute later, fine
  assert (rpc_watch_ad(nz)->>'watched_today')::int = 2, 'the second of the day';
  perform test_reset();
end $$;

-- --- 8. ten a day, counted by the database --------------------------------------------------------------
do $$ declare nz uuid; i int; begin
  for i in 3..10 loop
    perform wind_back('22222222-2222-2222-2222-222222222222', 61);
    perform test_as('22222222-2222-2222-2222-222222222222');
    nz := (rpc_ad_nonce()->>'nonce')::uuid;
    assert (rpc_watch_ad(nz)->>'watched_today')::int = i, format('ad %s', i);
    perform test_reset();
  end loop;
  perform wind_back('22222222-2222-2222-2222-222222222222', 61);
  perform test_as('22222222-2222-2222-2222-222222222222');
  begin
    perform rpc_ad_nonce();
    raise exception 'an eleventh nonce was issued';
  exception when others then if sqlerrm not like '%all ten%' then raise; end if; end;
  perform test_reset();
  assert (select count(*) from ad_views where user_id = '22222222-2222-2222-2222-222222222222') = 10, 'ten views, no more';
  assert bal('22222222-2222-2222-2222-222222222222') = 100 + 2, 'ten ads are two points';
end $$;

-- --- 9. a nonce issued under the cap cannot be spent over it -----------------------------------------------
-- The gap that matters: a nonce taken out while there was room, then spent after the day filled up.
do $$ declare nz uuid; before numeric; begin
  perform test_as('33333333-3333-3333-3333-333333333333');
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  perform test_reset();
  -- the day fills up while that nonce is in flight
  insert into ad_views (user_id, day, seq, reward)
  select '33333333-3333-3333-3333-333333333333', (now() at time zone 'utc')::date, g, 0.2
  from generate_series(1, 10) g;
  before := bal('33333333-3333-3333-3333-333333333333');
  perform test_as('33333333-3333-3333-3333-333333333333');
  begin
    perform rpc_watch_ad(nz);
    raise exception 'an in-flight nonce broke the daily cap';
  exception when others then if sqlerrm not like '%all ten%' and sqlerrm not like '%One ad a minute%' then raise; end if; end;
  perform test_reset();
  assert bal('33333333-3333-3333-3333-333333333333') = before, 'nothing credited past the cap';
  -- the ten were planted straight into the table, so they never reached the ledger: clear them
  -- again before the conservation check at the end
  delete from ad_views where user_id = '33333333-3333-3333-3333-333333333333';
end $$;

-- --- 10. the flag still switches the whole thing off --------------------------------------------------------
do $$ begin
  update app_flags set enabled = false where key = 'rewarded_ads';
  perform test_as('11111111-1111-1111-1111-111111111111');
  begin perform rpc_ad_nonce(); raise exception 'a nonce was issued with the flag off';
  exception when others then if sqlerrm not like '%switched off%' then raise; end if; end;
  begin perform rpc_watch_ad(null); raise exception 'an ad paid with the flag off';
  exception when others then if sqlerrm not like '%switched off%' then raise; end if; end;
  perform test_reset();
  update app_flags set enabled = true where key = 'rewarded_ads';
end $$;

-- --- 11. with the real slot on, the stub cannot pay ------------------------------------------------------------
-- The countdown placeholder stays for testing, but it must not be a way to be paid without an ad.
do $$ begin
  update app_flags set enabled = true where key = 'gam_rewarded';
  perform test_as('33333333-3333-3333-3333-333333333333');
  begin
    perform rpc_watch_ad(null);
    raise exception 'the stub paid out while the real slot was live';
  exception when others then if sqlerrm not like '%not counted%' then raise; end if; end;
  perform test_reset();
  update app_flags set enabled = false where key = 'gam_rewarded';
  -- and with the real slot off, the stub is allowed again
  perform test_as('33333333-3333-3333-3333-333333333333');
  assert (rpc_watch_ad(null)->>'credited')::numeric = 0.2, 'the stub pays while it is the only thing there';
  perform test_reset();
end $$;

-- --- 12. nothing is minted that the ledger does not say ----------------------------------------------------------
do $$ declare credited numeric; views numeric; begin
  select coalesce(sum(amount), 0) into credited from ledger where reason = 'ad_reward';
  select coalesce(sum(reward), 0) into views from ad_views;
  assert credited = views, format('the ledger says %s, the views say %s', credited, views);
  assert credited = (select count(*) from ad_views) * 0.2, 'and every one of them is 0.2';
end $$;

select 'ADS TESTS PASSED' as result;
rollback;
