"""Sample-boundary replay for the real Task 8 RTL and independent Python oracle."""
from pathlib import Path
from tools.v2_voice_reference import VoiceEngine


def generate(path):
    engine = VoiceEngine()
    rows = []

    def emit(op, word=0, sample=0):
        bitmap = sum(1 << i for i, v in enumerate(engine.voices) if v.active)
        rows.append(f"{op} {word:024x} {sample} {bitmap:08x} "
                    f"{int(engine.overflow)} {engine.revoice_count & 255}\n")

    def reset():
        nonlocal engine
        engine = VoiceEngine()
        emit(0)

    def event(kind, note=60, pitch=0, gain=200, mix=0, during_scan=False):
        word = (kind << 91) | (note << 64) | (gain << 56) | ((pitch & 65535) << 40) | (mix << 24)
        if during_scan:
            # A sample begins before the held event. Its result must reflect
            # only events already accepted at that sample boundary.
            sample = engine.sample()
            emit(3, word, sample)
        if kind == 1:
            engine.note_on(note, gain, pitch, mix)
        elif kind == 2:
            engine.note_off(note)
        elif kind == 3:
            engine.revoice(note, pitch)
        elif kind == 5:
            engine.all_notes_off()
        emit(1 if not during_scan else 4, word)

    def samples(n):
        for _ in range(n):
            emit(2, sample=engine.sample())

    reset()
    event(1, pitch=1, mix=0xff80)
    samples(300)  # ADSR and non-multiple-of-512 detune must reach their targets.
    event(3, pitch=-513)
    samples(280)
    event(2, during_scan=True)
    samples(80)
    reset()
    notes = [57, 60, 62, 64, 67, 69, 72]
    for i in range(32):
        event(1, notes[i % len(notes)], (i - 16) * 127, (i * 37) & 255, (i * 1919) & 65535)
        if i in (0, 7):
            samples(20)
    event(1, 100)  # Overflow preserves every existing voice.
    samples(320)
    event(3, 60, -32768, during_scan=True)
    samples(300)
    event(5)
    samples(80)
    # Backpressure for each command type near the end of a scan, and slot reuse.
    event(1, 60, 511, during_scan=True)
    samples(20)
    event(2, 60, during_scan=True)
    samples(80)
    event(1, 69, 32767, mix=0xffff)
    samples(280)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(rows), encoding="ascii")
    return len(rows)


if __name__ == "__main__":
    import sys
    print(f"voice replay rows={generate(sys.argv[1])}")
