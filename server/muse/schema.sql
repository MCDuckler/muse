-- muse schema. Applied idempotently at startup;each statement is idempotent.
create extension if not exists pg_trgm;
create extension if not exists unaccent;

create table if not exists users (
  id          serial primary key,
  name        text unique not null,
  created_at  timestamptz not null default now()
);

create table if not exists devices (
  id          serial primary key,
  user_id     int not null references users(id) on delete cascade,
  name        text not null,
  platform    text,
  token_hash  text unique not null,
  created_at  timestamptz not null default now(),
  last_seen   timestamptz
);

create table if not exists covers (
  id      serial primary key,
  sha256  text unique not null,
  w       int, h int,
  path    text not null,
  source  text
);

create table if not exists tracks (
  id            serial primary key,
  title         text not null,
  artists       text[] not null default '{}',
  album         text,
  duration_ms   int,
  isrc          text,
  mbid          text,
  release_year  int,
  cover_id      int references covers(id),
  source        text not null default 'youtube',   -- youtube | custom
  state         text not null default 'pending',   -- pending|downloading|ready|failed
  fail_reason   text,
  loudness_lufs real,
  gain_db       real,
  created_at    timestamptz not null default now(),
  norm_title    text generated always as (lower(regexp_replace(title,'[^[:alnum:] ]','','g'))) stored
);
create index if not exists tracks_norm_trgm on tracks using gin (norm_title gin_trgm_ops);
create index if not exists tracks_state_idx on tracks(state);

create table if not exists track_sources (
  track_id    int not null references tracks(id) on delete cascade,
  provider    text not null,          -- ytmusic | upload
  provider_id text not null,
  raw         jsonb not null default '{}',
  fetched_at  timestamptz not null default now(),
  primary key (provider, provider_id)
);
create index if not exists track_sources_track on track_sources(track_id);

create table if not exists media (
  id        serial primary key,
  track_id  int not null references tracks(id) on delete cascade,
  sha256    text not null,
  codec     text,
  bitrate   int,
  bytes     bigint not null,
  path      text not null,
  ready_at  timestamptz not null default now(),
  role      text not null default 'canonical',   -- canonical | original
  unique (track_id, sha256)
);

create table if not exists workers (
  id         serial primary key,
  name       text unique not null,
  arch       text,
  last_seen  timestamptz,
  leased     int not null default 0
);

create table if not exists jobs (
  id           serial primary key,
  kind         text not null,          -- ingest | meta | lyrics | sync
  payload      jsonb not null default '{}',
  state        text not null default 'pending',   -- pending|leased|done|failed
  attempts     int not null default 0,
  leased_by    text,
  leased_until timestamptz,
  error        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists jobs_pending on jobs(kind, state, created_at);

create table if not exists playlists (
  id             serial primary key,
  owner_id       int not null references users(id) on delete cascade,
  name           text not null,
  kind           text not null default 'local',  -- local|spotify|ytmusic
  remote_id      text,
  sync_mode      text not null default 'off',
  last_synced_at timestamptz,
  created_at     timestamptz not null default now()
);
create table if not exists playlist_items (
  playlist_id int not null references playlists(id) on delete cascade,
  pos         int not null,
  track_id    int not null references tracks(id) on delete cascade,
  added_at    timestamptz not null default now(),
  primary key (playlist_id, pos)
);

create table if not exists queues (
  id           serial primary key,
  user_id      int not null references users(id) on delete cascade,
  name         text not null,
  cursor_index int not null default 0,
  position_ms  int not null default 0,
  shuffle      boolean not null default false,
  repeat       text not null default 'off',
  rev          int not null default 1,
  updated_at   timestamptz not null default now(),
  unique (user_id, name)
);
create table if not exists queue_items (
  queue_id int not null references queues(id) on delete cascade,
  pos      int not null,
  track_id int not null references tracks(id) on delete cascade,
  origin   text not null default 'user',   -- user|autoplay|radio
  primary key (queue_id, pos)
);

create table if not exists matches (
  remote_kind text not null,
  remote_id   text not null,
  track_id    int references tracks(id) on delete set null,
  confidence  real,
  method      text,
  decided_by  text,
  primary key (remote_kind, remote_id)
);


create table if not exists listens (
  id         bigserial primary key,
  user_id    int not null references users(id) on delete cascade,
  track_id   int not null references tracks(id) on delete cascade,
  started_at timestamptz not null default now(),
  ms_played  int not null default 0,
  completed  boolean not null default false
);

create table if not exists lyrics (
  track_id   int primary key references tracks(id) on delete cascade,
  synced     text,
  plain      text,
  source     text,
  fetched_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Additive migrations. They run after every create above, because an ALTER
-- placed next to the column it adds would execute before its table exists.
-- ---------------------------------------------------------------------------
alter table media add column if not exists role text not null default 'canonical';
alter table tracks add column if not exists fingerprint text;
alter table tracks add column if not exists discovered_via text not null default 'user';
alter table jobs add column if not exists next_attempt_at timestamptz not null default now();
alter table matches add column if not exists remote_title text;
alter table matches add column if not exists remote_artists text[];
alter table matches add column if not exists decided_at timestamptz not null default now();

create index if not exists jobs_pending_next on jobs(kind, state, next_attempt_at);
create index if not exists media_sha_idx on media(sha256);
