"""Splitting a credit into artists, and knowing when not to.

The failure this guards against is not "the pair stayed joined" — it is inventing
artists who never existed. Cutting "Fujiya & Miyagi" in half produces two artist pages
with one record between them and no way to tell, later, that it was ever one name.
"""
from __future__ import annotations

import pytest

from muse import artists


def nobody(_text, _min_fans=0):
    """The metadata service says it has never heard of this credit."""
    return False


def unreachable(_text, _min_fans=0):
    """The metadata service could not be asked."""
    return None


def acts(known: dict[str, int]):
    """A verifier backed by a fixed set of real acts and their followings."""
    def verify(text: str, min_fans: int = 0):
        fans = known.get(text.lower())
        return None if fans is None else fans >= min_fans
    return verify


@pytest.mark.parametrize("credit, want", [
    ("Hugh Hardie, Kyan", ["Hugh Hardie", "Kyan"]),
    ("Retado, Ikkimel, & Slim Salabim", ["Retado", "Ikkimel", "Slim Salabim"]),
    ("Emery, Dreazz and Luciano", ["Emery", "Dreazz", "Luciano"]),
    ("Maeckes, Danger Dan, and Fatoni", ["Maeckes", "Danger Dan", "Fatoni"]),
    ("Oliver Koletzki feat. Thorsten Nagelschmidt",
     ["Oliver Koletzki", "Thorsten Nagelschmidt"]),
    ("Egotronic ft. Plemo", ["Egotronic", "Plemo"]),
    ("Solo Artist", ["Solo Artist"]),
])
def test_a_list_is_a_list(credit, want):
    assert artists.split(credit, verify=nobody) == want


@pytest.mark.parametrize("credit", [
    # The band's name continues after the separator.
    "Tyler, The Creator",
    "Nick Cave & The Bad Seeds",
    "Bob Marley & The Wailers",
    "Roy Bianco & Die Abbrunzati Boys",
    # A suffix is not a second person.
    "Loudon Wainwright, III",
    # Inside brackets nothing is a separator.
    "Project UNDARK(Dieter Moebius,Phew,Erika Kobayashi)",
])
def test_names_that_only_look_like_lists(credit):
    assert artists.split(credit, verify=nobody) == [credit]


def test_a_duo_is_one_act_when_the_service_knows_it():
    known = acts({"fujiya & miyagi": 16841, "alf champion & mdhntr": 1})
    assert artists.split("Fujiya & Miyagi", verify=known) == ["Fujiya & Miyagi"]
    # A real duo with one listener is still a duo: no following is required of a name
    # that does not read like a list.
    assert artists.split("ALF CHAMPION & MDHNTR", verify=known) == \
        ["ALF CHAMPION & MDHNTR"]


def test_two_people_are_two_people():
    assert artists.split("Calvin Harris & Dua Lipa", verify=nobody) == \
        ["Calvin Harris", "Dua Lipa"]


def test_a_band_whose_name_reads_like_a_list_needs_a_following():
    """These services keep a page per collaboration, so existing is not enough.

    "Future, Metro Boomin, & Kendrick Lamar" is an artist on Deezer with ten followers.
    Earth, Wind & Fire have 1.2 million.
    """
    known = acts({
        "earth, wind & fire": 1263949,
        "future, metro boomin, & kendrick lamar": 10,
    })
    assert artists.split("Earth, Wind & Fire", verify=known) == ["Earth, Wind & Fire"]
    assert artists.split("Future, Metro Boomin, & Kendrick Lamar", verify=known) == \
        ["Future", "Metro Boomin", "Kendrick Lamar"]


def test_an_unanswerable_question_errs_the_safe_way_each_time():
    """A comma still means a list; an ampersand is left joined rather than guessed."""
    assert artists.split("Hugh Hardie, Kyan", verify=unreachable) == \
        ["Hugh Hardie", "Kyan"]
    assert artists.split("Fujiya & Miyagi", verify=unreachable) == ["Fujiya & Miyagi"]
    # And with nobody to ask at all, the same.
    assert artists.split("Fujiya & Miyagi") == ["Fujiya & Miyagi"]


def test_split_all_keeps_order_and_drops_repeats():
    assert artists.split_all(
        ["Hugh Hardie, Kyan", "Kyan", "Makoto"], verify=nobody) == \
        ["Hugh Hardie", "Kyan", "Makoto"]


def test_nothing_becomes_nothing():
    assert artists.split("") == []
    assert artists.split_all([]) == []
