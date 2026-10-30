#!/usr/bin/env python3
"""Render the original 3.8-second startup scores. Requires numpy.

No samples, recordings, external music or runtime dependencies are used.
The lossless WAV masters are shipped directly as local resources.
"""
from pathlib import Path
import wave
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
RATE, DURATION = 44100, 3.8
N = round(RATE * DURATION)
rng = np.random.default_rng(271828)


def envelope(t, length, attack, release):
    return np.minimum(1, t / attack) ** 1.5 * np.minimum(1, np.maximum(0, (length - t) / release)) ** 1.5


def render(dark):
    mix = np.zeros((N, 2))

    def add(signal, start, pan=0):
        offset = round(start * RATE)
        count = min(len(signal), N - offset)
        if count > 0:
            mix[offset:offset + count, 0] += signal[:count] * np.sqrt((1 - pan) / 2)
            mix[offset:offset + count, 1] += signal[:count] * np.sqrt((1 + pan) / 2)

    def choir(note, start, length, amp, pan):
        t = np.arange(round(length * RATE)) / RATE
        f = 440 * 2 ** ((note - 69) / 12)
        signal = np.zeros_like(t)
        # A small detuned ensemble with vowel formants, slow breath and soft attacks.
        for cents in [-6, -2, 3, 7]:
            phase = 2 * np.pi * f * 2 ** (cents / 1200) * t + .012 * np.sin(2 * np.pi * 4.7 * t)
            for harmonic in range(1, min(35, int(9000 / f))):
                hz = f * harmonic
                formant = .18 + 2.3 * np.exp(-((hz - 730) / 240) ** 2) + .9 * np.exp(-((hz - 1180) / 260) ** 2)
                signal += np.sin(phase * harmonic + rng.uniform(0, 6.28)) * formant / harmonic ** 1.5 / 4
        signal *= envelope(t, length, .48, 1.15) * (.95 + .05 * np.sin(t * 1.7))
        add(signal * amp, start, pan)

    def bell(note, start, amp, pan):
        length = DURATION - start
        t = np.arange(round(length * RATE)) / RATE
        f = 440 * 2 ** ((note - 69) / 12)
        signal = sum(a * np.sin(2 * np.pi * f * ratio * t) * np.exp(-t / decay)
                     for ratio, a, decay in [(1, 1, 1.0), (2.01, .28, .65), (3.98, .08, .35)])
        signal *= (1 - np.exp(-t / .025))
        add(signal * amp, start, pan)

    # Open fifth: light expands at 0s, character wipes at .35/.55s, title at 1.2/1.25s.
    root = 38 if dark else 50  # D2 / D3, related tonal identity across both versions.
    for interval, amp, pan in [(0, .21, -.2), (7, .17, .2), (12, .12, -.55)]:
        choir(root + interval, 0, 3.65, amp, pan)
    reveal = .55 if dark else .35
    choir(root + 24, reveal, 3.55 - reveal, .14, .45)
    # Lydian lift and a major ninth bloom under the completed halo and lettering.
    for interval, start, pan in [(16, 1.0, -.65), (19, 1.25, .65), (26, 1.8, -.3)]:
        choir(root + interval, start, 3.5 - start, .12 if dark else .14, pan)
    bell(74 if dark else 86, reveal, .065, -.4)
    bell(81 if dark else 93, 1.25 if dark else 1.2, .075, .4)
    bell(86 if dark else 98, 2.05 if dark else 2.2, .085, 0)
    # The title bloom is the final accent; only its release remains after 2.2s.
    # Shorter cathedral reflections preserve the sacred space within the startup cue.
    dry = mix.copy()
    for index in range(26):
        delay = .065 + index * .052 + rng.uniform(0, .018)
        offset = round(delay * RATE)
        reflection = dry[:-offset, ::-1] if index % 2 else dry[:-offset]
        mix[offset:] += reflection * .16 * np.exp(-delay / .6)
    t = np.arange(N) / RATE
    mix *= np.minimum(1, t / .035)[:, None]
    # Resolve musically after the title, then ease the entire reverb tail to silence.
    release = np.clip((t - 2.3) / (DURATION - .02 - 2.3), 0, 1)
    mix *= (.5 + .5 * np.cos(np.pi * release))[:, None]
    # -7 dBFS peak leaves room for system mixing; playback uses a further gentle level.
    mix *= 10 ** (-7 / 20) / np.max(np.abs(mix))
    assert np.isfinite(mix).all() and np.max(np.abs(mix)) < .45
    name = 'StartupSacredDark' if dark else 'StartupSacredLight'
    master = ROOT / 'Sources/PetsPet' / (name + '.wav')
    with wave.open(str(master), 'wb') as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes((mix * 32767).astype('<i2').tobytes())
    print(f'{name}: {DURATION}s stereo, peak -7dBFS, {master.stat().st_size} bytes')


if __name__ == '__main__':
    for dark in [False, True]:
        render(dark)
