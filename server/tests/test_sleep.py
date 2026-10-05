"""The sleep mix: the calm end of what somebody plays, laid out to wind down."""
from __future__ import annotations

import json

import pytest

from muse import auth, db, discover, recommend, sleep, traits


def _me() -> int:
    return db.one("select id from users where name='chris'")["id"]


@pytest.fixture(autouse=True)
def _no_cache(client):
    db.run("delete from remote_cache")
    yield
    db.run("delete from remote_cache")


STILL = {"lufs": -21.0, "pulse": 0.05, "punch": None, "bpm": None}
SOFT = {"lufs": -14.0, "pulse": 0.2, "punch": 4.8, "bpm": 80.0}       # an opener at most
DRIVING = {"lufs": -6.0, "pulse": 0.7, "punch": 9.0, "bpm": 128.0}


def _sound(n: int) -> list[float]:
    """A sound row: records numbered close together sound alike."""
    return [round(1.0 + 0.05 * n * (i % 5) + (0.3 if i == n % 36 else 0.0), 3) for i in range(36)]


def _song(client, hdr, vid: str, title: str, artist: str, heard: dict, *,
          minutes: float = 5, sound: int | None = None, mine: bool = True) -> int:
    t = client.post("/tracks/resolve", headers=hdr, json={"video_id": vid}).json()["id"]
    db.run("update tracks set state='ready', title=%s, artists=%s, duration_ms=%s where id=%s",
           (title, [artist], int(minutes * 60_000), t))
    db.run("""insert into track_traits(track_id, bpm, lufs, pulse, punch, sound)
              values(%s,%s,%s,%s,%s,%s)""",
           (t, heard["bpm"], heard["lufs"], heard["pulse"], heard["punch"],
            json.dumps(_sound(sound)) if sound is not None else None))
    if not mine:
        db.run("delete from library_items where track_id=%s", (t,))
    return t


def _listen(user: int, track: int, *, done=True, ms=200_000, times: int = 1):
    """Played two days ago at noon — on a clock set to UTC, so never at night."""
    db.run("update users set utc_offset_min = 0 where id = %s", (user,))
    for _ in range(times):
        db.run("""insert into listens(user_id, track_id, started_at, ms_played, completed)
                  values(%s,%s, date_trunc('day', now()) - interval '2 days'
                                + interval '12 hours', %s, %s)""", (user, track, ms, done))


@pytest.fixture()
def bedroom(client, hdr):
    """chris's own calm songs, two softer ones he loves, loud ones, a talk, one he
    skips — and the house's calm records nobody here has in their library."""
    me = _me()
    out = {"still": [], "soft": [], "driving": [], "house": []}
    for n in range(6):
        t = _song(client, hdr, f"STILL{n:04d}", f"Still {n}", f"Quiet Act {n}", STILL)
        _listen(me, t)
        out["still"].append(t)
    for n in range(2):
        t = _song(client, hdr, f"SOFT{n:05d}", f"Soft {n}", f"Soft Act {n}", SOFT, sound=n)
        _listen(me, t, times=3)
        out["soft"].append(t)
    for n in range(4):
        t = _song(client, hdr, f"LOUD{n:05d}", f"Loud {n}", f"Loud Act {n}", DRIVING, sound=20 + n)
        _listen(me, t, times=5)
        out["driving"].append(t)
    out["talk"] = _song(client, hdr, "TALK00001", "How to make a beat (tutorial)", "A Channel",
                        STILL)
    out["skipped"] = _song(client, hdr, "SKIP00001", "Skipped", "Skipped Act", STILL)
    _listen(me, out["skipped"], done=False, ms=4_000, times=3)
    for n in range(10):
        out["house"].append(_song(client, hdr, f"HOUSE{n:04d}", f"House {n}", f"House Act {n}",
                                  STILL, mine=False))
    return out


def _mix(me: int) -> dict:
    return discover.one_list(me, "sleep")


def test_a_record_is_heard_as_calm_or_driving():
    still = sleep.energy(STILL)
    soft = sleep.energy(SOFT)
    driving = sleep.energy(DRIVING)
    assert still < sleep.CALM_MAX < soft <= sleep.OPENING_MAX < driving
    assert sleep.energy({"lufs": None, "pulse": None, "punch": None}) is None
    # Beats laid down are a pulse, however unsure of its tempo the tracker was.
    drifting = {"lufs": -12.0, "pulse": 0.16, "punch": 4.9, "bpm": 140.0}
    assert sleep.energy(drifting) > sleep.CALM_MAX
    # Sung through is a little less restful than not sung at all.
    assert sleep.energy({**SOFT, "sung": 1.0}) > sleep.energy({**SOFT, "sung": 0.0})


