"""Generate the Hermes Voice notification chime.

Output: an 8-bit-flavored ascending arpeggio (E5 → A5 → C#6, 110ms each),
saved as both .wav (working) and .caf (for the iOS bundle). Stdlib only —
no numpy. Run once and commit the output.

Usage: python3 backend/scripts/make_chime.py
"""
from __future__ import annotations

import math
import struct
import subprocess
import sys
import wave
from pathlib import Path

SAMPLE_RATE = 22_050
NOTE_DURATION_S = 0.11
NOTE_GAP_S = 0.02       # small silence between notes for crispness
ATTACK_S = 0.008
RELEASE_S = 0.035
AMPLITUDE = 0.6         # peak amplitude (0..1); short bursts can be loud

NOTES_HZ = [659.25, 880.0, 1108.73]  # E5, A5, C#6


def square_sample(t: float, freq: float) -> float:
    """Pseudo-8-bit square wave with a duty cycle that gives a chip feel."""
    phase = (t * freq) % 1.0
    return 1.0 if phase < 0.5 else -1.0


def envelope(t: float, dur: float) -> float:
    """Simple A-R envelope so notes don't click. Sustain is implicit (=1)."""
    if t < ATTACK_S:
        return t / ATTACK_S
    if t > dur - RELEASE_S:
        return max(0.0, (dur - t) / RELEASE_S)
    return 1.0


def build_samples() -> list[int]:
    samples: list[int] = []
    for freq in NOTES_HZ:
        n = int(SAMPLE_RATE * NOTE_DURATION_S)
        for i in range(n):
            t = i / SAMPLE_RATE
            sample = square_sample(t, freq) * envelope(t, NOTE_DURATION_S) * AMPLITUDE
            samples.append(int(sample * 32_767))
        # Inter-note silence.
        samples.extend([0] * int(SAMPLE_RATE * NOTE_GAP_S))
    return samples


def write_wav(samples: list[int], path: Path) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)  # 16-bit
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))


def convert_to_caf(wav: Path, caf: Path) -> None:
    """Use macOS's afconvert (always present on dev machines) to make .caf."""
    subprocess.run(
        ["afconvert", "-f", "caff", "-d", "LEI16", str(wav), str(caf)],
        check=True,
    )


def main() -> int:
    out_dir = Path(__file__).resolve().parent.parent.parent / "ios" / "HermesVoice" / "HermesVoice" / "Resources"
    out_dir.mkdir(parents=True, exist_ok=True)
    wav_path = out_dir / "hermes-chime.wav"
    caf_path = out_dir / "hermes-chime.caf"

    samples = build_samples()
    write_wav(samples, wav_path)
    try:
        convert_to_caf(wav_path, caf_path)
        wav_path.unlink()  # only keep the .caf
        print(f"wrote {caf_path} ({caf_path.stat().st_size} bytes)")
    except FileNotFoundError:
        print(
            "afconvert not found; keeping .wav. iOS accepts .wav for both "
            "AVAudioPlayer and UNNotificationSound.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
