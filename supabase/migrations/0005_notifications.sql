-- The Pool — §7 notifications. Rows land in `notifications`; the send-notifications
-- Installed in its own schema so it never touches the other tables in this project.
create schema if not exists pool;
set search_path = pool, public, extensions;
-- edge function renders and sends them through Resend. Every type respects the user's toggles.

-- New card opened: crew members, or people watching the competition (public cards)
create or replace function notify_new_card() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
declare m matches;
begin
  select * into m from matches where id = new.match_id;
  if new.crew_id is not null then
    insert into notifications (user_id, type, dedupe_key, payload)
    select cm.user_id, 'new_card', new.id::text,
           jsonb_build_object('card_id', new.id, 'match_id', new.match_id, 'crew_id', new.crew_id, 'opened_by', new.created_by)
    from crew_members cm join notification_settings ns on ns.user_id = cm.user_id
    where cm.crew_id = new.crew_id and cm.user_id <> coalesce(new.created_by, '00000000-0000-0000-0000-000000000000') and ns.new_card
    on conflict do nothing;
  else
    insert into notifications (user_id, type, dedupe_key, payload)
    select ns.user_id, 'new_card', new.id::text,
           jsonb_build_object('card_id', new.id, 'match_id', new.match_id, 'opened_by', new.created_by)
    from notification_settings ns
    where ns.new_card and m.competition_code = any(ns.watched_competitions)
      and ns.user_id <> coalesce(new.created_by, '00000000-0000-0000-0000-000000000000')
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger cards_notify_new after insert on cards for each row execute function notify_new_card();

-- Crew activity: throttled to one digest per user per crew per hour
create or replace function notify_crew_activity() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
declare bucket timestamptz := date_trunc('hour', now());
begin
  insert into notifications (user_id, type, dedupe_key, payload, scheduled_for)
  select cm.user_id, 'crew_activity', new.crew_id || ':' || to_char(bucket, 'YYYYMMDDHH24'),
         jsonb_build_object('crew_id', new.crew_id, 'since', bucket),
         bucket + interval '1 hour'
  from crew_members cm join notification_settings ns on ns.user_id = cm.user_id
  where cm.crew_id = new.crew_id and cm.user_id <> new.user_id and ns.crew_activity
  on conflict do nothing;
  return new;
end $$;
create trigger crew_posts_notify after insert on crew_posts for each row execute function notify_crew_activity();

-- Deadline reminder: run every 5 minutes by cron; catches fixtures 45–65 min from kickoff,
-- deduped per match so the window width does not matter.
create or replace function enqueue_deadline_reminders() returns int
language plpgsql security definer set search_path = pool, public, extensions as $$
declare n int;
begin
  with soon as (
    select m.id as match_id, m.utc_date from matches m
    where m.utc_date between now() + interval '45 minutes' and now() + interval '65 minutes'
      and m.status in ('SCHEDULED', 'TIMED')
  ),
  needed as (
    select k.call_type, k.simple from markets k where k.enabled
  ),
  -- people with an entry that is missing calls
  incomplete as (
    select e.user_id, c.id as card_id, s.match_id
    from soon s join cards c on c.match_id = s.match_id join entries e on e.card_id = c.id
    where (select count(*) from calls x where x.entry_id = e.id)
        < (select count(*) from needed where c.mode = 'complex' or needed.simple)
  ),
  -- crew members who have not started a crew card at all
  absent as (
    select cm.user_id, c.id as card_id, s.match_id
    from soon s join cards c on c.match_id = s.match_id and c.crew_id is not null
    join crew_members cm on cm.crew_id = c.crew_id
    where not exists (select 1 from entries e where e.card_id = c.id and e.user_id = cm.user_id)
  ),
  targets as (select * from incomplete union select * from absent),
  ins as (
    insert into notifications (user_id, type, dedupe_key, payload)
    select t.user_id, 'deadline_reminder', t.match_id::text,
           jsonb_build_object('match_id', t.match_id, 'card_ids', jsonb_agg(t.card_id))
    from targets t join notification_settings ns on ns.user_id = t.user_id
    where ns.deadline_reminder
    group by t.user_id, t.match_id
    on conflict do nothing
    returning 1
  )
  select count(*) into n from ins;
  return n;
end $$;

-- Friday crew card (weekly digest, opt-in)
create or replace function enqueue_weekly_digest() returns int
language plpgsql security definer set search_path = pool, public, extensions as $$
declare n int;
begin
  with ins as (
    insert into notifications (user_id, type, dedupe_key, payload)
    select ns.user_id, 'weekly_digest', to_char(now(), 'IYYY-IW'), '{}'::jsonb
    from notification_settings ns where ns.weekly_digest
    on conflict do nothing returning 1
  ) select count(*) into n from ins;
  return n;
end $$;

-- cron only
revoke execute on all functions in schema pool from public, anon;
grant execute on all functions in schema pool to service_role;
revoke execute on function enqueue_deadline_reminders(), enqueue_weekly_digest(), notify_new_card(), notify_crew_activity() from public, anon, authenticated;
