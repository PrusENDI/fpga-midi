import unittest

from tools.v2_voice_reference import VoiceEngine


class VoiceTests(unittest.TestCase):
    def test_one_voice_attack_and_round_robin(self):
        engine = VoiceEngine()
        self.assertTrue(engine.note_on(60, velocity=200))
        self.assertEqual(sum(v.active for v in engine.voices), 1)
        self.assertEqual(engine.scan_base, 0)
        engine.sample()
        self.assertEqual(engine.scan_base, 1)
        self.assertGreater(engine.voices[0].env, 0)

    def test_thirty_two_voice_steal_released_then_reuse(self):
        engine = VoiceEngine()
        for index in range(8):
            self.assertTrue(engine.note_on(60 + index, velocity=255))
        self.assertEqual(sum(v.active for v in engine.voices), 8)
        for index in range(8, 32):
            self.assertTrue(engine.note_on(60 + index % 8, velocity=255))
        self.assertEqual(sum(v.active for v in engine.voices), 32)
        engine.note_off(60)
        self.assertTrue(engine.note_on(100, velocity=255))
        self.assertEqual(engine.voice_steal_count, 1)
        self.assertEqual(engine.pending_steal_slot, 0)
        self.assertTrue(engine.voices[0].releasing)
        self.assertTrue(engine.note_on(101, velocity=255) is False)
        for _ in range(320):
            engine.sample()
        self.assertTrue(engine.voices[0].active)
        self.assertEqual(engine.voices[0].note, 100)

    def test_full_voice_steal_uses_oldest_then_velocity_then_id(self):
        engine = VoiceEngine()
        for index in range(32):
            self.assertTrue(engine.note_on(40 + index, velocity=200 - index))
        # Equal age is constructed explicitly to isolate the velocity/id tie-break.
        for index, voice in enumerate(engine.voices):
            voice.age = 7
            voice.releasing = False
            voice.active = True
        engine.voices[3].velocity = 10
        engine.voices[5].velocity = 10
        self.assertTrue(engine.note_on(100, velocity=100))
        self.assertEqual(engine.pending_steal_slot, 3)

    def test_vibrato_phase_and_signed_increment_modulation(self):
        engine = VoiceEngine(vibrato_hz_q8_8=256, vibrato_cents_q8_8=12 * 256)
        self.assertTrue(engine.note_on(60, velocity=200))
        voice = engine.voices[0]
        base = voice.increment_a
        for _ in range(64):
            engine.sample()
        self.assertNotEqual(voice.vibrato_phase, 0)
        self.assertNotEqual(voice.vibrato_delta_cents, 0)
        self.assertNotEqual(voice.increment_a, base)
        self.assertEqual(voice.increment_a + voice.increment_b, 2 * base)

    def test_revoice_preserves_phase_and_bounded_detune(self):
        engine = VoiceEngine()
        engine.note_on(60, pitch_mod=0)
        engine.sample()
        voice = engine.voices[0]
        phase = (voice.phase_a, voice.phase_b)
        self.assertEqual(engine.revoice(60, pitch_mod=4096), 1)
        self.assertEqual(engine.revoice_count, 1)
        self.assertEqual((voice.phase_a, voice.phase_b), phase)
        self.assertNotEqual(voice.target_a, voice.target_b)
        for _ in range(20):
            engine.sample()
        self.assertLessEqual(abs(voice.increment_a - voice.target_a), 512 * 20)

    def test_adsr_attack_decay_sustain(self):
        engine = VoiceEngine()
        engine.note_on(60, velocity=10)
        for _ in range(16):
            engine.sample()
        voice = engine.voices[0]
        self.assertEqual(voice.stage, "decay")
        for _ in range(300):
            engine.sample()
        self.assertEqual(voice.stage, "sustain")
        self.assertEqual(voice.env, 49152)

    def test_release_and_all_notes_off(self):
        engine = VoiceEngine()
        engine.note_on(60)
        engine.note_on(64)
        for _ in range(4):
            engine.sample()
        engine.note_off(60)
        for _ in range(80):
            engine.sample()
        self.assertFalse(engine.voices[0].active)
        self.assertTrue(engine.voices[1].active)
        engine.all_notes_off()
        for _ in range(80):
            engine.sample()
        self.assertFalse(any(v.active for v in engine.voices))

    def test_saturating_two_oscillator_mix(self):
        engine = VoiceEngine()
        for _ in range(32):
            engine.note_on(60, velocity=255, timbre_mod=0xFFFF)
        for voice in engine.voices:
            voice.env = 0xFFFF
            voice.phase_a = 0xFFFF0000
            voice.phase_b = 0xFFFF0000
            voice.mix_a = 0xFF
            voice.mix_b = 0xFF
        self.assertEqual(engine.sample(), 32767)


if __name__ == "__main__":
    unittest.main()
