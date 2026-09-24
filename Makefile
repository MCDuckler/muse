SERVER := server/.venv/bin
PGROOT := $(HOME)/.local/pgroot
PGDATA := $(HOME)/.local/share/muse-pg

.PHONY: dev db-start db-stop api test fmt clean

db-start:   ## local rootless Postgres 17 (no docker, no sudo)
	$(PGROOT)/bin/pg_ctl -D $(PGDATA) -o "-p 5433 -k /tmp -c listen_addresses=127.0.0.1" \
		-l $(PGDATA)/server.log start || true

db-stop:
	$(PGROOT)/bin/pg_ctl -D $(PGDATA) stop || true

api: db-start
	cd server && ./.venv/bin/python -m uvicorn muse.main:app --host 127.0.0.1 --port 8770 --reload

test: db-start
	cd server && ./.venv/bin/python -m pytest tests -q

clean:
	rm -rf server/.venv
