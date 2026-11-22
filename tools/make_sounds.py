#!/usr/bin/env python3
"""產生 App 內建的鬧鐘音檔（44.1 kHz、單聲道、16-bit WAV，長度 < 30 秒）。

AlarmKit 自訂鈴聲要求 30 秒以內，App 警報聲也直接讀同一批檔案
（KeepAlive 要求 44.1 kHz 單聲道）。原本的 wake_alarm.wav 不由這個腳本產生。

用法：python3 tools/make_sounds.py   （需要 numpy）
"""
import wave
from pathlib import Path

import numpy as np

SR = 44_100
DUR = 28.0
OUT = Path(__file__).resolve().parent.parent / "App" / "Sounds"
t = np.arange(int(SR * DUR)) / SR


def square(phase):
    return np.sign(np.sin(phase))


def saw(phase):
    return 2 * ((phase / (2 * np.pi)) % 1.0) - 1


def phase_of(freq):
    """頻率（可隨時間變）→ 相位，避免掃頻時爆音"""
    return 2 * np.pi * np.cumsum(freq) / SR


def finish(x, drive=3.0):
    """壓縮＋軟削波：讓平均響度接近滿格（聽起來更大聲），峰值留一點空間"""
    x = x - np.mean(x)
    x = x / (np.max(np.abs(x)) + 1e-9)
    x = np.tanh(drive * x) / np.tanh(drive)
    fade = int(0.005 * SR)  # 頭尾 5 ms 淡入淡出，循環播放時不會喀一聲
    x[:fade] *= np.linspace(0, 1, fade)
    x[-fade:] *= np.linspace(1, 0, fade)
    return 0.98 * x / np.max(np.abs(x))


def ramp_speed(base):
    """每 7 秒加速一次（1×、1.3×、1.7×、2.2×）"""
    return base * np.choose(np.minimum((t // 7).astype(int), 3), [1.0, 1.3, 1.7, 2.2])


def scream():
    """極限尖叫：耳朵最敏感的 2.5～4 kHz 快速顫音＋上掃鋸齒波＋雜訊爆裂，幾乎沒有空檔"""
    warble_rate = ramp_speed(np.full_like(t, 11.0))
    warble = 3200 + 600 * square(phase_of(warble_rate))
    a = square(phase_of(warble))
    sweep_rate = ramp_speed(np.full_like(t, 2.0))
    sweep_pos = (np.cumsum(sweep_rate) / SR) % 1.0
    b = saw(phase_of(900 + 2600 * sweep_pos))
    rng = np.random.default_rng(7)
    noise = rng.uniform(-1, 1, t.size)
    gate = ((t * ramp_speed(np.full_like(t, 4.0))) % 1.0) < 0.25
    return finish(0.55 * a + 0.35 * b + 0.45 * noise * gate, drive=4.0)


def klaxon():
    """防空警報：低音鋸齒波快速上滑（awooga）疊高頻嗶聲，低頻在枕頭／被子裡也穿得透"""
    period = 0.6
    pos = (t % period) / period
    f = np.where(pos < 0.75, 300 + 350 * (pos / 0.75) ** 0.5, 650)
    low = saw(phase_of(f)) + 0.6 * square(phase_of(f * 2.01))
    beep_on = ((t * 6) % 1.0) < 0.5
    high = square(2 * np.pi * 2900 * t) * beep_on
    env = np.where(pos < 0.92, 1.0, 0.25)
    return finish((0.7 * low + 0.5 * high) * env, drive=3.5)


def chaos():
    """隨機轟炸：每 60～250 ms 隨機換一種聲音（方波、掃頻、雜訊、不和諧和弦），大腦沒辦法習慣節奏"""
    rng = np.random.default_rng(42)
    out = np.zeros_like(t)
    i = 0
    while i < t.size:
        n = int(rng.uniform(0.06, 0.25) * SR)
        seg = np.arange(min(n, t.size - i)) / SR
        kind = rng.integers(0, 4)
        if kind == 0:
            s = square(2 * np.pi * rng.uniform(1500, 4500) * seg)
        elif kind == 1:
            f0, f1 = rng.uniform(500, 4500, 2)
            s = saw(phase_of(np.linspace(f0, f1, seg.size)))
        elif kind == 2:
            s = rng.uniform(-1, 1, seg.size)
        else:
            base = rng.uniform(1800, 3000)
            s = sum(square(2 * np.pi * base * r * seg) for r in (1.0, 1.06, 1.41)) / 3
        out[i:i + seg.size] = s
        i += seg.size
    return finish(out, drive=3.0)


def write(name, x):
    data = (x * 32767).astype("<i2").tobytes()
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)
    rms = float(np.sqrt(np.mean(x ** 2)))
    print(f"{name}: {len(x) / SR:.1f}s RMS {20 * np.log10(rms):.1f} dBFS")


if __name__ == "__main__":
    write("wake_scream.wav", scream())
    write("wake_klaxon.wav", klaxon())
    write("wake_chaos.wav", chaos())
