"""muse admin CLI — there is no signup, users are added here and land in muse.toml."""
from __future__ import annotations

import getpass
import secrets
import sys

from . import auth


def adduser(name: str) -> None:
    pw = getpass.getpass(f"password for {name}: ")
    if pw != getpass.getpass("again: "):
        sys.exit("passwords differ")
    print("\nAdd this to muse.toml:\n")
    print("[[users]]")
    print(f'name = "{name}"')
    print(f'password_hash = "{auth.hash_password(pw)}"')


def secret() -> None:
    print(secrets.token_urlsafe(32))


def main() -> None:
    match sys.argv[1:]:
        case ["adduser", name]:
            adduser(name)
        case ["secret"]:
            secret()
        case _:
            sys.exit("usage: python -m muse.cli [adduser <name> | secret]")


if __name__ == "__main__":
    main()