def test_talks_sets_and_jingles_are_not_songs():
    assert sleep.is_song("Nanou2", 205_000)
    assert not sleep.is_song("The Hoover Sound Explained", 200_000)
    assert not sleep.is_song("crazy new pocket synth 2025 #flstudio", 200_000)
    assert not sleep.is_song("Inside Floating Points' studio", 600_000)
    assert not sleep.is_song("Ambient set", 3 * 3600_000)
    assert not sleep.is_song("A jingle", 20_000)
    assert not sleep.is_song("Some Talk", 300_000, ["Resident Advisor"])


def test_the_sleep_mix_is_the_calm_end_of_what_somebody_plays(client, hdr, bedroom):
    me = _me()
    fav = client.post(f"/favourites/{bedroom['still'][0]}", headers=hdr)
    assert fav.status_code in (200, 201, 204), fav.text
    discover.build_for(me, network=False)
    mix = _mix(me)
    assert mix and mix["kind"] == "sleep" and mix["name"] == "Sleep mix"
    ids = [t["id"] for t in mix["tracks"]]
    assert sleep.LEAST <= len(ids) <= sleep.MOST
    assert not set(ids) & set(bedroom["driving"])
    assert bedroom["talk"] not in ids and bedroom["skipped"] not in ids
    # His own first: all of his calm songs, and the house's only after.
    assert set(bedroom["still"]) <= set(ids)
    assert 55 <= mix["minutes"] <= sleep.MINUTES_MOST
    assert str(mix["minutes"]) in mix["blurb"]
    # Winding down: the softer songs open it, the stillest close it.
    rows = sleep._rows(me)
    energies = [rows[t]["energy"] for t in ids]
    assert energies[0] == max(energies) and energies[-1] == min(energies)
    assert set(ids[:2]) <= set(bedroom["soft"])
    assert mix["why"][str(bedroom["still"][0])] == "one of your favourites"
    assert any("from the house" in mix["why"].get(str(t), "") for t in bedroom["house"])
    assert len(mix["energy"]) == len(ids)


def test_a_softer_song_opens_only_when_it_is_loved(client, hdr, bedroom):
    me = _me()
    db.run("delete from listens where track_id = any(%s)", (bedroom["soft"],))
    sleep.build(me, network=False, save=discover._save)
    ids = [t["id"] for t in _mix(me)["tracks"]]
    assert not set(ids) & set(bedroom["soft"])


def test_what_lists_are_called_moves_a_record(client, hdr, bedroom):
    me = _me()
    other = auth.ensure_user("joe")
    borderline = _song(client, hdr, "BORDER001", "Borderline", "Border Act",
                       {"lufs": -8.0, "pulse": 0.1, "punch": None, "bpm": None}, mine=False)
    clubbed = bedroom["house"][0]
    before = sleep._rows(me)
    assert before[borderline]["energy"] > sleep.CALM_MAX
    for owner, name, t in ((other, "Villa Schlafmix", borderline),
                           (other, "Techno · Peak Time", clubbed)):
        p = db.one("insert into playlists(owner_id, name) values(%s,%s) returning id",
                   (owner, name))["id"]
        db.run("insert into playlist_items(playlist_id, pos, track_id) values(%s,0,%s)", (p, t))
    after = sleep._rows(me)
    assert after[borderline]["energy"] == pytest.approx(before[borderline]["energy"] + sleep.CALM_LIST)
    assert after[clubbed]["energy"] == pytest.approx(before[clubbed]["energy"] + sleep.LOUD_LIST)
    # The person's own list counts for more than somebody else's.
    mine = db.one("insert into playlists(owner_id, name) values(%s,'zum Einschlafen') returning id",
                  (me,))["id"]
    db.run("insert into playlist_items(playlist_id, pos, track_id) values(%s,0,%s)",
           (mine, borderline))
    assert sleep._rows(me)[borderline]["energy"] == pytest.approx(
        before[borderline]["energy"] + sleep.OWN_CALM_LIST)


def test_the_genres_an_act_is_filed_under_move_it_too(client, hdr, bedroom):
    from muse import brainz
    me = _me()
    t = bedroom["house"][1]
    before = sleep._rows(me)[t]["energy"]
    brainz._store("mb:artist:house act 1", {"mbid": "m", "name": "House Act 1",
                                             "genres": ["Hardcore Punk"]})
    assert sleep._rows(me)[t]["energy"] == pytest.approx(before + sleep.LOUD_GENRE)


