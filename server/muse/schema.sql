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


-- What the audio engine did on somebody's phone, sent up when the app comes back to
-- the front. "It stops when I switch to another app" is not a bug report anybody can
-- act on, and the interesting minute is always the one with the screen off — so the
-- phone writes it down (see PlaybackLog) and this is where it lands, rather than being
-- read aloud from a screenshot.
create table if not exists playback_reports (
  id      bigserial primary key,
  user_id int not null references users(id) on delete cascade,
  device  text,
  build   text,
  at      timestamptz not null default now(),
  lines   text not null
);

create index if not exists playback_reports_recent
  on playback_reports(user_id, at desc);

-- A queue that keeps going: a song, a record or an artist, and everything the machine
-- thinks belongs next to it. The queue is the station — everything a queue can do a
-- station can do — and this is what it was made from, so it can be asked for more.
create table if not exists stations (
  queue_id   int primary key references queues(id) on delete cascade,
  owner_id   int not null references users(id) on delete cascade,
  kind       text not null,
  seed_track int references tracks(id) on delete set null,
  seed_text  text,
  name       text not null,
  created_at timestamptz not null default now()
);

create table if not exists listens (
  id         bigserial primary key,
  user_id    int not null references users(id) on delete cascade,
  track_id   int not null references tracks(id) on delete cascade,
  started_at timestamptz not null default now(),
  ms_played  int not null default 0,
  completed  boolean not null default false
);

-- Recently played, newest first, for one person. It was a sequential scan and a sort
-- of every listen ever recorded to draw one screen.
create index if not exists listens_recent on listens(user_id, started_at desc);

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

-- What each device is doing, so the others can say so and take over from it.
--
-- One account, several devices — a phone, a browser at a desk, a tablet on a shelf —
-- and until now they only shared a queue: two of them could play the same music at
-- once, each unaware of the other, and moving from one to the other meant finding your
-- place again by hand. These few columns are what a device says about itself, and they
-- are what makes "play this here instead" a thing the app can offer.
alter table devices add column if not exists kind text;
alter table devices add column if not exists playing boolean not null default false;
alter table devices add column if not exists track_id int
      references tracks(id) on delete set null;
alter table devices add column if not exists queue_id int
      references queues(id) on delete set null;
alter table devices add column if not exists position_ms int not null default 0;
alter table devices add column if not exists state_at timestamptz;

-- A name for the row itself.
--
-- A queue can hold the same song twice, and a row was only ever identified by its
-- position — which every insert above it changes. So the player, told the queue had
-- changed, could only look for "the copy nearest where I was", and with two copies
-- equally near it took the earlier one: playback slid from the second copy back to the
-- first and played the same song again. This is the one thing about a row that does
-- not move when the rows around it do.
alter table queue_items add column if not exists item_id bigserial;

-- A mirrored library can be much bigger than the disk it would land on. Twelve thousand
-- liked songs are a list worth having long before they are forty gigabytes worth having,
-- so a big mirror records what is in it and fetches the audio when somebody plays it.
alter table playlists add column if not exists download_mode text not null default 'all';

