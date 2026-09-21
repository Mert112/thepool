-- The Pool — the signed-out board (sign-in teaser) reads v_board, whose card join runs these.
-- 0003/0004 granted them to anon, but 0005's blanket "revoke … from anon" took them back.
-- All four only answer for auth.uid(), which is null for anon, so nothing private is exposed.
set search_path = pool, public, extensions;
grant execute on function is_crew_member(uuid, uuid), can_see_card(uuid, uuid), match_card_count(int), match_playing(int) to anon;
