"""Score what we ship today, so anything that replaces it has a number to beat."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'server'))

from muse import stems                                    # noqa: E402
from evaluate import run                                  # noqa: E402


def separate(mix):
    drums, music = stems.hits_and_notes(mix.mean(axis=1))
    return {'instrumental': stems.without_voice(mix), 'drums': drums, 'music': music}


run('the arithmetic (mid/side + HPSS)', separate, subset=sys.argv[1] if len(sys.argv) > 1 else None)
