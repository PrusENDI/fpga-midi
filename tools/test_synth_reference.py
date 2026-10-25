import math
import unittest

from tools.synth_reference import (ENV_MAX, SAMPLE_RATE, SynthEngine, TIMBRE_SINE,
                                   TIMBRE_SQUARE, phase_increment, note_frequency)


def _zero_crossings(samples):
    crossings = 0
    for before, after in zip(samples, samples[1:]):
        if (before <= 0 < after) or (before >= 0 > after):
            crossings += 1
    return crossings


class PhaseTests(unittest.TestCase):
    def test_phase_increment_matches_the_contract(self):
        # 440 Hz at 48 kHz is 440 * 2^32 / 48000 = 39,370,534.
        self.assertEqual(phase_increment(440.0), 39370534)

    def test_note_frequency_anchor(self):
        self.assertAlmostEqual(note_frequency(69), 440.0, places=6)
        self.assertAlmostEqual(note_frequency(57), 220.0, places=6)

    def test_increment_is_bounded(self):
        self.assertLess(phase_increment(20000.0), 1 << 32)


class OscillatorTests(unittest.TestCase):
    def test_sine_frequency_error_is_under_one_hertz(self):
        engine = SynthEngine(voice_count=1, sample_rate=SAMPLE_RATE)
        engine.note_on(0, 69, velocity=127, timbre=TIMBRE_SINE)
        samples = engine.render(SAMPLE_RATE)          # one second
        measured = _zero_crossings(samples) / 2.0
        self.assertLess(abs(measured - 440.0), 1.0)

    def test_sine_amplitude_is_in_range(self):
        engine = SynthEngine(voice_count=1)
        engine.note_on(0, 69, velocity=127, timbre=TIMBRE_SINE)
        peak = max(abs(sample) for sample in engine.render(4800))
        self.assertGreater(peak, 2000)
        self.assertLessEqual(peak, 32767)

    def test_square_is_bipolar(self):
        engine = SynthEngine(voice_count=1)
        engine.note_on(0, 57, velocity=127, timbre=TIMBRE_SQUARE)
        samples = engine.render(4800)
        self.assertTrue(any(sample > 1000 for sample in samples))
        self.assertTrue(any(sample < -1000 for sample in samples))


class EnvelopeTests(unittest.TestCase):
    def test_attack_then_sustain_then_release(self):
        engine = SynthEngine(voice_count=1)
        engine.note_on(0, 69, velocity=127, timbre=TIMBRE_SINE)
        voice = engine.voices[0]
        engine.render(240)                             # 5 ms in
        rising = voice.envelope.level
        engine.render(4800)                            # past decay, in sustain
        held = voice.envelope.level
        self.assertGreater(rising, 0)
        self.assertGreater(held, 0)
        self.assertLessEqual(held, ENV_MAX)
        engine.note_off(0, 69)
        engine.render(14000)                           # release finished
        self.assertEqual(voice.envelope.level, 0)
        self.assertFalse(voice.active)

    def test_voice_releases_only_its_own_note(self):
        engine = SynthEngine(voice_count=4)
        engine.note_on(0, 60, velocity=100)
        engine.note_on(0, 64, velocity=100)
        self.assertEqual(engine.note_off(0, 60), 1)
        self.assertEqual(engine.active_voices(), 2)     # both still sounding
        engine.render(48000)
        self.assertEqual(engine.active_voices(), 1)     # the released one is gone


class PolyphonyTests(unittest.TestCase):
    def test_thirty_two_voices_stay_inside_the_range(self):
        engine = SynthEngine(voice_count=32)
        for index in range(32):
            engine.note_on(index % 4, 48 + index, velocity=127)
        self.assertEqual(engine.active_voices(), 32)
        samples = engine.render(2400)
        self.assertLessEqual(max(samples), 32767)
        self.assertGreaterEqual(min(samples), -32768)

    def test_last_note_steals_when_full(self):
        engine = SynthEngine(voice_count=2)
        engine.note_on(0, 60)
        engine.note_on(0, 62)
        engine.note_on(0, 64)
        notes = sorted(voice.note for voice in engine.voices if voice.active)
        self.assertEqual(notes, [62, 64])

    def test_all_notes_off_releases_everything(self):
        engine = SynthEngine(voice_count=4)
        engine.note_on(0, 60)
        engine.note_on(1, 64)
        engine.all_notes_off()
        engine.render(48000)
        self.assertEqual(engine.active_voices(), 0)


class DeterminismTests(unittest.TestCase):
    def test_same_sequence_gives_same_samples(self):
        def run():
            engine = SynthEngine(voice_count=8)
            engine.note_on(0, 60, velocity=100)
            engine.note_on(1, 67, velocity=80)
            first = engine.render(2000)
            engine.note_off(0, 60)
            second = engine.render(2000)
            return first + second

        self.assertEqual(run(), run())


if __name__ == "__main__":
    unittest.main()
