#!/usr/bin/env python3
"""合成面板的兩段內建提示音（純正弦波 + 泛音 + 指數包絡，無版權問題）。

    python3 extras/make_sounds.py        # 產 Sounds/overheat.m4a、Sounds/cooldown.m4a（需要 macOS 的 afconvert）
"""
import math, os, struct, subprocess, tempfile, wave

SR = 44100
ROOT = os.path.join(os.path.dirname(__file__), "..", "Sounds")


def tone(freq, dur, vol=0.5, attack=0.01, decay=0.25, harmonics=((1, 1.0), (2, 0.35), (3, 0.12))):
    out = []
    for i in range(int(SR * dur)):
        t = i / SR
        env = min(1, t / attack) * math.exp(-t / decay)
        out.append(vol * env * sum(a * math.sin(2 * math.pi * freq * h * t) for h, a in harmonics))
    return out


def mix(parts):
    buf = [0.0] * max(off + len(p) for off, p in parts)
    for off, p in parts:
        for i, v in enumerate(p):
            buf[off + i] += v
    peak = max(abs(x) for x in buf) or 1
    return [x / peak * 0.85 for x in buf]


def save(name, buf):
    os.makedirs(ROOT, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav = f.name
    with wave.open(wav, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(x * 32767)) for x in buf))
    out = os.path.join(ROOT, name + ".m4a")
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000", wav, out], check=True)
    os.remove(wav)
    print(out, f"{len(buf) / SR:.2f}s")


s = lambda sec: int(SR * sec)
# 過熱：下行兩音 A5 → E5，第二音拖長，有警示感
save("overheat", mix([(0, tone(880, 0.35, decay=0.12)), (s(0.22), tone(659, 0.7, decay=0.3))]))
# 回穩：上行琶音 C5 E5 G5 收在 C6，乾淨的鐘聲
save("cooldown", mix([(0, tone(523, 0.5)), (s(0.12), tone(659, 0.5)), (s(0.24), tone(784, 0.6)), (s(0.38), tone(1047, 0.9, decay=0.4))]))
