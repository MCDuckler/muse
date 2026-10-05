"""A Bandcamp label is not the act that shares its name.

CloudCore is an "artist" account on Bandcamp whose records are by Zecho, optmst, Xpress
and a hundred more; Cloudcore on Deezer is somebody else with three singles. Bringing
the follow over took the first for the second. What is checked: such a page is a label
wherever it is read, its acts are read off its records when it has no artists page, a
Deezer act of the same name is only taken for a page when they share a record, follows
made the old way are put right, and an artist's page never borrows a label's.
"""
from __future__ import annotations

import html
import json
import urllib.error

import pytest

from muse import brainz, db, discography, follows, linked, sources


def _me() -> int:
    return db.one("select id from users where name='chris'")["id"]


def _page(name: str, records: list[tuple[str, str | None]], is_label: bool = False) -> str:
    items = [{"page_url": f"/album/r{n}", "title": t, "artist": a, "art_id": n, "type": "album"}
             for n, (t, a) in enumerate(records)]
    band = {"id": 7, "name": name, "is_label": is_label}
    return (f'<div id="pagedata" data-band="{html.escape(json.dumps(band))}"></div>'
            f'<ol id="music-grid" class="music-grid" '
            f'data-client-items="{html.escape(json.dumps(items))}"></ol>')


CLOUDCORE = "https://cloudcore.bandcamp.com"
PAGES = {
    # An "artist" account run as a label: every record somebody else's.
    CLOUDCORE: _page("CloudCore", [("Atom", "Zecho"), ("Fall So Hard", "optmst"),
                                   ("60 Seconds", "Xpress"), ("N-r-G", "Xpress"),
                                   ("Lou", "Actual")]),
    # An act, whose name is also somebody else's on Deezer.
    "https://moonfield.bandcamp.com": _page("Moonfield", [("Tides", None), ("Glass", None)]),
    # An act Deezer knows under the same name, with a record in common.
    "https://xpress.bandcamp.com": _page("Xpress", [("60 Seconds", None), ("Pulse", None)]),
}

# Deezer, as far as these tests ask it: who is called what, and what they put out.
DEEZER_ARTISTS = {
    "cloudcore": {"id": 221120545, "name": "Cloudcore", "nb_fan": 10},
    "moonfield": {"id": 500, "name": "Moonfield", "nb_fan": 3},
    "xpress": {"id": 600, "name": "Xpress", "nb_fan": 40},
    "optmst": {"id": 700, "name": "optmst", "nb_fan": 2},
}
DEEZER_ALBUMS = {
    "221120545": ["Hazerunner", "Dislocated Memories", "Absence Of Nothing"],
    "500": ["Some Other Record"],
    "600": ["60 Seconds", "Elsewhere"],
    "700": ["Nothing Alike"],
}


@pytest.fixture(autouse=True)
def _world(client, monkeypatch):
    for t in ("remote_cache", "artist_releases", "feed_seen", "jobs", "artist_follows"):
        db.run(f"delete from {t}")
    monkeypatch.setattr(brainz, "artist", lambda name, **kw: None)
    monkeypatch.setattr(linked, "bandcamp_record", lambda url: {
        "release_date": "2020-01-01", "tags": [], "reviews": [], "about": None})

    def fetch_page(url):
        root, _, rest = url.partition(".com")
        root += ".com"
        if rest.startswith("/artists"):
            # Such a page has no artists page of its own.
            raise urllib.error.HTTPError(url, 404, "Not Found", None, None)
        if root not in PAGES:
            raise urllib.error.HTTPError(url, 404, "Not Found", None, None)
        return PAGES[root], root + "/music"
    monkeypatch.setattr(sources, "fetch_page", fetch_page)
    monkeypatch.setattr(sources, "_get_page", lambda url: "<html></html>")

    def deezer(path, params=None, *, kind="search"):
        if path == "/search/artist":
            q = (params or {}).get("q", "").strip('"').lower()
            hit = DEEZER_ARTISTS.get(q)
            return {"data": [hit] if hit else []}
        if path.startswith("/artist/") and path.endswith("/albums"):
            aid = path.split("/")[2]
            return {"data": [{"id": n, "title": t} for n, t in
                             enumerate(DEEZER_ALBUMS.get(aid, []))]}
        return {"data": []}
    monkeypatch.setattr(discography, "_get", deezer)


def _followed() -> set[tuple[str, str, bool]]:
    return {(r["provider"], r["remote_id"], r["is_label"]) for r in db.all_(
        "select provider, remote_id, is_label from artist_follows where user_id=%s", (_me(),))}


