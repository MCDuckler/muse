"""Artwork and metadata. The rule that matters: a cover must belong to the track."""
from __future__ import annotations

import io

import pytest
from PIL import Image

from muse import catalog, db, enrich


def _png(colour=(200, 90, 30), size=(700, 700)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, colour).save(buf, format="PNG")
    return buf.getvalue()


@pytest.fixture()
def ready_track(client, hdr, wsec, complete_job):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], t["id"])
    return t


# ---------------- the job is actually scheduled ----------------
def test_a_finished_ingest_queues_enrichment(client, hdr, wsec, complete_job):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], t["id"])
    meta = client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w", "kind": "meta"}).json()["jobs"]
    assert len(meta) == 1 and meta[0]["payload"]["track_id"] == t["id"]


# ---------------- matching guards the artwork ----------------
def test_a_confident_match_attaches_its_cover(client, hdr, cfg, ready_track, monkeypatch):
    monkeypatch.setattr(enrich, "_deezer", lambda title, artist: [{
        "title": "Test Song", "artists": ["Tester"], "duration_ms": 123_000,
        "album": "Real Album", "cover": "https://example.test/cover.jpg",
        "provider": "deezer",
    }])
    monkeypatch.setattr(enrich, "_download", lambda url, min_px=0: _png())

    result = enrich.enrich_track(cfg, ready_track["id"])
    assert result["cover"] is True and result["matched"] == "deezer"

    got = client.get(f"/tracks/{ready_track['id']}", headers=hdr).json()
    assert got["cover_url"] == f"/tracks/{ready_track['id']}/cover"
    # The album already came from the source of the audio, so enrichment leaves it be.
    assert got["album"] == "Test Album"


def test_a_wrong_length_candidate_never_supplies_the_cover(client, hdr, cfg,
                                                           ready_track, monkeypatch):
    """Same title and artist, minutes apart: the right song, the wrong recording —
    exactly the case that would otherwise put someone else's album art on a track."""
    monkeypatch.setattr(enrich, "_deezer", lambda title, artist: [{
        "title": "Test Song", "artists": ["Tester"], "duration_ms": 400_000,
        "album": "Wrong Album", "cover": "https://example.test/wrong.jpg",
        "provider": "deezer",
    }])
    monkeypatch.setattr(enrich, "_itunes", lambda title, artist: [])
    downloaded = []
    monkeypatch.setattr(enrich, "_download",
                        lambda url, min_px=0: downloaded.append(url) or _png())

    result = enrich.enrich_track(cfg, ready_track["id"])
    assert result["matched"] is None
    assert "https://example.test/wrong.jpg" not in downloaded
    got = client.get(f"/tracks/{ready_track['id']}", headers=hdr).json()
    assert got["album"] != "Wrong Album"


def test_itunes_is_tried_when_deezer_has_nothing(client, hdr, cfg, ready_track,
                                                 monkeypatch):
    monkeypatch.setattr(enrich, "_deezer", lambda title, artist: [])
    monkeypatch.setattr(enrich, "_itunes", lambda title, artist: [{
        "title": "Test Song", "artists": ["Tester"], "duration_ms": 123_000,
        "album": "From iTunes", "year": "2011",
        "cover": "https://example.test/it.jpg", "provider": "itunes",
    }])
    monkeypatch.setattr(enrich, "_download", lambda url, min_px=0: _png())

    assert enrich.enrich_track(cfg, ready_track["id"])["matched"] == "itunes"


def test_enrichment_fills_gaps_but_never_overwrites(client, hdr, cfg, wsec,
                                                    complete_job, monkeypatch):
    """What the audio source said wins; enrichment only fills what is missing."""
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], t["id"])
    db.run("update tracks set album=null, release_year=null where id=%s", (t["id"],))

    monkeypatch.setattr(enrich, "_deezer", lambda title, artist: [])
    monkeypatch.setattr(enrich, "_itunes", lambda title, artist: [{
        "title": "Test Song", "artists": ["Tester"], "duration_ms": 123_000,
        "album": "Filled In", "year": "1999",
        "cover": "https://example.test/i.jpg", "provider": "itunes",
    }])
    monkeypatch.setattr(enrich, "_download", lambda url, min_px=0: _png())
    enrich.enrich_track(cfg, t["id"])

    got = client.get(f"/tracks/{t['id']}", headers=hdr).json()
    assert got["album"] == "Filled In"
    assert db.one("select release_year from tracks where id=%s", (t["id"],))["release_year"] == 1999


