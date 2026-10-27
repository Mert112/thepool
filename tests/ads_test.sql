-- Rewarded ads (0025, 0026): the nonce rules, the daily cap, and the fraud score that replaced
-- the minute between ads. Google's rewarded slot hands the page no token of its
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
  assert ad_settings()->'spacing_seconds' is null, 'no minute between ads any more (0026)';
  assert (ad_settings()->>'stub_seconds')::int = 25, 'the stub ad is twenty-five seconds';
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

-- --- 7. the next ad can start the moment one finishes (0026) -------------------------------------
do $$ declare nz uuid; older uuid; begin
  perform test_as('22222222-2222-2222-2222-222222222222');
  older := (rpc_ad_nonce()->>'nonce')::uuid;                  -- taken out and left for later
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  perform rpc_watch_ad(nz);                                   -- Ben's first, and it pays
  nz := (rpc_ad_nonce()->>'nonce')::uuid;                     -- and straight away, another
  assert (rpc_watch_ad(nz)->>'watched_today')::int = 2, 'the second of the day, no wait';
  -- a nonce issued earlier and never spent is still good until it expires
  assert (rpc_watch_ad(older)->>'watched_today')::int = 3, 'an older unspent nonce still pays';
  perform test_reset();
end $$;

-- --- 8. ten a day, counted by the database --------------------------------------------------------------
do $$ declare nz uuid; i int; begin
  for i in 4..10 loop
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
  exception when others then if sqlerrm not like '%all ten%' then raise; end if; end;
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

-- --- 12. every credit records where it came from (0026) -----------------------------------------------
create or replace function test_headers(ip text, ua text) returns void language sql as $$
  select set_config('request.headers', json_build_object('cf-connecting-ip', ip, 'user-agent', ua)::text, true);
$$;
create or replace function last_view(u text) returns ad_views language sql stable
security definer set search_path = pool, public as $$
  select * from ad_views where user_id = u::uuid order by created_at desc, seq desc limit 1 $$;
-- make each credit look like it happened `secs` apart, so the gap rule can be tested honestly
create or replace function spread_out(u text, secs int) returns void
language sql security definer set search_path = pool, public as $$
  update ad_views v set created_at = now() - make_interval(secs => secs * (10 - v.seq)) where user_id = u::uuid;
$$;
create or replace function is_flagged(u text) returns boolean language sql stable
security definer set search_path = pool, public as $$
  select coalesce((select flagged from ad_fraud_scores() where user_id = u::uuid), false) $$;
create or replace function reasons_of(u text) returns text language sql stable
security definer set search_path = pool, public as $$
  select array_to_string(reasons, '; ') from ad_fraud_scores() where user_id = u::uuid $$;

do $$ declare nz uuid; v ad_views; begin
  perform test_as('11111111-1111-1111-1111-111111111111');
  perform test_headers('203.0.113.7', 'Mozilla/5.0 test');
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  perform rpc_watch_ad(nz, 'ABCDEF0123456789abcdef0123456789');
  perform test_reset();
  v := last_view('11111111-1111-1111-1111-111111111111');
  assert v.fingerprint = 'abcdef0123456789abcdef0123456789', 'the fingerprint is kept, lower-cased';
  assert v.ip = '203.0.113.7', 'the IP comes from the gateway''s header';
  assert v.user_agent = 'Mozilla/5.0 test', 'and so does the user-agent';
  -- a fingerprint that is not a hash is dropped, and the ad still pays
  perform test_as('11111111-1111-1111-1111-111111111111');
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  assert (rpc_watch_ad(nz, 'not a hash; drop table')->>'credited')::numeric = 0.2, 'junk fingerprint, still credited';
  perform test_reset();
  assert (last_view('11111111-1111-1111-1111-111111111111')).fingerprint is null, 'and the junk was not stored';
  assert has_function_privilege('authenticated', 'pool.ad_fraud_scores()', 'execute') = false, 'players cannot read the score';
  assert has_table_privilege('authenticated', 'pool.admin_prize_claims', 'select') = false, 'nor the admin view';
  assert has_table_privilege('anon', 'pool.admin_ad_fraud', 'select') = false, 'nor anyone signed out';
end $$;

-- --- 13. sharing a device or an IP with three or more others flags every one of them ---------------------
insert into auth.users (id, email) values
  ('44444444-4444-4444-4444-444444444444', 'dan@example.com'),
  ('55555555-5555-5555-5555-555555555555', 'eda@example.com'),
  ('66666666-6666-6666-6666-666666666666', 'fil@example.com'),
  ('77777777-7777-7777-7777-777777777777', 'gul@example.com');

