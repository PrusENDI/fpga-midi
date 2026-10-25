import struct
import tempfile
import unittest
import wave
from pathlib import Path

from tools.synth_render import render_table
from tools.synthwave_loop import STYLE


def _table(notes, loop_bars=1, bpm=100):
    """Minimal event table: (tick, duration, note, track, velocity)."""
    events = [{"track": track, "type": "note_on", "tick": tick, "duration": duration,
               "note": note, "velocity": velocity}
              for tick, duration, note, track, velocity in notes]
    return {"config": {"bpm": bpm, "loop_bars": loop_bars, "ticks_per_bar": 16}, "events": events}


def _read(path):
    with wave.open(str(path)) as handle:
        frames = handle.getnframes()
        rate = handle.getframerate()
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        raw = handle.readframes(frames)
    return frames, rate, channels, width, raw


class RenderTests(unittest.TestCase):
    def test_wav_format_and_length(self):
        table = _table([(0, 8, 60, "lead", 100)])
        path = Path(tempfile.gettempdir()) / "m3_one_note.wav"
        render_table(table, path, tail_ms=500)
        frames, rate, channels, width, _ = _read(path)
        self.assertEqual((rate, channels, width), (48000, 1, 2))
        # One bar at 100 BPM is 2.4 s, plus 0.5 s tail.
        self.assertAlmostEqual(frames / rate, 2.9, places=1)

    def test_silent_when_no_events(self):
        path = Path(tempfile.gettempdir()) / "m3_silent.wav"
        render_table(_table([]), path, tail_ms=100)
        _, _, _, _, raw = _read(path)
        self.assertEqual(max(abs(value) for value in struct.unpack("<%dh" % (len(raw) // 2), raw)), 0)

    def test_notes_do_not_clip(self):
        notes = [(index * 2, 4, 48 + index, "lead", 127) for index in range(16)]
        path = Path(tempfile.gettempdir()) / "m3_poly.wav"
        render_table(_table(notes), path, tail_ms=300)
        _, _, _, _, raw = _read(path)
        values = struct.unpack("<%dh" % (len(raw) // 2), raw)
        self.assertLessEqual(max(values), 32767)
        self.assertGreaterEqual(min(values), -32768)
        self.assertGreater(max(values), 1000)

    def test_render_is_deterministic(self):
        table = _table([(0, 4, 60, "lead", 100), (4, 4, 64, "lead", 90)])
        first = Path(tempfile.gettempdir()) / "m3_a.wav"
        second = Path(tempfile.gettempdir()) / "m3_b.wav"
        render_table(table, first, tail_ms=100)
        render_table(table, second, tail_ms=100)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_release_falls_silent_by_the_end(self):
        table = _table([(0, 2, 60, "lead", 100)])
        path = Path(tempfile.gettempdir()) / "m3_release.wav"
        render_table(table, path, tail_ms=800)
        _, rate, _, _, raw = _read(path)
        values = struct.unpack("<%dh" % (len(raw) // 2), raw)
        tail = values[-int(0.05 * rate):]
        self.assertLess(max(abs(value) for value in tail), 200)


if __name__ == "__main__":
    unittest.main()
