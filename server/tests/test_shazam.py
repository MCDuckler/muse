"""Songs Shazam recognised, brought over here.

The parsing is the part worth testing hardest: it is somebody's own listening history,
the file has changed shape between versions of Shazam, and a person exporting their
library is not going to enjoy being told their file is the wrong shape.
"""
from __future__ import annotations

import pytest

from muse import shazam

EXPORT = '''"Shazam Library"
"Index","TagTime","Title","Artist","URL","TrackKey"
"1","2026-03-04 21:15:02 UTC","Tiger Is Coming","LEENALCHI","https://www.shazam.com/track/1/x","552211"
"2","2026-03-05 01:02:03 UTC","Chez Moi","CC:DISCO!","",""
'''


def test_the_preamble_is_not_a_song():
    tags = shazam.read(EXPORT)
    assert len(tags) == 2, "the title line and the header are not tags"
    assert tags[0]["title"] == "Tiger Is Coming"
    assert tags[0]["artist"] == "LEENALCHI"
    assert tags[0]["tag_key"] == "552211"
    assert tags[0]["tagged_at"].year == 2026
    assert tags[0]["tagged_at"].hour == 21


def test_a_tag_with_no_id_still_has_a_name_of_its_own():
    """Two tags of the same song seconds apart are one tag as far as anybody cares;
    the same song on two different nights is two."""
    tags = shazam.read(EXPORT)
    assert tags[1]["tag_key"] != tags[0]["tag_key"]
    assert "chez moi" in tags[1]["tag_key"]
    assert "2026-03-05" in tags[1]["tag_key"]


def test_the_columns_can_be_anywhere_and_called_anything():
    """Shazam has moved these about between versions, and other tools export their own
    arrangement of the same thing."""
    tags = shazam.read(
        'Artist,Song,Date\n'
        'Kraftwerk,Das Model,2026-01-02 03:04:05\n')
    assert len(tags) == 1
    assert tags[0]["title"] == "Das Model"
    assert tags[0]["artist"] == "Kraftwerk"
    assert tags[0]["tagged_at"].day == 2


def test_a_file_with_no_dates_is_still_a_library():
    tags = shazam.read('Title,Artist\nNeon Velocity,Annie Hall\n')
    assert len(tags) == 1
    assert tags[0]["tagged_at"] is None


def test_something_that_is_not_a_library_reads_as_nothing():
    assert shazam.read("hello,world\n1,2\n") == []
    assert shazam.read("") == []


def test_importing_the_same_export_twice_adds_nothing(client, hdr):
    first = client.post("/shazams/import", headers=hdr, json={"csv": EXPORT}).json()
    assert first["read"] == 2 and first["added"] == 2

    again = client.post("/shazams/import", headers=hdr, json={"csv": EXPORT}).json()
    assert again["added"] == 0 and again["already_here"] == 2

    listed = client.get("/shazams", headers=hdr).json()
    assert listed["total"] == 2


def test_the_newest_tag_is_at_the_top(client, hdr):
    client.post("/shazams/import", headers=hdr, json={"csv": EXPORT})
    items = client.get("/shazams", headers=hdr).json()["items"]
    assert [i["title"] for i in items] == ["Chez Moi", "Tiger Is Coming"], \
        "newest first, which is the order anybody remembers them in"


def test_a_tag_is_kept_even_when_nothing_here_answers_to_it(client, hdr):
    """A song recognised in a bar at two in the morning is worth having written down
    whether or not the library has it."""
    client.post("/shazams/import", headers=hdr, json={"csv": EXPORT})
    listed = client.get("/shazams", headers=hdr).json()
    assert listed["total"] == 2
    assert listed["matched"] == 0, "nothing looked up yet"
    assert listed["waiting"] == 2

    unmatched = client.get("/shazams", headers=hdr,
                           params={"unmatched": True}).json()
    assert len(unmatched["items"]) == 2


def test_matching_puts_a_track_against_a_tag(client, hdr):
    """The same machinery every other import uses: a tag is a title and an artist, so
    there is no reason for it to be its own kind of guess."""
    from muse import db, shazam as reader

    client.post("/shazams/import", headers=hdr, json={"csv": EXPORT})
    me = client.get("/me", headers=hdr).json()["user_id"]

    out = reader.match_some(me)
    assert out["looked_at"] == 2
    assert out["left"] == 0

    rows = db.all_("select track_id, looked_at from shazams where user_id=%s", (me,))
    assert all(r["looked_at"] is not None for r in rows), "all of them were looked at"


def test_looking_again_is_offered_because_the_answer_changes(client, hdr):
    """A song nothing matched last month is a song the catalogue may well have now."""
    from muse import db

    client.post("/shazams/import", headers=hdr, json={"csv": EXPORT})
    me = client.get("/me", headers=hdr).json()["user_id"]
    db.run("update shazams set looked_at=now() where user_id=%s", (me,))

    client.post("/shazams/match", headers=hdr)
    waiting = client.get("/shazams", headers=hdr).json()["waiting"]
    assert waiting == 2, "put back in the queue to be looked at again"


def test_a_file_that_is_not_a_library_says_so(client, hdr):
    r = client.post("/shazams/import", headers=hdr, json={"csv": "nothing,useful\n"})
    assert r.status_code == 400
    assert "shazam.com" in r.json()["detail"]
