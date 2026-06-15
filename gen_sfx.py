#!/usr/bin/env python3
"""Generate the game's sound effects + a looping music bed as 16-bit mono WAVs.

Pure standard library — no numpy required. Run from the project root:

    python3 gen_sfx.py

Writes shoot/explosion/hit/gameover/wave/powerup/dash/shield/bomb/bossdie.wav
and music.wav (a seamless loop). The DSP is deliberately simple (sweeps,
decaying noise, short arpeggios) to match the neon/vector aesthetic without
shipping any external assets.
"""

import math
import os
import random
import struct
import wave

SR = 22050  # sample rate (Hz)
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sfx")
TAU = 2.0 * math.pi


def write_wav(name, samples, headroom=0.92):
    """Normalize float samples in [-1, 1] and write a 16-bit mono WAV."""
    peak = max((abs(s) for s in samples), default=0.0)
    gain = (headroom / peak) if peak > 1e-6 else 1.0
    frames = bytearray()
    for s in samples:
        v = int(max(-1.0, min(1.0, s * gain)) * 32767)
        frames += struct.pack("<h", v)
    path = os.path.join(OUT_DIR, name)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(bytes(frames))
    print(f"  wrote {path}  ({len(samples)} samples, {len(samples) / SR:.2f}s)")


def fade_edges(buf, ms=4.0):
    """Short fade in/out to avoid clicks at the boundaries."""
    n = min(int(SR * ms / 1000.0), len(buf) // 2)
    for i in range(n):
        k = i / n
        buf[i] *= k
        buf[-1 - i] *= k
    return buf


# ── one-shot SFX ──────────────────────────────────────────────────────────
def shoot():
    dur = 0.14
    out, phase = [], 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        freq = 200.0 + 1100.0 * math.exp(-t * 20.0)
        phase += TAU * freq / SR
        sq = 1.0 if math.sin(phase) >= 0.0 else -1.0
        out.append((0.55 * sq + 0.45 * math.sin(phase * 1.004)) * math.exp(-t * 24.0))
    return fade_edges(out)


def explosion():
    dur = 0.45
    out, lp = [], 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        lp += (random.uniform(-1.0, 1.0) - lp) * 0.35
        rumble = math.sin(TAU * 70.0 * t) * math.exp(-t * 7.0)
        out.append((0.75 * lp + 0.55 * rumble) * math.exp(-t * 7.5))
    return fade_edges(out)


def hit():
    dur = 0.22
    out, phase = [], 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        phase += TAU * (120.0 + 320.0 * math.exp(-t * 26.0)) / SR
        out.append((0.7 * math.sin(phase) + random.uniform(-1.0, 1.0) * 0.4) * math.exp(-t * 16.0))
    return fade_edges(out)


def gameover():
    out = []
    for f in [440.0, 349.23, 261.63]:        # A4 -> F4 -> C4
        phase = 0.0
        for i in range(int(SR * 0.28)):
            t = i / SR
            phase += TAU * f * (1.0 + 0.01 * math.sin(TAU * 6.0 * t)) / SR
            sq = 1.0 if math.sin(phase) >= 0.0 else -1.0
            out.append((0.5 * sq + 0.5 * math.sin(phase)) * math.exp(-t * 5.0) * 0.9)
    return fade_edges(out)


def wave_up():
    out = []
    for f in [523.25, 659.25, 783.99]:       # C5 -> E5 -> G5
        phase = 0.0
        for i in range(int(SR * 0.09)):
            t = i / SR
            phase += TAU * f / SR
            sq = 1.0 if math.sin(phase) >= 0 else -1.0
            out.append((0.5 * math.sin(phase) + 0.5 * sq) * math.exp(-t * 9.0) * 0.8)
    return fade_edges(out)


def powerup():
    """Bright rising sparkle — pickup."""
    out = []
    for f in [523.25, 659.25, 783.99, 1046.5]:   # C5 E5 G5 C6
        phase = 0.0
        for i in range(int(SR * 0.06)):
            t = i / SR
            phase += TAU * f / SR
            sh = 0.15 * math.sin(TAU * f * 2.0 * t)
            out.append((math.sin(phase) + sh) * math.exp(-t * 7.0) * 0.7)
    return fade_edges(out)


def dash():
    """Quick band-swept whoosh."""
    dur = 0.18
    out, lp = [], 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        n = random.uniform(-1.0, 1.0)
        # rising then falling cutoff via time-varying one-pole
        cut = 0.05 + 0.5 * math.sin(math.pi * t / dur)
        lp += (n - lp) * cut
        env = math.sin(math.pi * t / dur)
        out.append(lp * env * 0.9)
    return fade_edges(out)


def shield():
    """Metallic block ping + thud."""
    dur = 0.3
    out, phase, phase2 = [], 0.0, 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        phase += TAU * 880.0 / SR
        phase2 += TAU * 1318.5 / SR
        ping = (math.sin(phase) + 0.5 * math.sin(phase2)) * math.exp(-t * 9.0)
        thud = math.sin(TAU * 90.0 * t) * math.exp(-t * 16.0)
        out.append(0.7 * ping + 0.5 * thud)
    return fade_edges(out)


def bomb():
    """Deep sub boom that clears the screen."""
    dur = 0.6
    out, lp = [], 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        sub = math.sin(TAU * (90.0 * math.exp(-t * 3.0) + 35.0) * t)
        lp += (random.uniform(-1.0, 1.0) - lp) * 0.2
        out.append((0.8 * sub + 0.4 * lp) * math.exp(-t * 4.5))
    return fade_edges(out)


def bossdie():
    """Layered explosion with a descending tone — boss death."""
    dur = 0.9
    out, lp = [], 0.0
    for i in range(int(SR * dur)):
        t = i / SR
        lp += (random.uniform(-1.0, 1.0) - lp) * 0.25
        tone = math.sin(TAU * (300.0 * math.exp(-t * 2.0) + 60.0) * t)
        out.append((0.6 * lp + 0.5 * tone) * math.exp(-t * 4.0))
    return fade_edges(out)


# ── looping music bed ─────────────────────────────────────────────────────
def music():
    """Seamless ~8.7s neon loop: bass + arp + kick + hats over Am F C G."""
    bpm = 110.0
    beat = 60.0 / bpm
    bar = beat * 4.0
    bars = 4
    dur = bar * bars
    n = int(SR * dur)
    out = [0.0] * n
    roots = [220.0, 174.61, 261.63, 196.0]          # A3 F3 C4 G3
    triads = [[0, 3, 7], [0, 4, 7], [0, 4, 7], [0, 4, 7]]

    def hz(base, semis):
        return base * (2.0 ** (semis / 12.0))

    def add(start_t, length, fn):
        s = int(start_t * SR)
        for i in range(int(length * SR)):
            idx = s + i
            if 0 <= idx < n:
                out[idx] += fn(i / SR)

    for b in range(bars):
        t0 = b * bar
        base = roots[b]
        # bass: triangle, root one octave down, re-pluck each beat
        bf = base / 2.0
        add(t0, bar, lambda t, bf=bf, beat=beat: 0.20 * (2.0 / math.pi) *
            math.asin(math.sin(TAU * bf * t)) * math.exp(-(t % beat) * 1.6))
        # arp: eighth notes through the triad, lifting an octave at the end
        triad = [hz(base, s) for s in triads[b]]
        for e in range(8):
            note = triad[e % 3] * (2.0 if e >= 6 else 1.0)
            add(t0 + e * (beat / 2.0), beat / 2.0,
                lambda t, note=note: 0.10 * (0.6 * math.sin(TAU * note * t) +
                0.4 * (1.0 if math.sin(TAU * note * t) >= 0 else -1.0)) * math.exp(-t * 6.0))
        # kick on beats 1 and 3
        for kb in (0, 2):
            add(t0 + kb * beat, 0.2,
                lambda t: 0.5 * math.sin(TAU * (120.0 * math.exp(-t * 30.0) + 45.0) * t) * math.exp(-t * 9.0))
        # hats on the offbeats
        for hb in range(1, 8, 2):
            add(t0 + hb * (beat / 2.0), 0.04,
                lambda t: 0.08 * random.uniform(-1.0, 1.0) * math.exp(-t * 60.0))
    # No edge fade — the buffer is one whole loop and wraps seamlessly.
    return out


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    random.seed(1234)   # deterministic builds
    print("Generating SFX + music ->", OUT_DIR)
    write_wav("shoot.wav", shoot())
    write_wav("explosion.wav", explosion())
    write_wav("hit.wav", hit())
    write_wav("gameover.wav", gameover())
    write_wav("wave.wav", wave_up())
    write_wav("powerup.wav", powerup())
    write_wav("dash.wav", dash())
    write_wav("shield.wav", shield())
    write_wav("bomb.wav", bomb())
    write_wav("bossdie.wav", bossdie())
    write_wav("music.wav", music(), headroom=0.85)
    print("Done.")


if __name__ == "__main__":
    main()
