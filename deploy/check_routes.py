#!/usr/bin/env python3
"""Every API route must actually reach the API.

Caddy matches the API by an explicit path list, and twice now a new endpoint was added
to the server but not to that list — so it quietly returned the web app's HTML and the
client tried to parse a page as JSON. This walks the server's own OpenAPI schema and
checks each path through the real proxy.

    python3 deploy/check_routes.py https://your.server
"""
from __future__ import annotations

import sys
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "https://89-58-49-140.nip.io"


def fetch(url: str) -> tuple[int, str, str]:
    req = urllib.request.Request(url, headers={"Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.headers.get("content-type", ""), r.read(200).decode("utf8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("content-type", ""), e.read(200).decode("utf8", "replace")


schema_status, _, schema_body = fetch(f"{BASE}/openapi.json")
if schema_status != 200:
    sys.exit(f"could not read the schema: HTTP {schema_status}")

import json

paths = json.loads(schema_body if len(schema_body) > 200 else "{}").get("paths")
if not paths:
    with urllib.request.urlopen(f"{BASE}/openapi.json", timeout=20) as r:
        paths = json.load(r)["paths"]

bad = []
for path in sorted(paths):
    # Unauthenticated GET is enough: we care whether the API answered, not what it said.
    probe = path.replace("{track_id}", "1").replace("{queue_id}", "1") \
                .replace("{playlist_id}", "1").replace("{job_id}", "1") \
                .replace("{kind}", "spotify").replace("{remote_id}", "x") \
                .replace("{pos}", "0")
    status, ctype, body = fetch(f"{BASE}{probe}")
    served_html = "text/html" in ctype or body.lstrip().startswith("<!DOCTYPE")
    if served_html:
        bad.append(f"{path} -> HTTP {status} {ctype} (served the web app, not the API)")

if bad:
    print("Routes not reaching the API:")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print(f"all {len(paths)} API routes reach the API")
