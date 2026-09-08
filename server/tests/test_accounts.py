"""Adding people to a server. There is still no public signup — what changed is that
adding someone no longer means editing a file and restarting."""
from __future__ import annotations

from muse import auth, db


def test_the_config_account_still_works(client, hdr):
    """muse.toml seeds the first account; it must keep working after the move to the
    database, or a server upgrade locks its owner out."""
    assert client.get("/me", headers=hdr).json()["user"] == "chris"
    row = db.one("select pw_hash from users where name='chris'")
    assert row["pw_hash"], "the config password should have been seeded into the db"


def test_an_account_can_be_created_and_used(client, hdr):
    made = client.post("/accounts", headers=hdr,
                       json={"name": "sam", "password": "correct-horse"}).json()
    assert made["name"] == "sam"

    r = client.post("/auth/login", data={"user": "sam", "password": "correct-horse"})
    assert r.status_code == 200
    token = r.json()["token"]
    assert client.get("/me", headers={"Authorization": f"Bearer $token".replace("$token", token)}).json()["user"] == "sam"


def test_new_accounts_start_empty(client, hdr):
    """Someone else's queues and playlists are not yours."""
    client.post("/queues", headers=hdr, json={"name": "Mine"})
    client.post("/accounts", headers=hdr,
                json={"name": "sam", "password": "correct-horse"})
    token = client.post("/auth/login",
                        data={"user": "sam", "password": "correct-horse"}).json()["token"]
    theirs = {"Authorization": f"Bearer {token}"}
    assert client.get("/queues", headers=theirs).json() == []
    assert client.get("/playlists", headers=theirs).json() == []


def test_weak_or_duplicate_accounts_are_refused(client, hdr):
    assert client.post("/accounts", headers=hdr,
                       json={"name": "sam", "password": "short"}).status_code == 400
    assert client.post("/accounts", headers=hdr,
                       json={"name": "  ", "password": "correct-horse"}).status_code == 400
    client.post("/accounts", headers=hdr,
                json={"name": "sam", "password": "correct-horse"})
    # names differing only by case are the same person as far as signing in goes
    r = client.post("/accounts", headers=hdr,
                    json={"name": "SAM", "password": "correct-horse"})
    assert r.status_code == 400 and "already" in r.json()["detail"]


def test_creating_an_account_needs_an_existing_one(client):
    assert client.post("/accounts",
                       json={"name": "nobody", "password": "correct-horse"}).status_code == 401


# ---------------- invites ----------------
def test_an_invite_lets_someone_set_their_own_password(client, hdr):
    invite = client.post("/accounts/invites", headers=hdr,
                         json={"note": "for sam"}).json()
    assert invite["code"] and invite["valid_hours"] == 48

    r = client.post("/auth/redeem", data={
        "code": invite["code"], "user": "sam", "password": "their-own-secret",
        "device": "phone",
    })
    assert r.status_code == 200
    assert r.json()["user"] == "sam"
    # signed in immediately, without anyone else knowing the password
    assert client.get("/me",
                      headers={"Authorization": f"Bearer {r.json()['token']}"}
                      ).json()["user"] == "sam"


def test_an_invite_works_once(client, hdr):
    code = client.post("/accounts/invites", headers=hdr, json={}).json()["code"]
    client.post("/auth/redeem",
                data={"code": code, "user": "sam", "password": "their-own-secret"})
    again = client.post("/auth/redeem",
                        data={"code": code, "user": "kim", "password": "another-secret"})
    assert again.status_code == 400


def test_an_expired_or_unknown_invite_is_refused(client, hdr):
    assert client.post("/auth/redeem", data={
        "code": "not-a-real-code", "user": "sam", "password": "their-own-secret",
    }).status_code == 400

    code = client.post("/accounts/invites", headers=hdr, json={}).json()["code"]
    db.run("update invites set expires_at = now() - interval '1 hour' where code=%s",
           (code,))
    assert client.post("/auth/redeem", data={
        "code": code, "user": "sam", "password": "their-own-secret",
    }).status_code == 400


def test_a_revoked_invite_cannot_be_redeemed(client, hdr):
    code = client.post("/accounts/invites", headers=hdr, json={}).json()["code"]
    client.delete(f"/accounts/invites/{code}", headers=hdr)
    assert client.post("/auth/redeem", data={
        "code": code, "user": "sam", "password": "their-own-secret",
    }).status_code == 400


# ---------------- managing accounts ----------------
def test_accounts_are_listed_with_who_you_are(client, hdr):
    client.post("/accounts", headers=hdr,
                json={"name": "sam", "password": "correct-horse"})
    listed = client.get("/accounts", headers=hdr).json()
    names = {a["name"] for a in listed["items"]}
    assert {"chris", "sam"} <= names
    assert listed["you"] in {a["id"] for a in listed["items"]}


def test_you_cannot_delete_yourself_or_the_last_account(client, hdr):
    me = client.get("/accounts", headers=hdr).json()["you"]
    r = client.delete(f"/accounts/{me}", headers=hdr)
    assert r.status_code == 400 and "signed in" in r.json()["detail"]


def test_another_account_can_be_removed(client, hdr):
    made = client.post("/accounts", headers=hdr,
                       json={"name": "sam", "password": "correct-horse"}).json()
    assert client.delete(f"/accounts/{made['id']}", headers=hdr).status_code == 200
    assert client.post("/auth/login",
                       data={"user": "sam", "password": "correct-horse"}).status_code == 401


def test_changing_your_own_password(client, hdr):
    client.post("/accounts", headers=hdr,
                json={"name": "sam", "password": "correct-horse"})
    token = client.post("/auth/login",
                        data={"user": "sam", "password": "correct-horse"}).json()["token"]
    theirs = {"Authorization": f"Bearer {token}"}

    assert client.post("/auth/password", headers=theirs,
                       json={"password": "short"}).status_code == 400
    assert client.post("/auth/password", headers=theirs,
                       json={"password": "a-longer-secret"}).status_code == 200
    assert client.post("/auth/login",
                       data={"user": "sam", "password": "correct-horse"}).status_code == 401
    assert client.post("/auth/login",
                       data={"user": "sam", "password": "a-longer-secret"}).status_code == 200
    assert auth is not None
