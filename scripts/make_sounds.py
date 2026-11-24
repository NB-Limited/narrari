"""Synthesises Narrari's start, stop and discard sounds from sines and seeded noise, nothing sampled.

Each set is one function of the kind. Classic, the system's own sounds, is not made here.

Run: uv run --with numpy --with scipy python scripts/make_sounds.py
(writes 48 kHz 16-bit mono WAVs to Sources/NarrariKit/Resources/Sounds)
"""

from pathlib import Path
import wave

import numpy as np
from scipy import signal

SR = 48_000
PEAK_DBFS = -12.0
OUT = Path(__file__).resolve().parent.parent / "Sources/NarrariKit/Resources/Sounds"
KINDS = ("start", "stop", "discard")


def samples(ms):
    return int(round(SR * ms / 1000))


def silence(ms):
    return np.zeros(samples(ms))


def partial(n, freq, tau, amp=1.0, glide=0.0, glide_tau=0.03, attack=0.001):
    t = np.arange(n) / SR
    f = freq * (1 + glide * (1 - np.exp(-t / glide_tau)))
    phase = 2 * np.pi * np.cumsum(f) / SR
    return amp * np.sin(phase) * np.exp(-t / tau) * (1 - np.exp(-t / attack))


def noise(n, seed):
    return np.random.default_rng(seed).standard_normal(n)


def burst(n, tau_ms, attack_ms=0.6):
    t = np.arange(n) / SR
    return np.exp(-t / (tau_ms / 1000)) * (1 - np.exp(-t / (attack_ms / 1000)))


def lowpass(x, hz, order=2):
    return signal.sosfilt(signal.butter(order, hz, "low", fs=SR, output="sos"), x)


def bandpass(x, lo, hi, order=2):
    return signal.sosfilt(signal.butter(order, [lo, hi], "band", fs=SR, output="sos"), x)


def place(total_ms, *events):
    """Mixes sounds at their offsets; each ends on a 10 ms fade so none is cut mid-decay."""
    out = silence(total_ms)
    tail = samples(10)
    for at_ms, sound in events:
        i = samples(at_ms)
        sound = sound[:len(out) - i].copy()
        sound[-tail:] *= 0.5 + 0.5 * np.cos(np.pi * (np.arange(tail) + 1) / tail)
        out[i:i + len(sound)] += sound
    return out


def finish(x, attack_ms=0.5, release_ms=20, peak=PEAK_DBFS):
    """High-pass, zero the DC, fade both ends to exact zero, normalise the peak."""
    x = signal.sosfilt(signal.butter(2, 30, "high", fs=SR, output="sos"), x)
    x = lowpass(x, 9_000, order=4)
    a, r = samples(attack_ms), samples(release_ms)
    x[:a] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(a) / a)
    x[-r:] *= 0.5 + 0.5 * np.cos(np.pi * (np.arange(r) + 1) / r)
    w = np.hanning(len(x))
    x -= w * (x.sum() / w.sum())
    return x * (10 ** (peak / 20) / np.abs(x).max())


# Wood: a small block, three modes, a short knock of filtered noise.

def wood_tick(freq, glide, ms=90, amp=1.0):
    n = samples(ms)
    body = sum(partial(n, freq * r, tau, a, glide=glide, attack=0.001)
               for r, a, tau in ((1, 1, 0.026), (2.57, 0.32, 0.011), (4.03, 0.1, 0.006)))
    knock = bandpass(noise(n, 1), 900, 3_500) * burst(n, 2.5) * 0.25
    return amp * (body + knock)


def wood(kind):
    if kind == "start":
        return finish(wood_tick(1_180, 0.03), release_ms=25)
    if kind == "stop":
        return finish(wood_tick(860, -0.03), release_ms=25)
    return finish(place(170, (0, wood_tick(720, -0.02)), (68, wood_tick(640, -0.02, amp=0.7))), release_ms=30)


# Low: a muted drum-like thud with a body mode that small speakers can carry.

