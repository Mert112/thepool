-- The Pool — new call types for multi-sport cards (0009 uses them).
-- Enum values must be committed before they can be used, so they get their own migration.
set search_path = pool, public, extensions;

alter type call_type add value if not exists 'total';       -- over/under the posted points line
alter type call_type add value if not exists 'margin';      -- winner by a band of points/runs
alter type call_type add value if not exists 'top_scorer';  -- the game's top points scorer (basketball)
alter type call_type add value if not exists 'sets';        -- exact set score (tennis)
alter type call_type add value if not exists 'distance';    -- goes the distance: deciding set / judges' decision
alter type call_type add value if not exists 'method';      -- how the fight ends (MMA)
alter type call_type add value if not exists 'round';       -- the round the fight ends in (MMA)
