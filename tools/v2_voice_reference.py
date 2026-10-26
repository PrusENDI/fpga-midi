"""Fixed-point reference for the Task 8 two-oscillator voice manager.

The RTL scans one slot per 100 MHz clock.  This reference advances every
active slot for one audio sample, which is equivalent at the sample boundary
and keeps the vector tests readable.
"""

PHASE_MASK = 0xFFFFFFFF
SUSTAIN_LEVEL = 49152
ATTACK_STEP = 4096
DECAY_STEP = 256
RELEASE_STEP = 1024
DEFAULT_MIX = 128


def note_increment(note: int) -> int:
    # Values match the ROM entries used by the RTL probe.  Unknown notes are
    # legal events and deliberately map to zero until the complete ROM table
    # is installed with the Task 9 wavetable/patch path.
    return {
        57: 19685267,
        60: 23409859,
        62: 26276679,
        64: 29494575,
        67: 35075158,
        69: 39370534,
        72: 46819719,
    }.get(note & 0xFF, 0)


class Voice:
    def __init__(self):
        self.active = False
        self.releasing = False
        self.note = 0
        self.track = 0
        self.tick = 0
        self.duration = 0
        self.flags = 0
        self.phase_a = 0
        self.phase_b = 0
        self.increment_a = 0
        self.increment_b = 0
        self.target_a = 0
        self.target_b = 0
        self.gain = 0
        self.mix_a = DEFAULT_MIX
        self.mix_b = DEFAULT_MIX
        self.env = 0
        self.stage = "attack"


class VoiceEngine:
    def __init__(self, voices=32):
        self.voices = [Voice() for _ in range(voices)]
        self.overflow = False
        self.revoice_count = 0
        self.scan_base = 0

    @staticmethod
    def _apply_delta(base: int, delta: int) -> int:
        value = int(base) + int(delta)
        return max(0, min(PHASE_MASK, value))

    @staticmethod
    def _bounded_step(current: int, target: int) -> int:
        if current < target:
            return current + min(512, target - current)
        if current > target:
            return current - min(512, current - target)
        return current

    def note_on(self, note, velocity=100, pitch_mod=0, timbre_mod=0,
                track=0, tick=0, duration=0, flags=0):
        voice = next((v for v in self.voices if not v.active), None)
        if voice is None:
            self.overflow = True
            return False
        base = note_increment(note)
        voice.active = True
        voice.releasing = False
        voice.note = note & 0xFF
        voice.track = track & 0x7
        voice.tick = tick & 0xFF
        voice.duration = duration & 0xFF
        voice.flags = flags & 0xFF
        voice.phase_a = 0
        voice.phase_b = 0
        voice.increment_a = base
        voice.increment_b = base
        voice.target_a = self._apply_delta(base, pitch_mod)
        voice.target_b = self._apply_delta(base, -pitch_mod)
        voice.gain = velocity & 0xFF
        if timbre_mod:
            voice.mix_a = (timbre_mod >> 8) & 0xFF
            voice.mix_b = timbre_mod & 0xFF
        else:
            voice.mix_a = DEFAULT_MIX
            voice.mix_b = DEFAULT_MIX
        voice.env = 0
        voice.stage = "attack"
        return True

    def note_off(self, note):
        for voice in self.voices:
            if voice.active and voice.note == (note & 0xFF):
                voice.releasing = True
                voice.stage = "release"

    def all_notes_off(self):
        for voice in self.voices:
            if voice.active:
                voice.releasing = True
                voice.stage = "release"

    def revoice(self, note, pitch_mod=0):
        hits = 0
        for voice in self.voices:
            if voice.active and voice.note == (note & 0xFF):
                base = note_increment(note)
                voice.target_a = self._apply_delta(base, pitch_mod)
                voice.target_b = self._apply_delta(base, -pitch_mod)
                hits += 1
        self.revoice_count += hits
        return hits

    @staticmethod
    def _oscillator(phase, stage, gain, mix):
        raw = ((phase >> 16) & 0xFFFF) - 32768
        attenuation = {"attack": 2, "decay": 1, "sustain": 0, "release": 3}[stage]
        if gain < 64:
            attenuation += 3
        elif gain < 128:
            attenuation += 2
        elif gain < 192:
            attenuation += 1
        if mix < 64:
            attenuation += 3
        elif mix < 128:
            attenuation += 2
        elif mix < 192:
            attenuation += 1
        return raw >> attenuation

    def sample(self):
        mixed = 0
        count = len(self.voices)
        for offset in range(count):
            voice = self.voices[(self.scan_base + offset) % count]
            if not voice.active:
                continue
            mixed += self._oscillator(voice.phase_a, voice.stage, voice.gain, voice.mix_a)
            mixed += self._oscillator(voice.phase_b, voice.stage, voice.gain, voice.mix_b)
            voice.phase_a = (voice.phase_a + voice.increment_a) & PHASE_MASK
            voice.phase_b = (voice.phase_b + voice.increment_b) & PHASE_MASK
            voice.increment_a = self._bounded_step(voice.increment_a, voice.target_a)
            voice.increment_b = self._bounded_step(voice.increment_b, voice.target_b)
            if voice.stage == "attack":
                voice.env += ATTACK_STEP
                if voice.env >= 0xFFFF:
                    voice.env = 0xFFFF
                    voice.stage = "decay"
            elif voice.stage == "decay":
                if voice.env <= SUSTAIN_LEVEL + DECAY_STEP:
                    voice.env = SUSTAIN_LEVEL
                    voice.stage = "sustain"
                else:
                    voice.env -= DECAY_STEP
            elif voice.stage == "release":
                if voice.env <= RELEASE_STEP:
                    voice.env = 0
                    voice.active = False
                    voice.releasing = False
                    voice.stage = "attack"
                else:
                    voice.env -= RELEASE_STEP
        self.scan_base = (self.scan_base + 1) % count
        return max(-32768, min(32767, mixed))
