-- The Pool — MMA: "How it ends" already covers "Goes the distance" (Decision = it went the distance),
-- so the distance call goes and the method joins the simple card. KO and TKO stay one option: ESPN
-- records them as a single result ("KO/TKO"), and so does every major sportsbook's method-of-victory market.
set search_path = pool, public, extensions;
update markets set enabled = false where sport = 'mma' and call_type = 'distance';
update markets set simple = true, sort_order = 2, description = 'KO/TKO, submission, or the judges'' scorecards.'
 where sport = 'mma' and call_type = 'method';
update markets set sort_order = 3 where sport = 'mma' and call_type = 'round';