do $$ declare u text; nz uuid; i int := 0; begin
  -- three accounts on one device: each shares with two others, which is not yet three
  foreach u in array array['44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555',
                           '66666666-6666-6666-6666-666666666666'] loop
    i := i + 1;
    perform test_as(u);
    perform test_headers('198.51.100.' || i, 'ua');
    nz := (rpc_ad_nonce()->>'nonce')::uuid;
    perform rpc_watch_ad(nz, 'feedfacefeedface');
    perform test_reset();
  end loop;
  assert not is_flagged('44444444-4444-4444-4444-444444444444'), 'two others is not three';

  -- a fourth: now each of the four shares the device with three others
  perform test_as('77777777-7777-7777-7777-777777777777');
  perform test_headers('198.51.100.99', 'ua');
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  perform rpc_watch_ad(nz, 'feedfacefeedface');
  perform test_reset();
  assert is_flagged('44444444-4444-4444-4444-444444444444'), 'three others sharing a device is a flag';
  assert is_flagged('77777777-7777-7777-7777-777777777777'), 'for every account on it';
  assert reasons_of('77777777-7777-7777-7777-777777777777') like '%device shared with 3 other accounts%', reasons_of('77777777-7777-7777-7777-777777777777');
  assert not is_flagged('11111111-1111-1111-1111-111111111111'), 'Ana is on her own device';

  -- the same by IP: Ana and Cem join Dan's address, and with Eda that makes four on 198.51.100.1
  foreach u in array array['11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
                           '55555555-5555-5555-5555-555555555555'] loop
    perform test_as(u);
    perform test_headers('198.51.100.1', 'ua');
    nz := (rpc_ad_nonce()->>'nonce')::uuid;
    perform rpc_watch_ad(nz, null);
    perform test_reset();
  end loop;
  assert is_flagged('11111111-1111-1111-1111-111111111111'), 'four accounts on one IP flags Ana';
  assert reasons_of('11111111-1111-1111-1111-111111111111') like '%IP shared with 3 other accounts%', reasons_of('11111111-1111-1111-1111-111111111111');
end $$;

-- --- 14. credits averaging under twenty seconds apart are a flag; twenty-five is not ---------------------
insert into auth.users (id, email) values
  ('88888888-8888-8888-8888-888888888888', 'hal@example.com'),
  ('99999999-9999-9999-9999-999999999999', 'ivo@example.com');
do $$ declare nz uuid; i int; begin
  for i in 1..4 loop
    perform test_as('88888888-8888-8888-8888-888888888888');
    perform test_headers('192.0.2.8', 'ua');
    nz := (rpc_ad_nonce()->>'nonce')::uuid; perform rpc_watch_ad(nz, '8888888888888888');
    perform test_as('99999999-9999-9999-9999-999999999999');
    perform test_headers('192.0.2.9', 'ua');
    nz := (rpc_ad_nonce()->>'nonce')::uuid; perform rpc_watch_ad(nz, '9999999999999999');
    perform test_reset();
  end loop;
  perform spread_out('88888888-8888-8888-8888-888888888888', 5);    -- a bot
  perform spread_out('99999999-9999-9999-9999-999999999999', 26);   -- back to back on the 25-second stub
  assert is_flagged('88888888-8888-8888-8888-888888888888'), 'five seconds apart is a flag';
  assert reasons_of('88888888-8888-8888-8888-888888888888') like '%ads average 5s apart%', reasons_of('88888888-8888-8888-8888-888888888888');
  assert not is_flagged('99999999-9999-9999-9999-999999999999'), 'one ad straight after another is not';
  -- flagged is not banned: Hal can still watch and be paid
  perform test_as('88888888-8888-8888-8888-888888888888');
  nz := (rpc_ad_nonce()->>'nonce')::uuid;
  assert (rpc_watch_ad(nz, '8888888888888888')->>'credited')::numeric = 0.2, 'a flagged account still earns';
  perform test_reset();
end $$;

-- --- 15. a flagged claim carries its warning in the admin view --------------------------------------------
do $$ declare w text; begin
  update profiles set balance = 1000000 where id in ('88888888-8888-8888-8888-888888888888', '99999999-9999-9999-9999-999999999999');
  perform test_as('88888888-8888-8888-8888-888888888888'); perform rpc_claim_prize();
  perform test_as('99999999-9999-9999-9999-999999999999'); perform rpc_claim_prize();
  perform test_reset();
  select warning into w from admin_prize_claims where user_id = '88888888-8888-8888-8888-888888888888';
  assert w like '⚠ %ads average%', format('Hal''s claim should warn, says %s', w);
  assert (select warning from admin_prize_claims where user_id = '99999999-9999-9999-9999-999999999999') is null, 'Ivo''s does not';
  assert (select flagged from admin_ad_fraud where user_id = '88888888-8888-8888-8888-888888888888'), 'and the fraud list agrees';
  -- the claims were played for the test; undo them, and the balances, before the ledger check
  delete from prize_claims where user_id in ('88888888-8888-8888-8888-888888888888', '99999999-9999-9999-9999-999999999999');
  update profiles p set balance = (select coalesce(sum(amount), 0) from ledger l where l.user_id = p.id)
   where id in ('88888888-8888-8888-8888-888888888888', '99999999-9999-9999-9999-999999999999');
