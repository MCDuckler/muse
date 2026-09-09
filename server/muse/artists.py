"""One credit, one artist.

Metadata arrives with several people in a single string — "Hugh Hardie, Kyan",
"Teddy Killerz feat. Sweetie Irie" — and stored that way the pair is a third artist
who has made exactly one record. Splitting them is what makes an artist page the
artist's.

The catch is that a separator is not always a separator. "Tyler, The Creator",
"Fujiya & Miyagi", "Nick Cave & The Bad Seeds" and "Earth, Wind & Fire" are one act
each, and cutting them up is a worse error than leaving a pair joined: it invents
artists who never existed. So the split is deliberately cautious.

  * A right-hand side that starts with "the", "his", "her" and the like is part of the
    band's name, never a second act — which covers "Tyler, The Creator" and every
    "X & The Y" there has ever been.
  * A separator inside brackets is not a separator.
  * "feat."/"ft." always separates: that is what it means.
  * A comma at the top level separates. Somebody typing a comma meant a list.
  * An ampersand with no comma anywhere is the genuinely ambiguous case — a duo's name
    as often as two names.

Before any of that, the whole credit is put to the metadata service: if it is itself a
known artist, exactly, it is left alone. That is what saves "Dave Dee, Dozy, Beaky,
Mick & Tich" and "Earth, Wind & Fire", which read exactly like lists because they are
lists — of the members of one band. When the service cannot be reached it says so
rather than "no", and then a comma is still treated as a list while an ampersand is
left joined: the cautious answer in each case.

For a credit with a comma the answer alone is not enough, because these services also
keep a page per collaboration: "Future, Metro Boomin, & Kendrick Lamar" exists as an
artist, with ten followers. Real bands do not look like that — Earth, Wind & Fire have
1.2 million, Dave Dee and company four thousand — so a comma credit has to clear a
following as well as exist. An ampersand credit does not: plenty of real duos have a
handful of listeners, and there the fallback is to leave them alone anyway.
"""
from __future__ import annotations

import logging
import re

log = logging.getLogger("muse.artists")

# Splitters that are always a list, whatever else is in the string.
_FEATURING = re.compile(r"\s+(?:feat\.?|ft\.?|featuring|w/|with)\s+", re.I)
# Splitters that mean a list when the credit already reads like one.
_AND = re.compile(r"\s+(?:&|\+|and|x|×|vs\.?|versus)\s+", re.I)

# A part that begins with one of these belongs to the name in front of it: an act is
# "Nick Cave & The Bad Seeds", not Nick Cave and a band called The Bad Seeds.
_CONTINUES = re.compile(
    r"^(the|his|her|their|los|las|les|die|der|das|el|la)\b", re.I)

# What is left of a name when the piece before it was cut off: "Loudon Wainwright, III".
_SUFFIX = re.compile(r"^(jr|sr|ii|iii|iv|vi{0,3}|phd|md)\.?$", re.I)
# A piece that still starts with the word that joined it: "…, and Fatoni".
_LEADING = re.compile(r"^(?:and|&|\+|feat\.?|ft\.?|featuring|with|x)\s+", re.I)
_ANY_SEPARATOR = re.compile(r"[,;&+]|\s(?:and|feat\.?|ft\.?|featuring|x|vs\.?)\s", re.I)


def _pieces(text: str, pattern: re.Pattern) -> tuple[list[str], list[str]]:
    """Split on a pattern outside brackets, keeping the separators that were used.

    "Project UNDARK(Dieter Moebius,Phew,Erika Kobayashi)" is one credit as written;
    cutting at its inner commas leaves an unclosed bracket in every piece. And the
    separators come back because a piece that turns out to belong to the name in front
    of it has to be rejoined with the comma or ampersand it was written with.
    """
    cuts, depth, start = [], 0, 0
    for m in pattern.finditer(text):
        depth += text.count("(", start, m.start()) + text.count("[", start, m.start())
        depth -= text.count(")", start, m.start()) + text.count("]", start, m.start())
        if depth <= 0:
            cuts.append((m.start(), m.end()))
        start = m.start()
    if not cuts:
        return [text], []

    parts, seps, at = [], [], 0
    for cut, resume in cuts:
        parts.append(text[at:cut])
        seps.append(text[cut:resume])
        at = resume
    parts.append(text[at:])
    return parts, seps


