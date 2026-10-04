"""Followed Bandcamp pages: their records read whole, a refused read tried again, a
looked-at record left looked at, and the feed narrowed to one service."""
from __future__ import annotations

import html
import json
import pathlib

import pytest

from muse import brainz, db, discography, discover, follows, jobs, linked, sources


def _me() -> int:
    return db.one("select id from users where name='chris'")["id"]


@pytest.fixture(autouse=True)
def _offline(client, monkeypatch):
    for t in ("remote_cache", "artist_releases", "feed_seen", "jobs"):
        db.run(f"delete from {t}")
    db.run("delete from artist_follows")
    monkeypatch.setattr(brainz, "artist", lambda name, **kw: None)
    monkeypatch.setattr(discography, "_get", lambda *a, **k: {"data": []})
    monkeypatch.setattr(linked, "bandcamp_record", lambda url: {
        "release_date": "2020-01-01", "tags": [], "reviews": [], "about": None})


def _grid_page(band: dict, lis: list[str], client_items: list[dict] | None) -> str:
    """A music page the way Bandcamp draws one: the first records as list items, the
    rest as JSON on the grid for its script."""
    items = (f' data-client-items="{html.escape(json.dumps(client_items))}"'
             if client_items is not None else "")
    return (f'<div id="pagedata" data-band="{html.escape(json.dumps(band))}"></div>'
            f'<ol id="music-grid" class="music-grid"{items}>' + "".join(lis) + "</ol>")


def _li(kind: str, n: int, href: str, title: str, artist: str | None = None,
        lazy: bool = False) -> str:
    img = (f'<img class="lazy" src="/img/0.gif" data-original="https://f4.bcbits.com/img/a{n}_2.jpg">'
           if lazy else f'<img src="https://f4.bcbits.com/img/a{n}_2.jpg" alt="" />')
    over = f'<br><span class="artist-override">\n  {artist}\n</span>' if artist else ""
    return (f'<li data-item-id="{kind}-{n}" data-band-id="1" class="music-grid-item">'
            f'<a href="{href}"><div class="art">{img}</div>'
            f'<p class="title">\n  {html.escape(title)}\n  {over}</p></a></li>')


def test_a_music_page_is_read_whole_newest_first_with_links_made_whole(monkeypatch):
    page = _grid_page(
        {"id": 1, "name": "Club Designs", "is_label": False},
        [_li("album", 11, "/album/cdmusic014", "CDMUSIC014", "Various Artists"),
         _li("album", 12, "https://destrata.bandcamp.com/album/cdmusic013?label=1&amp;tab=music",
             "CDMUSIC013", "Destrata"),
         _li("track", 13, "/track/a-single", "A Single", lazy=True)],
        [{"page_url": "/album/r4", "title": "R4", "artist": "Black Sites", "art_id": 14,
          "type": "album"},
         {"page_url": "https://kerrie.bandcamp.com/album/echoes?label=1&tab=music",
          "title": "Echoes", "artist": "Kerrie", "art_id": 15, "type": "album"},
         # The same record drawn twice is one record.
         {"page_url": "/album/cdmusic014", "title": "CDMUSIC014", "art_id": 11}])
    monkeypatch.setattr(sources, "fetch_page",
                        lambda url: (page, "https://clubdesigns.bandcamp.com/music"))

    got = linked.bandcamp_music("https://clubdesigns.bandcamp.com", newest=40)
    ids = [r["remote_id"] for r in got["records"]]
    assert ids == [
        "https://clubdesigns.bandcamp.com/album/cdmusic014",
        "https://destrata.bandcamp.com/album/cdmusic013",
        "https://clubdesigns.bandcamp.com/track/a-single",
        "https://clubdesigns.bandcamp.com/album/r4",
        "https://kerrie.bandcamp.com/album/echoes",
    ], "the drawn records first, then the rest — every link whole"
    first, _, single = got["records"][:3]
    assert first["title"] == "CDMUSIC014" and first["artist"] == "Various Artists"
    assert single["artist"] is None and single["record_type"] == "track"
    assert single["cover"] == "https://f4.bcbits.com/img/a13_2.jpg", "a lazily drawn picture too"
    assert got["is_label"] is True, "four acts on one page's records is a label"
    assert len(linked.bandcamp_music("https://clubdesigns.bandcamp.com", newest=2)["records"]) == 2


def test_a_page_with_one_record_is_a_list_of_one(monkeypatch):
    tralbum = {"artist": "Somebody", "art_id": 99, "current": {"title": "Only Record"}}
    page = f'<script data-tralbum="{html.escape(json.dumps(tralbum))}"></script>'
    monkeypatch.setattr(sources, "fetch_page",
                        lambda url: (page, "https://somebody.bandcamp.com/album/only-record"))
    got = linked.bandcamp_music("https://somebody.bandcamp.com")
    assert [(r["remote_id"], r["title"]) for r in got["records"]] == [
        ("https://somebody.bandcamp.com/album/only-record", "Only Record")]
    assert got["is_label"] is False


