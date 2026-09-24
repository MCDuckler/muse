"""The voice and the words of a record, for the automix: a hook is the line sung most,
the title's first; lyrics timed to another version of the song are not believed."""
from __future__ import annotations

from muse import vocals


def test_the_hook_is_the_line_sung_most_with_the_title_first():
    lrc = "\n".join([
        "[00:10.00] I was walking down the street",
        "[00:20.00] Tell me something good tonight",
        "[00:30.00] Tell me something good tonight",
        "[00:40.00] oh oh oh oh",
        "[00:41.00] oh oh oh oh",
        "[00:42.00] oh oh oh oh",
        "[00:50.00] Tell me something good tonight",
    ])
    hook = vocals.hook_of(vocals.parse_lrc(lrc), "Tell Me Something (Radio Edit)")
    assert hook["text"] == "Tell me something good tonight"
    assert hook["at"] == [20000, 30000, 50000]


def test_lyrics_are_moved_onto_the_voice_or_not_believed():
    # A bar every 2 s; the voice from bar 10 to 29 (20 s to 60 s).
    downbeats = [i * 2000 for i in range(60)]
    bars = [200 if 10 <= i < 30 else 0 for i in range(60)]
    # Lines timed 8 s early — an intro cut from the edit.
    lines = [(12000 + i * 3000, f"line {i}") for i in range(12)]
    off = vocals.align(lines, bars, downbeats)
    assert off is not None and abs(off - 8000) <= 2000
    # Lines spread over the whole record, voice or not: no offset fits.
    everywhere = [(i * 9500, f"line {i}") for i in range(12)]
    assert vocals.align(everywhere, bars, downbeats) is None


def test_what_a_separator_leaves_in_an_instrumental_is_no_voice(tmp_path):
    import subprocess

    def tone(name, filt):
        f = tmp_path / name
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                        f"sine=frequency=330:duration=8,{filt}", str(f)], check=True)
        return f

    record = tone("record.wav", "volume=0.5")
    # A voice a thirtieth of the record's loudness: a separator's leftovers.
    leftovers = tone("leftovers.wav", "volume=0.016")
    # The voice half the record, in the second half only.
    sung = tone("sung.wav", "volume='if(gte(t,4),0.25,0)':eval=frame")
    downbeats = [i * 2000 for i in range(4)]
    assert vocals.bar_levels(leftovers, record, downbeats) == [0, 0, 0, 0]
    got = vocals.bar_levels(sung, record, downbeats)
    assert got[:2] == [0, 0] and min(got[2:]) >= 118, got
