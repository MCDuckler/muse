"""A record's name: what the caller knew of it is kept when YouTube will not say,
a video that is not a song is still named by its own title and channel, and a record
once named by its id is put right by the meta job."""
from muse import catalog, db, enrich, ytm


def test_the_hit_names_the_record_when_youtube_will_not(client, hdr, monkeypatch):
    def unavailable(vid):
        raise ytm.Unavailable("no")
    monkeypatch.setattr(ytm, "song", unavailable)
    r = client.post("/tracks/resolve", headers=hdr, json={
        "video_id": "KNOWNVID0001", "title": "Glass Harbour", "artists": ["Ilse Varga"],
        "album": "Low Orbit"})
    assert r.status_code == 202
    body = r.json()
    assert body["title"] == "Glass Harbour"
    assert body["artists"] == ["Ilse Varga"]
    assert body["album"] == "Low Orbit"


def test_by_id_alone_it_is_named_by_its_id_and_the_meta_job_puts_it_right(client, hdr, monkeypatch):
    def unavailable(vid):
        raise ytm.Unavailable("no")
    monkeypatch.setattr(ytm, "song", unavailable)
    body = client.post("/tracks/resolve", headers=hdr, json={"video_id": "LONELYVID001"}).json()
    assert body["title"] == "LONELYVID001" and body["artists"] == []

    # Later, YouTube answers: the meta job's first move names the record.
    monkeypatch.setattr(ytm, "song", lambda vid: {
        "video_id": vid, "title": "Kessel Run", "artists": ["Tomás Nkemelu"],
        "album": "Rain On The Radio", "duration_ms": 200000, "raw": {}})
    t = enrich._names(catalog.track_row(body["id"]))
    assert t["title"] == "Kessel Run"
    assert t["artists"] == ["Tomás Nkemelu"]
    assert t["album"] == "Rain On The Radio"
    # And a record with a name of its own is left alone.
    monkeypatch.setattr(ytm, "song", lambda vid: {"video_id": vid, "title": "WRONG", "artists": ["X"]})
    again = enrich._names(catalog.track_row(body["id"]))
    assert again["title"] == "Kessel Run" and again["artists"] == ["Tomás Nkemelu"]


def test_a_video_that_is_not_a_song_is_named_by_its_own_title(monkeypatch):
    monkeypatch.setattr(ytm, "_ask", lambda what, *a, **k: [])
    monkeypatch.setattr(ytm, "video", lambda vid: {
        "video_id": vid, "title": "DJ Clock ft Beatenberg - Pluto (Official Video)",
        "artists": ["AM-PM Productions S.A"], "album": None, "duration_ms": 251000, "raw": {}})
    found = ytm.song("VIDEOVID0001")
    assert found["title"].startswith("DJ Clock")
    assert found["artists"] == ["AM-PM Productions S.A"]
    monkeypatch.setattr(ytm, "video", lambda vid: None)
    assert ytm.song("VIDEOVID0001") is None