def thud(freq, glide, ms=150, amp=1.0):
    n = samples(ms)
    x = (partial(n, freq, 0.05, 1, glide=glide, attack=0.003)
         + partial(n, freq * 2.1, 0.024, 0.3, glide=glide, attack=0.003)
         + partial(n, 430, 0.018, 0.25, attack=0.002))
    x += lowpass(noise(n, 2), 900) * burst(n, 4, 1.5) * 0.2
    return amp * x


def low(kind):
    if kind == "start":
        return finish(thud(150, 0.22), attack_ms=1, release_ms=35)
    if kind == "stop":
        return finish(thud(185, -0.24), attack_ms=1, release_ms=35)
    return finish(place(190, (0, thud(135, -0.05, 110)), (75, thud(125, -0.05, 110, amp=0.7))), attack_ms=1, release_ms=35)


# Glass: two struck glass notes; inharmonic partials kept below 6 kHz.

def glass_note(freq, ms, ring=0.16, amp=1.0):
    n = samples(ms)
    return amp * sum(partial(n, freq * r, ring * k, a, attack=0.003)
                     for r, a, k in ((1, 1, 1), (2.71, 0.14, 0.32), (5.18, 0.035, 0.13)))


def glass(kind):
    e5, b5 = 659.26, 987.77
    if kind == "start":
        return finish(place(220, (0, glass_note(e5, 220, amp=0.8)), (70, glass_note(b5, 150))), release_ms=60)
    if kind == "stop":
        return finish(place(220, (0, glass_note(b5, 220, amp=0.8)), (70, glass_note(e5, 150))), release_ms=60)
    g5, fs5 = 783.99, 739.99
    return finish(place(180, (0, glass_note(g5, 180, 0.06, 0.8)), (70, glass_note(fs5, 110, 0.06))), release_ms=40)


# Mallet: a marimba-like bar (partials near 1, 4 and 10) under a soft mallet.

def bar(freq, ms, damp=1.0, amp=1.0):
    n = samples(ms)
    return amp * sum(partial(n, freq * r, tau * damp, a, attack=0.003)
                     for r, a, tau in ((1, 1, 0.09), (3.93, 0.22, 0.03), (9.2, 0.04, 0.01)))


def mallet(kind):
    a4, e5, d4 = 440.0, 659.26, 293.66
    if kind == "start":
        return finish(place(200, (0, bar(a4, 200, amp=0.85)), (28, bar(e5, 172))), release_ms=50)
    if kind == "stop":
        return finish(place(200, (0, bar(e5, 200, amp=0.85)), (28, bar(a4, 172))), release_ms=50)
    return finish(place(170, (0, bar(d4, 170, 0.45)), (70, bar(d4, 100, 0.45, 0.7))), release_ms=30)


# The minimal sets: one gesture per sound, soft raised-cosine onsets, smooth exponential
# tails, a hint of room made here, quieter than the sets above.

LEVEL = {"start": -14.0, "stop": -14.0, "discard": -17.0}


def swell_env(n, attack_ms, tau_ms, delay_ms=0, taper=0.4):
    """Silence, a raised-cosine rise to 1, an exponential fall, tapered to zero over its last part."""
    d, a, k = samples(delay_ms), samples(attack_ms), int(taper * n)
    fall = np.exp(-np.arange(n - d - a) / SR / (tau_ms / 1000))
    rise = 0.5 - 0.5 * np.cos(np.pi * np.arange(a) / a)
    env = np.concatenate([np.zeros(d), rise, fall])
    env[-k:] *= 0.5 + 0.5 * np.cos(np.pi * (np.arange(k) + 1) / k)
    return env


def tone(freq, env):
    """A sine under an envelope; freq is a number or a per-sample curve."""
    f = np.broadcast_to(freq, env.shape)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env