# ---------------- serving ----------------
def test_cover_is_served_with_a_thumbnail_and_needs_auth(client, hdr, cfg,
                                                         ready_track, monkeypatch):
    monkeypatch.setattr(enrich, "_deezer", lambda title, artist: [{
        "title": "Test Song", "artists": ["Tester"], "duration_ms": 123_000,
        "album": "A", "cover": "https://example.test/c.jpg", "provider": "deezer",
    }])
    monkeypatch.setattr(enrich, "_download", lambda url, min_px=0: _png(size=(800, 800)))
    enrich.enrich_track(cfg, ready_track["id"])

    big = client.get(f"/tracks/{ready_track['id']}/cover", headers=hdr)
    small = client.get(f"/tracks/{ready_track['id']}/cover",
                       headers=hdr, params={"size": "sm"})
    assert big.status_code == 200 and small.status_code == 200
    assert len(small.content) < len(big.content), "sm must be the cheaper variant"
    assert "immutable" in big.headers["cache-control"]

    # <img> cannot send headers, so the signed key has to work here too
    key = client.get("/auth/stream-key", headers=hdr).json()["key"]
    assert client.get(f"/tracks/{ready_track['id']}/cover", params={"k": key}).status_code == 200
    assert client.get(f"/tracks/{ready_track['id']}/cover").status_code == 401


def test_a_track_without_a_cover_says_so(client, hdr, ready_track):
    assert client.get(f"/tracks/{ready_track['id']}", headers=hdr).json()["cover_url"] is None
    assert client.get(f"/tracks/{ready_track['id']}/cover", headers=hdr).status_code == 404


def test_a_record_shares_its_cover_with_the_rest_of_itself(client, hdr, cfg, wsec,
                                                           complete_job, monkeypatch):
    """One song of an album with its sleeve and the next one a grey square is the same
    record drawn two ways in one list — and the picture is already here, filed under
    the song beside it. Nine thousand Bandcamp tracks arrived through a mirror that
    never asked anybody for artwork; this is what stops them being blank."""
    made = []
    for n in range(3):
        t = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": f"SAME{n}"}).json()
        job = client.post("/internal/jobs/lease", headers=wsec,
                          json={"worker": "w"}).json()["jobs"][0]
        complete_job(job["id"], t["id"])
        db.run("update tracks set album=%s, artists=%s where id=%s",
               ("One Record", ["A Band"], t["id"]))
        made.append(t["id"])

    # The first one finds a cover of its own.
    monkeypatch.setattr(enrich, "_deezer", lambda title, artist: [{
        "title": "Test Song", "artists": ["Tester"], "duration_ms": 123_000,
        "album": "One Record", "cover": "https://example.test/cover.jpg",
        "provider": "deezer",
    }])
    monkeypatch.setattr(enrich, "_download", lambda url, min_px=0: _png())
    first = enrich.enrich_track(cfg, made[0])
    assert first["cover"] is True
    assert first["shared_with"] == 2, "the rest of the record got it too"

    for track_id in made[1:]:
        assert client.get(f"/tracks/{track_id}", headers=hdr).json()["cover_url"] \
            == f"/tracks/{track_id}/cover"

    # And a track that turns up later, whose own lookup finds nothing, takes it.
    late = client.post("/tracks/resolve", headers=hdr,
                       json={"video_id": "SAMELATE"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], late["id"])
    db.run("update tracks set album=%s, artists=%s where id=%s",
           ("One Record", ["A Band"], late["id"]))
    monkeypatch.setattr(enrich, "_deezer", lambda title, artist: [])
    monkeypatch.setattr(enrich, "_itunes", lambda title, artist: [])
    monkeypatch.setattr(enrich, "_download", lambda url, min_px=0: None)

    result = enrich.enrich_track(cfg, late["id"])
    assert result["borrowed"] is True
    assert client.get(f"/tracks/{late['id']}", headers=hdr).json()["cover_url"] \
        is not None


def test_a_cover_is_not_shared_with_songs_that_only_lack_an_album(client, hdr, cfg,
                                                                  wsec, complete_job,
                                                                  monkeypatch):
    """"No album" is not an album: sharing across the blank would put one record's
    sleeve on every loose track in the library."""
    loose = []
    for n in range(2):
        t = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": f"LOOSE{n}"}).json()
        job = client.post("/internal/jobs/lease", headers=wsec,
                          json={"worker": "w"}).json()["jobs"][0]
        complete_job(job["id"], t["id"])
        db.run("update tracks set album=null, artists=%s where id=%s",
               (["Someone"], t["id"]))
        loose.append(t["id"])

    monkeypatch.setattr(enrich, "_deezer", lambda title, artist: [])
    monkeypatch.setattr(enrich, "_itunes", lambda title, artist: [])
    monkeypatch.setattr(enrich, "_download", lambda url, min_px=0: _png())
    db.run("update tracks set cover_id=(select id from covers order by id limit 1) "
           "where id=%s", (loose[0],))

    result = enrich.enrich_track(cfg, loose[1])
    assert result["borrowed"] is False


def test_identical_covers_are_stored_once(client, hdr, cfg, ready_track, monkeypatch):
    a = enrich.store_cover(cfg, _png(), "test")
    b = enrich.store_cover(cfg, _png(), "test")
    assert a["id"] == b["id"], "content-addressed: one file, one row"


