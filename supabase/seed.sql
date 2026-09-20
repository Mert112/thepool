-- Demo data for local development when no provider key is configured.
-- Real deployments never need this: sync-fixtures fills competitions, teams, players and matches.
insert into teams (id, name, short_name, tla) values
  (57, 'Arsenal', 'Arsenal', 'ARS'), (64, 'Liverpool', 'Liverpool', 'LIV'),
  (86, 'Real Madrid', 'Real Madrid', 'RMA'), (65, 'Manchester City', 'Man City', 'MCI')
on conflict (id) do nothing;

insert into players (id, team_id, name, position) values
  (1, 57, 'Raya', 'Goalkeeper'), (2, 57, 'Saliba', 'Defence'), (3, 57, 'Rice', 'Midfield'), (4, 57, 'Ødegaard', 'Midfield'), (5, 57, 'Saka', 'Offence'), (6, 57, 'Havertz', 'Offence'),
  (11, 64, 'Alisson', 'Goalkeeper'), (12, 64, 'Van Dijk', 'Defence'), (13, 64, 'Mac Allister', 'Midfield'), (14, 64, 'Szoboszlai', 'Midfield'), (15, 64, 'Salah', 'Offence'), (16, 64, 'Gakpo', 'Offence'),
  (21, 86, 'Courtois', 'Goalkeeper'), (22, 86, 'Rüdiger', 'Defence'), (23, 86, 'Valverde', 'Midfield'), (24, 86, 'Bellingham', 'Midfield'), (25, 86, 'Vinícius Jr', 'Offence'), (26, 86, 'Mbappé', 'Offence'),
  (31, 65, 'Ederson', 'Goalkeeper'), (32, 65, 'Dias', 'Defence'), (33, 65, 'Rodri', 'Midfield'), (34, 65, 'De Bruyne', 'Midfield'), (35, 65, 'Foden', 'Offence'), (36, 65, 'Haaland', 'Offence')
on conflict (id) do nothing;

insert into matches (id, competition_code, season, matchday, utc_date, status, home_team_id, away_team_id) values
  (900001, 'PL', '2026', 4, now() + interval '5 hours', 'TIMED', 57, 64),
  (900002, 'CL', '2026', 1, now() + interval '1 day 2 hours', 'TIMED', 86, 65),
  (900003, 'PL', '2026', 4, now() + interval '2 days', 'TIMED', 65, 57)
on conflict (id) do nothing;
