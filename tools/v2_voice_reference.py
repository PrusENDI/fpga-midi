class Voice:
 def __init__(self): self.active=False;self.note=0;self.phase=0;self.gain=0
class VoiceEngine:
 def __init__(self,voices=32): self.voices=[Voice() for _ in range(voices)];self.overflow=False;self.revoice_count=0
 def note_on(self,note,velocity=100):
  v=next((x for x in self.voices if not x.active),None)
  if v is None:self.overflow=True;return False
  v.active=True;v.note=note;v.gain=velocity;v.phase=0;return True
 def note_off(self,note):
  for v in self.voices:
   if v.active and v.note==note:v.gain=0;v.active=False
 def revoice(self,note): self.revoice_count+=sum(v.active and v.note==note for v in self.voices)
 def sample(self): return sum(((v.phase>>16)-32768)//16 for v in self.voices if v.active)