-- Whose library a track is in.
--
-- The catalog is shared on purpose: one download serves everybody, and a second person
-- adding the same song should get it instantly rather than queue a second copy of the
-- same file. But "the library" is a personal thing, and it was showing every track on
-- the box to every account — one person's twelve thousand mirrored songs buried
-- everyone else's.
create table if not exists library_items (
  user_id  int not null references users(id) on delete cascade,
  track_id int not null references tracks(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (user_id, track_id)
);
create index if not exists library_items_recent on library_items(user_id, added_at desc);

-- Which playlists hold a given song. The primary key answers "what is on this
-- playlist"; this answers the other direction, which is what the add-to-playlist
-- ticks, the favourites lookup and the library trigger all ask.
create index if not exists playlist_items_track on playlist_items(track_id);

-- Membership is recorded by the database rather than by each caller.
--
-- Tracks are attached to people in thirteen places across seven modules — playlist
-- imports, queue edits, jam adds, radio, search-and-download — and a rule enforced in
-- thirteen places is a rule that will be missed in the fourteenth. A trigger on the
-- two tables that say "this track belongs to this person's list" cannot be bypassed.
create or replace function library_note_playlist_item() returns trigger as $$
begin
  insert into library_items(user_id, track_id)
  select p.owner_id, new.track_id from playlists p where p.id = new.playlist_id
  on conflict do nothing;
  return new;
end $$ language plpgsql;

create or replace function library_note_queue_item() returns trigger as $$
begin
  insert into library_items(user_id, track_id)
  select q.user_id, new.track_id from queues q where q.id = new.queue_id
  on conflict do nothing;
  -- In a jam the person who queued it is not always the person whose queue it is.
  if new.added_by is not null then
    insert into library_items(user_id, track_id) values (new.added_by, new.track_id)
    on conflict do nothing;
  end if;
  return new;
end $$ language plpgsql;

create or replace function library_note_listen() returns trigger as $$
begin
  insert into library_items(user_id, track_id) values (new.user_id, new.track_id)
  on conflict do nothing;
  return new;
end $$ language plpgsql;

drop trigger if exists library_from_playlist on playlist_items;
create trigger library_from_playlist after insert on playlist_items
  for each row execute function library_note_playlist_item();

drop trigger if exists library_from_queue on queue_items;
create trigger library_from_queue after insert on queue_items
  for each row execute function library_note_queue_item();

drop trigger if exists library_from_listen on listens;
create trigger library_from_listen after insert on listens
  for each row execute function library_note_listen();

-- Seed once, from everything that was already attached to somebody. Guarded on the
-- table being empty so that removing something from your library stays removed —
-- otherwise the next restart would put it back.
insert into library_items(user_id, track_id, added_at)
select owner, track_id, min(at)
  from (
    select p.owner_id as owner, i.track_id, i.added_at as at
      from playlists p join playlist_items i on i.playlist_id = p.id
    union all
    select q.user_id, i.track_id, q.updated_at
      from queues q join queue_items i on i.queue_id = q.id
    union all
    select l.user_id, l.track_id, l.started_at from listens l
  ) seed
 where not exists (select 1 from library_items)
 group by owner, track_id
on conflict do nothing;

-- Answers from a metadata service, kept for a while.
--
-- An album page asks the same question every time it is opened, and the answer changes
-- about as often as the album does. Caching it is the difference between a screen that
-- opens instantly and one that waits on somebody else's server — and it keeps a library
-- of thousands of albums from turning into thousands of requests.
create table if not exists remote_cache (
  key        text primary key,
  body       jsonb not null,
  fetched_at timestamptz not null default now()
);
create index if not exists remote_cache_age on remote_cache(fetched_at);

-- Artists somebody follows, and the records those artists have put out. Following is
-- per person; the releases are a fact about the artist, so they are shared.
create table if not exists artist_follows (
  user_id    int not null references users(id) on delete cascade,
  provider   text not null default 'deezer',
  remote_id  text not null,
  name       text not null,
  image      text,
  created_at timestamptz not null default now(),
  checked_at timestamptz,
  primary key (user_id, provider, remote_id)
);

create table if not exists artist_releases (
  provider     text not null default 'deezer',
  artist_id    text not null,
  album_id     text not null,
  title        text not null,
  artist       text not null,
  cover        text,
  release_date date,
  record_type  text,
  tracks       int,
  first_seen   timestamptz not null default now(),
  primary key (provider, album_id)
);
create index if not exists artist_releases_by_artist
  on artist_releases(provider, artist_id, release_date desc);

-- What each person has already scrolled past, so "new" means new to you.
create table if not exists feed_seen (
  user_id  int not null references users(id) on delete cascade,
  provider text not null default 'deezer',
  album_id text not null,
  seen_at  timestamptz not null default now(),
  primary key (user_id, provider, album_id)
);

-- Who is allowed to change things that belong to everybody.
--
-- There were no roles, which was fine while there was one person; with three it means
-- anyone can reset anyone's password. Named in the config rather than promoted from
-- inside the app: an account that can make itself an admin is not a role.
alter table users add column if not exists is_admin boolean not null default false;
update users set is_admin = true where name in ('chris', 'joe');

-- Skipping is the one thing a guest can do to what everybody else is hearing, so it
-- starts off. A host who wants a democracy can turn it on; a host who just wants to
-- play records for people should not have to discover the setting first.
-- Legacy: a jam used to have rules — who could add, who could vote to skip. It has
-- none now (everybody in the room can add and can work the controls), so these two
-- columns are read by nothing. Left in place rather than dropped: an old row costs
-- nothing, and dropping columns from a live table to tidy up is not worth it.

-- What the host's player is doing, so everybody else can do the same.
--
-- A jam used to be a shared *queue* and nothing else: guests could add songs and vote,
-- but nobody's play button reached anybody else, so "listening together" meant two
-- people playing the same list at different points in it. This is the transport, kept
-- as one row per jam and stamped with the moment it was true, so a device that reads it
-- late can work out where the music has got to since.
create table if not exists jam_playback (
  jam_id      int primary key references jams(id) on delete cascade,
  track_id    int references tracks(id) on delete set null,
  position_ms int not null default 0,
  playing     boolean not null default false,
  at          timestamptz not null default now()
);

-- Pictures somebody chose: a profile photo, a cover for a playlist that should not be
-- the one drawn from its contents. Both are a signature rather than a path — the file
-- is named from it, so a changed picture is a changed URL and nothing caches wrongly.
alter table users add column if not exists avatar_sig text;
alter table playlists add column if not exists cover_sig text;

-- The back of a record, drawn on.
--
-- Every sleeve has a bare cardboard back, and the player turns records over. What is
-- written there belongs to whoever owns the board: yours is yours, and a jam's is the
-- host's — everybody in the room draws on the record the host is playing, the way a
-- sleeve going round a table collects everybody's handwriting rather than each person
-- getting their own copy.
--
-- One row per stroke rather than one per board. A stroke is small, arrives complete,
-- and can be undone on its own; a single blob per board would have every drawer in a
-- jam overwriting each other's last second of work.
create table if not exists sleeve_marks (
  id          bigserial primary key,
  track_id    int not null references tracks(id) on delete cascade,
  -- Whose board this is. Not who drew: in a jam those differ, and that is the point.
  owner_id    int not null references users(id) on delete cascade,
  author_id   int not null references users(id) on delete cascade,
  -- The client's own id for the stroke, so a stroke still being drawn can be updated
  -- in place as it grows rather than arriving forty times as forty strokes.
  stroke_id   text not null,
  ink         int not null default 0,
  width       real not null default 1.0,
  -- x,y,x,y… in the sleeve's own square, 0 to 1, so it draws at any size.
  points      real[] not null,
  done        boolean not null default false,
  at          timestamptz not null default now(),
  unique (owner_id, track_id, stroke_id)
);

create index if not exists sleeve_marks_board
  on sleeve_marks(owner_id, track_id, id);

-- ---------------------------------------------------------------- other people
--
-- Somebody else's playlist, kept in your own library. A save rather than a copy: the
-- list stays theirs, and what you see is whatever is on it now — which is the point of
-- saving a friend's playlist rather than taking a snapshot of it.
create table if not exists playlist_saves (
  user_id     int not null references users(id) on delete cascade,
  playlist_id int not null references playlists(id) on delete cascade,
  saved_at    timestamptz not null default now(),
  primary key (user_id, playlist_id)
);
create index if not exists playlist_saves_mine
  on playlist_saves(user_id, saved_at desc);

-- Whether anybody else may add to it and take things off it. Off by default: a shared
-- list is a decision the person whose list it is makes, once, out loud.
alter table playlists add column if not exists open_edit boolean not null default false;