def room(x, tail_ms=40, wet=0.04, seed=40):
    """A small synthesised room: four early reflections and a short darkened diffuse tail.

    The response has unit energy; its energy sits below 3 kHz, so wet 0.04 puts the room about 19 dB
    under a tone and keeps its notches within 2 dB. Much more and a pure tone audibly dips through them.
    """
    n = samples(tail_ms)
    t = np.arange(n) / SR
    diffuse = lowpass(noise(n, seed), 3_000) * np.exp(-t / (tail_ms / 1000 / 6.9))
    diffuse[:samples(6)] = 0
    ir = diffuse / np.sqrt((diffuse ** 2).sum())
    for ms, g in ((4.7, 0.5), (7.9, 0.35), (11.3, 0.25), (16.1, 0.18)):
        ir[samples(ms)] += g
    ir = lowpass(ir, 4_000)
    ir /= np.sqrt((ir ** 2).sum())
    dry = np.concatenate([x, np.zeros(n)])
    return dry + wet * signal.fftconvolve(dry, ir)[:len(dry)]


def swell(kind):
    f, attack, tau, ms, drift = {"start": (1046.5, 24, 30, 120, 1.012),
                                 "stop": (784.0, 24, 38, 160, 0.988),
                                 "discard": (659.3, 24, 22, 110, 0.992)}[kind]
    n = samples(ms)
    x = tone(f * drift ** np.linspace(0, 1, n), swell_env(n, attack, tau))
    return finish(room(x, 40), release_ms=45, peak=LEVEL[kind])


def rim(kind):
    f, tau, ms = {"start": (1318.5, 34, 115),
                  "stop": (1046.5, 50, 190),
                  "discard": (880.0, 24, 110)}[kind]
    n = samples(ms)
    env = swell_env(n, 8, tau)
    # A glass rim rings as two modes a few hertz apart, so the tone shimmers as it fades.
    x = 0.6 * tone(f, env) + 0.4 * tone(f * 1.0024, env)
    x += 0.04 * tone(f * 2.32, swell_env(n, 8, tau / 3))
    return finish(room(x, 45), release_ms=45, peak=LEVEL[kind])


def bloom(kind):
    if kind == "start":
        n = samples(130)
        x = tone(784.0, swell_env(n, 14, 60))
        x += 0.5 * tone(1568.0, swell_env(n, 40, 26, delay_ms=8))
        x += 0.3 * tone(2352.0, swell_env(n, 40, 20, delay_ms=14))
        return finish(room(x, 30), release_ms=40, peak=LEVEL[kind])
    f, tau, ms, bright = {"stop": (659.3, 55, 170, 0.5), "discard": (622.3, 28, 110, 0.25)}[kind]
    n = samples(ms)
    x = tone(f, swell_env(n, 12, tau))
    x += bright * tone(2 * f, swell_env(n, 12, 14)) + 0.6 * bright * tone(3 * f, swell_env(n, 12, 9))
    return finish(room(x, 40), release_ms=45, peak=LEVEL[kind])


def bell(kind):
    f, tau, ms = {"start": (784.0, 38, 120),
                  "stop": (587.3, 55, 185),
                  "discard": (523.3, 28, 115)}[kind]
    n = samples(ms)
    x = tone(f, swell_env(n, 9, tau)) + 0.3 * tone(f * 2.38, swell_env(n, 7, tau * 0.35))
    return finish(room(x, 40), release_ms=45, peak=LEVEL[kind])


def trace(kind):
    f, tau, ms = {"start": (1760.0, 13, 75),
                  "stop": (1480.0, 14, 80),
                  "discard": (1174.7, 12, 75)}[kind]
    n = samples(ms)
    x = tone(f, swell_env(n, 8, tau))
    return finish(room(x, 20), release_ms=25, peak=LEVEL[kind] - 8)


SETS = [trace, swell, rim, bloom, bell, wood, low, glass, mallet]


def write_wav(path, x):
    pcm = np.round(np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())


def main():
    for make in SETS:
        for kind in KINDS:
            write_wav(OUT / f"{make.__name__}-{kind}.wav", make(kind))


if __name__ == "__main__":
    main()