# ---------------- display titles ----------------
def test_a_tiny_thumbnail_is_rejected_before_a_bigger_source(monkeypatch):
    """A 120px image is what YouTube Music hands out by default and it looks awful as
    the centrepiece of a now-playing screen."""
    assert enrich._download.__defaults__ == (0,)
    small = _png(size=(120, 120))
    monkeypatch.setattr(enrich.httpx, "get", lambda url, **kw: _FakeImg(small))
    assert enrich._download("x", min_px=enrich.MIN_COVER_PX) is None
    assert enrich._download("x") == small


def test_youtube_music_thumbnail_urls_are_upgraded():
    url = "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"
    assert "=w900-h900" in enrich._ytm_thumbnail({"thumbnails": [
        {"url": url, "width": 120, "height": 120}]})


class _FakeImg:
    def __init__(self, content):
        self.content = content
        self.status_code = 200
        self.headers = {"content-type": "image/png"}


@pytest.mark.parametrize("raw,expected", [
    ("Song Name (Official Video)", "Song Name"),
    ("Song Name (Official Music Video)", "Song Name"),
    ("Song Name [Lyric Video]", "Song Name"),
    ("Song Name - Official Video", "Song Name"),
    ("Song Name (HD)", "Song Name"),
    # These distinguish one recording from another and must survive
    ("Get Lucky (Radio Edit - feat. Pharrell Williams)",
     "Get Lucky (Radio Edit - feat. Pharrell Williams)"),
    ("Song (Live at Wembley)", "Song (Live at Wembley)"),
    ("Song - 2011 Remaster", "Song - 2011 Remaster"),
])
def test_display_title_strips_only_platform_noise(raw, expected):
    assert catalog.display_title(raw) == expected


def test_display_title_never_empties_a_title():
    assert catalog.display_title("(Official Video)") == "(Official Video)"
    assert catalog.display_title(None) == ""


def test_a_video_still_is_cropped_square(client, cfg):
    """16:9 stills are the last-resort source; letterboxed art looks broken in a grid."""
    wide = io.BytesIO()
    Image.new("RGB", (1280, 720), (10, 20, 30)).save(wide, format="PNG")
    row = enrich.store_cover(cfg, wide.getvalue(), "youtube")
    assert row["w"] == row["h"] == 720


def test_dominant_colour_prefers_the_hue_a_person_would_name(client, cfg):
    """Averaging album art gives mud; the point is the colour someone would call it."""
    from PIL import Image

    canvas = Image.new("RGB", (100, 100), (0, 0, 0))     # mostly black
    canvas.paste(Image.new("RGB", (30, 30), (220, 60, 40)), (10, 10))   # a red block
    colour = enrich.dominant_colour(canvas)
    r, g, b = int(colour[1:3], 16), int(colour[3:5], 16), int(colour[5:7], 16)
    assert r > g and r > b, f"expected the red, got {colour}"


def test_dominant_colour_survives_a_monochrome_cover(client, cfg):
    from PIL import Image

    colour = enrich.dominant_colour(Image.new("RGB", (50, 50), (255, 255, 255)))
    assert colour.startswith("#") and len(colour) == 7


@pytest.mark.parametrize("raw,artists,expected", [
    # The thing itself: a video names the artist because there is nowhere else to put
    # it, and here there is — the artist is on the row underneath.
    ("Rick Astley - Never Gonna Give You Up", ["Rick Astley"],
     "Never Gonna Give You Up"),
    ("Daft Punk — Get Lucky", ["Daft Punk"], "Get Lucky"),
    ("Tiesto | Adagio For Strings", ["Tiësto"], "Adagio For Strings"),
    ("Drake & Future - Life Is Good", ["Drake", "Future"], "Life Is Good"),
    ("AC/DC - Back In Black", ["AC/DC"], "Back In Black"),
    # A channel is not a different artist from the artist it belongs to, and the
    # longest name that matches has to win or half of it is left behind.
    ("Somebody - Topic - Song", ["Somebody - Topic"], "Song"),
    ("Artist - Artist - Song", ["Artist"], "Song"),
    # And the platform's own noise still goes, on top of it.
    ("Sia - Chandelier (Official Video)", ["Sia"], "Chandelier"),
    # Songs whose names simply contain a dash keep them: the front of these is not
    # the artist the track is filed under.
    ("Hurricane - Part Two", ["Bob Dylan"], "Hurricane - Part Two"),
    ("Song - 2011 Remaster", ["Someone"], "Song - 2011 Remaster"),
    ("Artist - Song - Live at Wembley", ["Artist"], "Song - Live at Wembley"),
    # A colon is not a separator here, because that is how classical works are named.
    ("Beethoven: Symphony No. 5", ["Beethoven"], "Beethoven: Symphony No. 5"),
    # Never leave a song with no name at all.
    ("Artist -", ["Artist"], "Artist -"),
    ("- Song", ["Artist"], "- Song"),
    # Nothing to compare against is nothing to strip.
    ("Rick Astley - Never Gonna Give You Up", [], 
     "Rick Astley - Never Gonna Give You Up"),
])
def test_display_title_drops_the_artist_it_is_already_filed_under(
        raw, artists, expected):
    assert catalog.display_title(raw, artists) == expected