end $$;

-- --- 16. with the flag on, the first claim needs a verified phone — once, and one number per account -----
do $$ declare r text; begin
  update app_flags set enabled = true where key = 'phone_verification';
  update profiles set balance = 1000000 where id in ('88888888-8888-8888-8888-888888888888', '99999999-9999-9999-9999-999999999999');
  perform test_as('88888888-8888-8888-8888-888888888888');
  assert (my_stats()->>'phone_needed')::boolean, 'the profile knows to ask';
  begin perform rpc_claim_prize(); raise exception 'a claim went in without a phone';
  exception when others then if sqlerrm not like '%Verify your phone%' then raise; end if; end;
  -- the player cannot mark themselves verified
  begin perform phone_mark_verified('88888888-8888-8888-8888-888888888888', '+905551234567');
        raise exception 'a player verified their own phone';
  exception when insufficient_privilege then null; end;
  perform test_reset();

  assert phone_can_start('88888888-8888-8888-8888-888888888888', '0555 123') like '%country code%', 'a number needs its country code';
  assert phone_can_start('88888888-8888-8888-8888-888888888888', '+905551234567') is null, 'a real number may be sent a code';
  perform phone_mark_verified('88888888-8888-8888-8888-888888888888', '+905551234567');

  perform test_as('88888888-8888-8888-8888-888888888888');
  assert not (my_stats()->>'phone_needed')::boolean, 'verified once, never asked again';
  assert rpc_claim_prize() is not null, 'and the claim goes in';
  perform test_reset();

  -- Ivo cannot use Hal's number, either to be sent a code or to be marked with it
  r := phone_can_start('99999999-9999-9999-9999-999999999999', '+905551234567');
  assert r like '%already on another account%', coalesce(r, 'no refusal');
  begin perform phone_mark_verified('99999999-9999-9999-9999-999999999999', '+905551234567');
        raise exception 'one number went on two accounts';
  exception when others then if sqlerrm not like '%already on another account%' then raise; end if; end;
  -- and Hal cannot add a second
  begin perform phone_mark_verified('88888888-8888-8888-8888-888888888888', '+359888123456');
        raise exception 'one account took two numbers';
  exception when others then if sqlerrm not like '%already verified%' then raise; end if; end;

  -- codes are rationed: three to a number in a day
  assert phone_can_start('99999999-9999-9999-9999-999999999999', '+359888000001') is null, 'one';
  assert phone_can_start('99999999-9999-9999-9999-999999999999', '+359888000001') is null, 'two';
  assert phone_can_start('99999999-9999-9999-9999-999999999999', '+359888000001') is null, 'three';
  assert phone_can_start('99999999-9999-9999-9999-999999999999', '+359888000001') like 'Too many codes%', 'a fourth is refused';

  -- with the flag off nobody is asked
  update app_flags set enabled = false where key = 'phone_verification';
  perform test_as('99999999-9999-9999-9999-999999999999');
  assert not (my_stats()->>'phone_needed')::boolean, 'flag off, no phone';
  assert rpc_claim_prize() is not null, 'and the claim goes in without one';
  perform test_reset();
  assert has_table_privilege('authenticated', 'pool.phone_verifications', 'select') = false, 'numbers are not readable';
  assert has_function_privilege('authenticated', 'pool.phone_can_start(uuid, text)', 'execute') = false, 'only the edge function sends codes';
  delete from prize_claims where user_id in ('88888888-8888-8888-8888-888888888888', '99999999-9999-9999-9999-999999999999');
  update profiles p set balance = (select coalesce(sum(amount), 0) from ledger l where l.user_id = p.id)
   where id in ('88888888-8888-8888-8888-888888888888', '99999999-9999-9999-9999-999999999999');
end $$;

-- --- 17. nothing is minted that the ledger does not say ----------------------------------------------------------
do $$ declare credited numeric; views numeric; begin
  select coalesce(sum(amount), 0) into credited from ledger where reason = 'ad_reward';
  select coalesce(sum(reward), 0) into views from ad_views;
  assert credited = views, format('the ledger says %s, the views say %s', credited, views);
  assert credited = (select count(*) from ad_views) * 0.2, 'and every one of them is 0.2';
end $$;

select 'ADS TESTS PASSED' as result;
rollback;