def _join_continuations(split: tuple[list[str], list[str]]) -> list[str]:
    """Put back any piece that was only ever the tail of the name before it."""
    parts, seps = split
    out: list[str] = []
    for i, part in enumerate(parts):
        part = part.strip()
        if not part:
            continue
        if out and (_CONTINUES.match(part) or _SUFFIX.match(part)):
            out[-1] = out[-1] + (seps[i - 1] if i - 1 < len(seps) else " ") + part
            continue
        out.append(part)
    return out


def _clean(parts: list[str]) -> list[str]:
    seen, out = set(), []
    for p in parts:
        p = _LEADING.sub("", p.strip()).strip(" ,;&+-").strip()
        if len(p) < 2:
            continue
        if p.lower() in seen:
            continue
        seen.add(p.lower())
        out.append(p)
    return out


# What a band with a comma in its name has to have, to be a band rather than a credit.
MIN_FANS_FOR_A_LIST_SHAPED_NAME = 2000


def split(name: str, verify=None) -> list[str]:
    """The artists in one credit string.

    [verify] is asked whether the whole credit is itself a known artist — optionally
    with a following of its own — and may answer True, False, or None for "could not
    find out". It is optional; without it a comma still means a list and an ampersand
    is left alone.
    """
    text = (name or "").strip().replace(";", ",")
    if not text:
        return []
    if not _ANY_SEPARATOR.search(text):
        return [text]

    # One act whose name reads like a list — "Dave Dee, Dozy, Beaky, Mick & Tich" — is
    # only knowable by asking. With a comma it also has to have a following, or every
    # collaboration's credit page would count as a band.
    floor = MIN_FANS_FOR_A_LIST_SHAPED_NAME if "," in text else 0
    known = verify(text, floor) if verify is not None else None
    if known is True:
        return [text]

    # A featured artist is a separate artist, always.
    chunks, _ = _pieces(text, _FEATURING)

    has_comma = any("," in c for c in chunks)
    out: list[str] = []
    for chunk in chunks:
        if has_comma:
            spread = []
            for piece in _join_continuations(_pieces(chunk, re.compile(r"\s*,\s*"))):
                spread += _join_continuations(_pieces(piece, _AND))
            out += spread
        elif _AND.search(chunk):
            pieces = _join_continuations(_pieces(chunk, _AND))
            # A duo's name as often as two names, and the answer above was about the
            # whole credit — ask about this chunk on its own. No answer means leave it
            # joined: a pair left together is a smaller error than two artists who
            # never existed.
            chunk_known = verify(chunk.strip(), 0) if verify is not None else None
            if len(pieces) > 1 and chunk_known is False:
                out += pieces
            else:
                out.append(chunk.strip())
        else:
            out.append(chunk)
    return _clean(out) or [text]


def split_all(names, verify=None) -> list[str]:
    """Every artist across a list of credits, in order, without repeats."""
    seen, out = set(), []
    for name in names or []:
        for one in split(name, verify=verify):
            if one.lower() in seen:
                continue
            seen.add(one.lower())
            out.append(one)
    return out


def deezer_verifier():
    """Asks Deezer whether a whole credit is one artist.

    Cached in the database, so a given name costs one request ever. Answers True, False,
    or None when the question could not be put.
    """
    from . import discography

    def verify(text: str, min_fans: int = 0) -> bool | None:
        try:
            found = discography.find_artist(text)
        except Exception as e:
            # Unreachable is not "no": saying no would split a duo's name into two
            # artists who do not exist, and no later run can put that back together.
            log.info("could not check %r: %s", text, e)
            return None
        if not found:
            return False
        # An exact name match is the claim we are testing. Deezer answers a search for
        # "Calvin Harris & Dua Lipa" with Calvin Harris, which is not the same thing.
        if discography.norm(found["name"]) != discography.norm(text):
            return False
        return (found.get("fans") or 0) >= min_fans

    return verify