def test_a_page_whose_records_are_other_peoples_is_a_label_wherever_it_is_read():
    band = linked.bandcamp_band(CLOUDCORE)
    assert band["is_label"] is True, "whatever the page calls itself"
    assert {"title": "Atom", "artist": "Zecho"} in band["records"]
    page = linked.bandcamp_band_page(CLOUDCORE)
    assert page["is_label"] is True
    assert [a["name"] for a in page["roster"]][:1] == ["Xpress"], "most records first"
    assert {a["name"] for a in page["roster"]} == {"Xpress", "Zecho", "optmst", "Actual"}
    assert all(a["url"] == "" for a in page["roster"]), "no pages of their own to point at"


def test_bringing_a_label_over_never_follows_its_namesake():
    got = follows.import_entries(_me(), "bandcamp",
                                 [{"name": "CloudCore", "url": CLOUDCORE}])
    followed = _followed()
    assert ("bandcamp", CLOUDCORE, True) in followed, "the label, as a label"
    assert ("deezer", "221120545", False) not in followed, "not the Cloudcore on Deezer"
    # Its acts, each only where Deezer's act has the record the label put out.
    assert ("deezer", "600", False) in followed, "Xpress: 60 Seconds is on both"
    assert ("deezer", "700", False) not in followed, "optmst on Deezer has nothing in common"
    assert got["labels"] == 1


def test_an_act_is_its_deezer_namesake_only_with_a_record_in_common():
    follows.import_entries(_me(), "bandcamp", [
        {"name": "Moonfield", "url": "https://moonfield.bandcamp.com"},
        {"name": "Xpress", "url": "https://xpress.bandcamp.com"},
    ])
    followed = _followed()
    assert ("bandcamp", "https://moonfield.bandcamp.com", False) in followed, \
        "the page itself, never wrong"
    assert ("deezer", "500", False) not in followed
    assert ("deezer", "600", False) in followed, "the same act: the same record"


def test_follows_brought_over_the_old_way_are_put_right():
    me = _me()
    follows.follow(me, {"remote_id": "221120545", "name": "Cloudcore"}, "deezer")
    follows.follow(me, {"remote_id": "600", "name": "Xpress"}, "deezer")
    entries = [{"name": "CloudCore", "url": CLOUDCORE},
               {"name": "Xpress", "url": "https://xpress.bandcamp.com"}]

    dry = follows.recheck(me, entries)
    assert [(c["deezer_id"], c["bandcamp"]) for c in dry] == [("221120545", CLOUDCORE)]
    assert ("deezer", "221120545", False) in _followed(), "a dry run changes nothing"

    follows.recheck(me, entries, apply=True)
    followed = _followed()
    assert ("deezer", "221120545", False) not in followed
    assert ("bandcamp", CLOUDCORE, True) in followed
    assert ("deezer", "600", False) in followed, "the right one is left alone"
    assert follows.recheck(me, entries) == [], "and once is enough"


def test_an_artists_page_does_not_borrow_a_label_of_the_same_name(client, hdr):
    follows.follow(_me(), {"remote_id": CLOUDCORE, "name": "CloudCore", "is_label": True},
                   "bandcamp")
    r = client.get("/library/artists/detail", params={"artist": "Cloudcore"}, headers=hdr)
    assert r.status_code == 200, r.text
    assert r.json()["artist"]["bandcamp_url"] is None, "the label is not the act"
    # An act's own page, followed under the same name, still is.
    follows.follow(_me(), {"remote_id": "https://moonfield.bandcamp.com", "name": "Moonfield"},
                   "bandcamp")
    r = client.get("/library/artists/detail", params={"artist": "Moonfield"}, headers=hdr)
    assert r.json()["artist"]["bandcamp_url"] == "https://moonfield.bandcamp.com"


# ------------------------------------------------------------------ what it must not do
def test_an_act_credited_with_company_is_not_a_label(monkeypatch):
    PAGES["https://sunra.bandcamp.com"] = _page("Sun Ra", [
        ("Lanquidity", "Sun Ra & His Arkestra"), ("Space Is The Place", "Sun Ra and his Arkestra"),
        ("Strange Strings", "Sun Ra & His Astro Infinity Arkestra"), ("Nuclear War", None),
        ("Disco 3000", "Sun Ra Quartet")])
    assert linked.bandcamp_band("https://sunra.bandcamp.com")["is_label"] is False
    assert linked.credited_to("Bou", "Boundary") is False, "whole words"
    assert linked.credited_to("James Holden", "James Holden & The Animal Spirits") is True


