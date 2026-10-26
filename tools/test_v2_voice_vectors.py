import unittest
from tools.v2_voice_reference import VoiceEngine
class VoiceTests(unittest.TestCase):
 def test_capacity(self):
  e=VoiceEngine(32)
  for n in range(32): self.assertTrue(e.note_on(60+n))
  self.assertFalse(e.note_on(100));self.assertTrue(e.overflow)
 def test_release_revoice(self):
  e=VoiceEngine();e.note_on(60);e.revoice(60);self.assertEqual(e.revoice_count,1);e.note_off(60);self.assertEqual(e.sample(),0)
if __name__=='__main__':unittest.main()