def test_new_songs_come_in_beside_the_calmest_and_never_first(client, hdr, bedroom, monkeypatch):
    """YouTube Music answers every seed with a dozen songs: some by the seed's own act,
    some saying they are still, and the rest anything — which stay out."""
    from muse import ytm

    def radio(vid, limit=25):
        seed = db.one("""select t.artists from track_sources s join tracks t on t.id = s.track_id
                          where s.provider = 'ytmusic' and s.provider_id = %s""", (vid,))
        act = (seed["artists"] if seed else ["Nobody"])[0]
        return ([{"video_id": f"SAME{vid[-4:]}{n}", "title": f"Radio Track {n}", "artists": [act],
                  "album": None, "duration_ms": 200_000, "raw": {}} for n in range(2)]
                + [{"video_id": f"RAIN{vid[-4:]}", "title": "Radio Track in the Rain",
                    "artists": ["Elsewhere Act"], "album": None, "duration_ms": 200_000, "raw": {}}]
                + [{"video_id": f"PUMP{vid[-4:]}{n}", "title": f"Party Banger {n}",
                    "artists": [f"Party Act {n}"], "album": None, "duration_ms": 200_000,
                    "raw": {}} for n in range(6)])

    monkeypatch.setattr(ytm, "watch_playlist", radio)
    me = _me()
    sleep.build(me, network=True, save=discover._save)
    mix = _mix(me)
    ids = [t["id"] for t in mix["tracks"]]
    new = [t["id"] for t in mix["tracks"] if t["title"].startswith("Radio Track")]
    assert 1 <= len(new) <= sleep.NEW_MOST
    assert ids[0] not in new and ids[-1] not in new
    assert all(mix["why"][str(t)].startswith("YouTube Music plays it after") for t in new)
    assert not [t for t in mix["tracks"] if t["title"].startswith("Party Banger")]
    # Fetched, for tonight.
    assert db.one("select count(*) n from jobs where kind='ingest' and (payload->>'track_id')::int = any(%s)",
                  (new,))["n"] == len(new)


def test_last_nights_mix_turns_over(client, hdr, bedroom):
    me = _me()
    first = sleep.build(me, network=False, save=discover._save)
    second = sleep.build(me, network=False, save=discover._save)
    assert set(first) != set(second)
    assert set(bedroom["still"]) <= set(second)      # his own stay: the house turns over


def test_somebody_with_nothing_played_gets_the_houses_calmest(client, hdr, bedroom):
    nobody = auth.ensure_user("luna")
    got = sleep.build(nobody, network=False, save=discover._save)
    assert len(got) >= sleep.LEAST
    assert not set(got) & set(bedroom["driving"])


def test_too_little_calm_makes_no_list(client, hdr):
    me = _me()
    t = _song(client, hdr, "ONLY00001", "Only", "Only Act", STILL)
    discover._save(me, "sleep", "Sleep mix", "old", [t], 35)
    assert sleep.build(me, network=False, save=discover._save) == []
    assert discover.one_list(me, "sleep") is None


def test_the_page_keeps_the_clock_and_says_how_long_a_list_is(client, hdr, bedroom):
    me = _me()
    r = client.get("/discover", headers=hdr, params={"tz": 120})
    assert r.status_code == 200, r.text
    assert db.one("select utc_offset_min from users where id=%s", (me,))["utc_offset_min"] == 120
    assert client.get("/discover", headers=hdr, params={"tz": 99999}).status_code == 200
    assert db.one("select utc_offset_min from users where id=%s", (me,))["utc_offset_min"] == 120
    discover.build_for(me, network=False)
    lists = client.get("/discover/lists", headers=hdr).json()["items"]
    sleepy = next(i for i in lists if i["slug"] == "sleep")
    assert sleepy["minutes"] >= 55 and len(sleepy["energy"]) == sleepy["count"]
    assert all("minutes" in i for i in lists)


def test_the_traits_row_keeps_how_a_record_moves(client, hdr):
    t = client.post("/tracks/resolve", headers=hdr, json={"video_id": "TRAIT0001"}).json()
    track = {"id": t["id"], "loudness_lufs": -9.0}
    traits.remember(track, {"bpm": 120.0, "confidence": 0.61, "contrast": 7.25})
    row = db.one("select pulse, punch, bpm from track_traits where track_id=%s", (t["id"],))
    assert row["pulse"] == pytest.approx(0.61) and row["punch"] == pytest.approx(7.25)
    # An analysis served without them (a structure on its own) keeps what was known.
    traits.remember(track, {"bpm": 121.0})
    row = db.one("select pulse, punch, bpm from track_traits where track_id=%s", (t["id"],))
    assert row["pulse"] == pytest.approx(0.61) and row["bpm"] == pytest.approx(121.0)
