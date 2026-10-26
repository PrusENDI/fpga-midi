class Voice:
 def __init__(self): self.active=False;self.releasing=False;self.note=0;self.phase=0;self.increment=0;self.target=0;self.gain=0;self.env=0
class VoiceEngine:
 def __init__(self,voices=32): self.voices=[Voice() for _ in range(voices)];self.overflow=False;self.revoice_count=0
 def note_on(self,note,velocity=100):
  v=next((x for x in self.voices if not x.active),None)
  if v is None:self.overflow=True;return False
  v.active=True;v.releasing=False;v.note=note;v.gain=velocity;v.env=0;v.phase=0;v.increment=0;v.target=1;return True
 def note_off(self,note):
  for v in self.voices:
   if v.active and v.note==note:v.releasing=True
 def revoice(self,note): self.revoice_count+=sum(v.active and v.note==note for v in self.voices)
 def sample(self):
  for v in self.voices:
   if v.active:
    v.increment += max(-512,min(512,v.target-v.increment));v.phase=(v.phase+v.increment)&0xffffffff
    v.env=max(0,v.env-1) if v.releasing else min(v.gain,v.env+1)
    if v.releasing and v.env==0:v.active=False
  return sum(((v.phase>>16)-32768)//16 for v in self.voices if v.active)
