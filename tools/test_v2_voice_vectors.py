import unittest
from tools.v2_voice_reference import VoiceEngine
class VoiceTests(unittest.TestCase):
 def test_capacity(self):
  e=VoiceEngine(32)
  for n in range(32): self.assertTrue(e.note_on(60+n))
  self.assertFalse(e.note_on(100));self.assertTrue(e.overflow)
 def test_release_revoice(self):
  e=VoiceEngine();e.note_on(60);e.revoice(60);self.assertEqual(e.revoice_count,1);v=e.voices[0];phase=v.phase;e.note_off(60);self.assertTrue(v.active);[e.sample() for _ in range(200)];self.assertFalse(v.active);self.assertNotEqual(v.phase,phase)
 def test_attack_decay_sustain_and_detune_target(self):
  e=VoiceEngine();e.note_on(60,10);v=e.voices[0];[e.sample() for _ in range(3)];self.assertGreater(v.env,0);v.target=100;self.assertLessEqual(abs(v.increment-v.target),100)
if __name__=='__main__':unittest.main()
