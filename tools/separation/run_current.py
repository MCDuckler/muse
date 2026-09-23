"""Score what we ship today, so anything that replaces it has a number to beat."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'server'))

from muse import stems                                    # noqa: E402
from evaluate import run                                  # noqa: E402


def separate(mix):
    drums, _ = stems.hits_and_notes(mix.mean(axis=1))
    return {'instrumental': stems.without_voice(mix), 'drums': drums}


run('what we ship today (mid/side + HPSS)', separate)