def test_a_record_is_the_same_record_whatever_the_shop_adds_to_its_name():
    DEEZER_ARTISTS["omni trio"] = {"id": 800, "name": "Omni Trio", "nb_fan": 900}
    DEEZER_ALBUMS["800"] = ["Renegade Snares", "The Deepest Cut, Vol. 1"]
    artist = discography.find_artist("Omni Trio")
    assert follows.same_act(artist, ["Renegade Snares EP"])
    assert follows.same_act(artist, ["The Deepest Cut, Vol. 1 (2024 Remaster)"])
    assert follows.same_act(artist, ["Renegade Snares (feat. Somebody)"])
    assert not follows.same_act(artist, ["Something Else Entirely"])


def test_putting_follows_right_never_leaves_an_act_unfollowed():
    me = _me()
    # Followed on Deezer, on the label's roster, with nothing on the label to compare.
    follows.follow(me, {"remote_id": "700", "name": "optmst"}, "deezer")
    follows.follow(me, {"remote_id": "500", "name": "Moonfield"}, "deezer")
    PAGES["https://quiet.bandcamp.com"] = _page("Moonfield", [])
    changed = follows.recheck(me, [{"name": "CloudCore", "url": CLOUDCORE},
                                   {"name": "Moonfield", "url": "https://quiet.bandcamp.com"}],
                              apply=True)
    assert changed == [], "nothing to tell them apart by is not proof they differ"
    assert {("deezer", "700", False), ("deezer", "500", False)} <= _followed()


# ------------------------------------------------------------------ labels in Discover and search
def test_a_followed_labels_acts_count_for_the_taste_and_say_why():
    from muse import recommend
    me = _me()
    follows.follow(me, {"remote_id": CLOUDCORE, "name": "CloudCore", "is_label": True}, "bandcamp")
    follows.follow(me, {"remote_id": "600", "name": "Xpress"}, "deezer")
    tas = recommend.taste(me)
    assert tas.label_acts.get("zecho") == "CloudCore"
    assert tas.artist.get("zecho") == recommend.LABEL_ACT, "a little, not like a follow"
    assert "xpress" not in tas.label_acts, "followed outright: that counts for more already"
    assert "cloudcore" not in tas.label_acts, "the label's own name is not an act on it"


def test_following_or_unfollowing_makes_their_discover_lists_again(client, hdr):
    db.run("delete from jobs where kind='discover_build'")
    r = client.post("/follows", headers=hdr, json={
        "provider": "bandcamp", "remote_id": CLOUDCORE, "name": "CloudCore", "is_label": True})
    assert r.status_code in (200, 201), r.text
    assert db.one("""select count(*) n from jobs where kind='discover_build'
                      and payload->>'user_id' = %s""", (str(_me()),))["n"] == 1
    row = db.one("select is_label from artist_follows where remote_id=%s", (CLOUDCORE,))
    assert row["is_label"] is True


def test_labels_are_found_by_search(cfg, monkeypatch):
    from muse import search
    me = _me()
    follows.follow(me, {"remote_id": CLOUDCORE, "name": "CloudCore", "is_label": True,
                        "image": None}, "bandcamp")
    # Read by the house before, and found to be a label whatever it calls itself.
    db.run("""insert into remote_cache(key, body, fetched_at)
              values('bc:band2:https://cloudmachine.bandcamp.com',
                     '{"name": "Cloud Machine", "is_label": true}', now())""")
    monkeypatch.setattr(sources, "bandcamp_bands", lambda q, limit=12: [
        {"name": "CloudCore", "url": CLOUDCORE, "is_label": False, "location": "London",
         "image": None},
        {"name": "Cloud Records", "url": "https://cloudrecords.bandcamp.com", "is_label": True,
         "location": "Berlin", "image": "https://f4.bcbits.com/img/1_23.jpg"},
        {"name": "Cloud Machine", "url": "https://cloudmachine.bandcamp.com", "is_label": False,
         "location": None, "image": None},
        {"name": "Cloudchord", "url": "https://cloudchord.bandcamp.com", "is_label": False,
         "location": "Austin", "image": None},
    ])
    got = search.everything(cfg, me, "cloud", kind="label")["items"]
    urls = [h["id"] for h in got]
    assert urls[0] == CLOUDCORE and got[0]["subtitle"] == "A label you follow"
    assert "https://cloudrecords.bandcamp.com" in urls, "Bandcamp says so"
    assert "https://cloudmachine.bandcamp.com" in urls, "the house has read it as one"
    assert "https://cloudchord.bandcamp.com" not in urls, "an act is not a label"
    assert urls.count(CLOUDCORE) == 1 and all(h["kind"] == "label" for h in got)
    # In an "everything" search they come along too, a few.
    mixed = search.everything(cfg, me, "cloudcore")["items"]
    assert any(h["kind"] == "label" and h["id"] == CLOUDCORE for h in mixed)
