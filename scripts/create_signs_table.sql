-- Run once in the Supabase SQL Editor to create the signs table.

create table if not exists signs (
    id         text        primary key,   -- "osm_12345678" or "place_N"
    name       text        not null,      -- town name, e.g. "Köln"
    lat        float8      not null,
    lon        float8      not null,
    updated_at timestamptz not null default now()
);

-- Composite index so the Garmin's bbox query (lat range + lon range) is fast
create index if not exists signs_lat_lon on signs (lat, lon);

-- Row Level Security: anon key may read (Garmin app), only service role may write (import script)
alter table signs enable row level security;

create policy "anon read signs"
    on signs for select to anon using (true);
