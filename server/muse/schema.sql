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

-- A linked provider account, per muse user. Tokens live here rather than in the
-- config file, because they belong to a person and expire.
create table if not exists provider_accounts (
  user_id       int not null references users(id) on delete cascade,
  provider      text not null,
  display_name  text,
  account_id    text,
  access_token  text,
  refresh_token text,
  expires_at    timestamptz,
  linked_at     timestamptz not null default now(),
  primary key (user_id, provider)
);

-- Entries in a mirrored playlist that could not be matched to anything we can play.
-- Kept so the app can say which songs are missing and why, rather than quietly
-- returning a shorter playlist than the one on Spotify.
create table if not exists playlist_unmatched (
  playlist_id int not null references playlists(id) on delete cascade,
  pos         int not null,
  remote_id   text,
  title       text,
  artists     text[],
  reason      text,
  primary key (playlist_id, pos)
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
alter table covers add column if not exists color text;
alter table tracks add column if not exists fail_code text;
alter table media add column if not exists role text not null default 'canonical';
alter table tracks add column if not exists fingerprint text;
alter table tracks add column if not exists discovered_via text not null default 'user';
alter table jobs add column if not exists next_attempt_at timestamptz not null default now();
alter table matches add column if not exists remote_title text;
alter table matches add column if not exists remote_artists text[];
alter table matches add column if not exists decided_at timestamptz not null default now();

create index if not exists jobs_pending_next on jobs(kind, state, next_attempt_at);
create index if not exists media_sha_idx on media(sha256);
alter table playlists add column if not exists source_name text;
alter table playlists add column if not exists last_error text;
-- Accounts live in the database, with muse.toml as the seed rather than the source of
-- truth: adding someone should not mean editing a file and restarting the server.
alter table users add column if not exists pw_hash text;
alter table users add column if not exists created_by int references users(id);

-- A one-time code so someone can set their own password. You should not have to know
-- another person's password in order to give them an account.
create table if not exists invites (
  code       text primary key,
  created_by int not null references users(id) on delete cascade,
  note       text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz,
  used_by    int references users(id)
);

-- Downloads are managed, not just queued. Priority so a track you are about to play
-- jumps a 200-track backfill; a batch so a playlist import reads as one thing rather
-- than two hundred anonymous rows.
alter table jobs add column if not exists priority int not null default 100;
alter table jobs add column if not exists batch_id text;
alter table jobs add column if not exists batch_label text;
create index if not exists jobs_batch on jobs(batch_id);
create index if not exists jobs_queue_order on jobs(kind, state, priority, created_at);

-- Server-wide switches that outlive a restart. Pausing downloads is the only one so
-- far, and it belongs in the database rather than in a process that gets redeployed.
create table if not exists settings (
  key   text primary key,
  value text,
  set_at timestamptz not null default now()
);

-- Jobs enqueued before batches existed still belong to an import. Tag them from the
-- mirrored playlist their track came from, so a queue that is already 1300 deep reads
-- as a handful of playlists instead of an anonymous wall. Only tracks discovered by a
-- sync are touched: a track you asked for yourself stays unlabelled and ahead.
update jobs j set batch_id = b.batch_id, batch_label = b.label
  from (select distinct on (pi.track_id) pi.track_id,
               'spotify:' || p.remote_id as batch_id,
               'Spotify · ' || p.name    as label
          from playlist_items pi
          join playlists p on p.id = pi.playlist_id
          join tracks t on t.id = pi.track_id
         where p.kind = 'spotify' and t.discovered_via = 'sync'
         order by pi.track_id, p.id) b
 where j.kind = 'ingest' and j.batch_id is null
   and j.state in ('pending', 'leased', 'failed')
   and (j.payload->>'track_id')::int = b.track_id;

-- A jam: one queue, several people, from wherever they are. The host's queue is the
-- record box everyone is reaching into; membership is what lets a guest reach in.
create table if not exists jams (
  id           serial primary key,
  code         text unique not null,
  host_id      int not null references users(id) on delete cascade,
  queue_id     int not null references queues(id) on delete cascade,
  guests_can_add   boolean not null default true,
  guests_can_skip  boolean not null default true,
  created_at   timestamptz not null default now(),
  ended_at     timestamptz
);
create index if not exists jams_live on jams(host_id) where ended_at is null;

create table if not exists jam_members (
  jam_id    int not null references jams(id) on delete cascade,
  user_id   int not null references users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (jam_id, user_id)
);

-- Skipping is the one thing a guest can do to what everyone else is hearing, so it is
-- a vote rather than a button.
create table if not exists jam_skip_votes (
  jam_id   int not null references jams(id) on delete cascade,
  track_id int not null references tracks(id) on delete cascade,
  user_id  int not null references users(id) on delete cascade,
  voted_at timestamptz not null default now(),
  primary key (jam_id, track_id, user_id)
);

-- Who put this on. In a jam that is the difference between a queue and an argument.
alter table queue_items add column if not exists added_by int references users(id);