def test_a_refused_read_is_tried_again_and_its_back_catalogue_kept_quiet(monkeypatch):
    me = _me()

    def refused(url, newest=40):
        raise linked.RateLimited("429")
    monkeypatch.setattr(linked, "bandcamp_music", refused)
    follows.follow(me, {"remote_id": "https://label.bandcamp.com", "name": "Label",
                        "is_label": True}, "bandcamp")
    job = db.one("select payload from jobs where kind='follow_refresh'")
    assert job, "queued to try again rather than waiting for the next poll"
    payload = job["payload"] if isinstance(job["payload"], dict) else json.loads(job["payload"])
    assert payload["tries"] == 1 and payload["new_follower"] == me

    monkeypatch.setattr(linked, "bandcamp_music", lambda url, newest=40: {
        "name": "Label", "is_label": True, "records": [
            {"remote_id": "https://act.bandcamp.com/album/old", "title": "Old", "artist": "Act",
             "cover": None, "record_type": "album"}]})
    assert follows.refresh_later(payload) == 1
    feed = follows.feed(me)
    assert [(i["title"], i["unseen"]) for i in feed] == [("Old", False)], \
        "an old record is not news just because the first read came late"

    # Three tries and no more.
    monkeypatch.setattr(linked, "bandcamp_music", refused)
    db.run("delete from jobs")
    follows.refresh_later({**payload, "tries": 3})
    assert db.one("select 1 from jobs where kind='follow_refresh'") is None


def test_a_page_that_acts_as_a_label_is_remembered_as_one(monkeypatch):
    me = _me()
    monkeypatch.setattr(linked, "bandcamp_music", lambda url, newest=40: {
        "name": "Analog Africa", "is_label": True, "records": []})
    follows.follow(me, {"remote_id": "https://analogafrica.bandcamp.com",
                        "name": "Analog Africa"}, "bandcamp")
    assert follows.list_for(me)[0]["is_label"] is True


def test_a_bandcamp_record_once_looked_at_stays_looked_at(client, hdr):
    me = _me()
    db.run("""insert into artist_follows(user_id, provider, remote_id, name)
              values(%s,'bandcamp','https://label.bandcamp.com','Label')""", (me,))
    db.run("""insert into artist_releases(provider, artist_id, album_id, title, artist,
                                          release_date)
              values('bandcamp','https://label.bandcamp.com',
                     'https://act.bandcamp.com/album/new','New','Act', current_date)""")
    assert follows.feed(me)[0]["unseen"] is True
    r = client.post("/discover/feed/seen", headers=hdr, json={"items": [
        {"provider": "bandcamp", "album_id": "https://act.bandcamp.com/album/new"}]})
    assert r.json()["seen"] == 1
    assert follows.feed(me)[0]["unseen"] is False

    db.run("delete from feed_seen")
    r = client.post("/feed/seen", headers=hdr, json={"items": [
        {"provider": "bandcamp", "album_id": "https://act.bandcamp.com/album/new"}]})
    assert r.json()["seen"] == 1 and follows.feed(me)[0]["unseen"] is False


def test_relative_record_ids_are_made_whole():
    me = _me()
    db.run("""insert into artist_releases(provider, artist_id, album_id, title, artist)
              values('bandcamp','https://tresorberlin.bandcamp.com','/album/r4','R4','Black Sites'),
                    ('bandcamp','https://other.bandcamp.com/','/album/x','X','Y')""")
    db.run("insert into feed_seen(user_id, provider, album_id) values(%s,'bandcamp','/album/r4')",
           (me,))
    schema = pathlib.Path(db.SCHEMA).read_text()
    # As db.init runs it: one execute, no parameters.
    with db.pool().connection() as c:
        c.execute(schema[schema.index("-- A Bandcamp record's id is its page."):])
    ids = {r["album_id"] for r in db.all_(
        "select album_id from artist_releases where provider='bandcamp'")}
    assert ids == {"https://tresorberlin.bandcamp.com/album/r4", "https://other.bandcamp.com/album/x"}
    assert db.one("select album_id from feed_seen where user_id=%s", (me,))["album_id"] == \
        "https://tresorberlin.bandcamp.com/album/r4"


def test_the_feed_can_be_narrowed_to_one_service(client, hdr):
    me = _me()
    ids = []
    for n, source in enumerate(["bandcamp", "youtube", "bandcamp", "soundcloud"]):
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": f"SVC{n}"}).json()
        db.run("update tracks set state='ready', source=%s where id=%s", (source, t["id"]))
        ids.append(t["id"])
    db.run("delete from listens where user_id=%s", (me,))
    discover._save(me, "weekly", "This week's finds", "", ids, 0, {})

    every = client.get("/discover/cards", headers=hdr).json()
    assert [c["track"]["id"] for c in every["items"]] == ids
    assert every["services"] == {"bandcamp": 2, "soundcloud": 1, "youtube": 1}
    assert [c["service"] for c in every["items"]] == ["bandcamp", "youtube", "bandcamp", "soundcloud"]

    only = client.get("/discover/cards", headers=hdr, params={"service": "bandcamp"}).json()
    assert [c["track"]["id"] for c in only["items"]] == [ids[0], ids[2]]
    assert only["total"] == 2
    assert only["services"] == every["services"], "the counts are of everything, to choose from"

    nonsense = client.get("/discover/cards", headers=hdr, params={"service": "myspace"}).json()
    assert nonsense["total"] == 4, "a service nobody has is no filter"
