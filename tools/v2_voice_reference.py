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
SAMPLE_HZ = 48_000
STEAL_RELEASE_SAMPLES = 8


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
        self.velocity = 0
        self.age = 0
        self.steal_hold = 0
        self.mix_a = DEFAULT_MIX
        self.mix_b = DEFAULT_MIX
        self.env = 0
        self.stage = "attack"
        self.vibrato_phase = 0
        self.vibrato_delta_cents = 0


class VoiceEngine:
    def __init__(self, voices=32, vibrato_hz_q8_8=0, vibrato_cents_q8_8=0):
        self.voices = [Voice() for _ in range(voices)]
        self.overflow = False
        self.voice_steal_count = 0
        self.revoice_count = 0
        self.scan_base = 0
        self.age_counter = 0
        self.pending_steal_slot = -1
        self.pending_note = 0
        self.pending_velocity = 0
        self.pending_pitch_mod = 0
        self.pending_timbre_mod = 0
        self.pending_track = 0
        self.pending_tick = 0
        self.pending_duration = 0
        self.pending_flags = 0
        self.vibrato_hz_q8_8 = vibrato_hz_q8_8 & 0xFFFF
        self.vibrato_cents_q8_8 = vibrato_cents_q8_8 & 0xFFFF

    def _allocate(self, voice, note, velocity, pitch_mod, timbre_mod,
                  track, tick, duration, flags):
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
        voice.velocity = velocity & 0xFF
        voice.age = self.age_counter
        self.age_counter = (self.age_counter + 1) & 0xFFFF
        voice.steal_hold = 0
        if timbre_mod:
            voice.mix_a = (timbre_mod >> 8) & 0xFF
            voice.mix_b = timbre_mod & 0xFF
        else:
            voice.mix_a = DEFAULT_MIX
            voice.mix_b = DEFAULT_MIX
        voice.env = 0
        voice.stage = "attack"
        voice.vibrato_phase = 0
        voice.vibrato_delta_cents = 0

    def _select_steal_slot(self):
        candidates = [v for v in self.voices if v.active]
        if not candidates:
            return -1
        return min(
            (index for index, voice in enumerate(self.voices) if voice.active),
            key=lambda index: (
                0 if self.voices[index].releasing else 1,
                self.voices[index].age,
                self.voices[index].velocity,
                index,
            ),
        )

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
        if self.pending_steal_slot >= 0:
            return False
        free_slot = next((index for index, v in enumerate(self.voices) if not v.active), None)
        if free_slot is not None:
            self._allocate(self.voices[free_slot], note, velocity, pitch_mod,
                           timbre_mod, track, tick, duration, flags)
            return True
        steal_slot = self._select_steal_slot()
        if steal_slot < 0:
            self.overflow = True
            return False
        victim = self.voices[steal_slot]
        victim.releasing = True
        victim.stage = "release"
        # The RTL updates one voice per sample scan, so a bounded eight-scan
        # release takes eight complete voice passes in the sample-level model.
        victim.steal_hold = STEAL_RELEASE_SAMPLES * len(self.voices)
        self.pending_steal_slot = steal_slot
        self.pending_note = note & 0xFF
        self.pending_velocity = velocity & 0xFF
        self.pending_pitch_mod = pitch_mod
        self.pending_timbre_mod = timbre_mod
        self.pending_track = track
        self.pending_tick = tick
        self.pending_duration = duration
        self.pending_flags = flags
        self.voice_steal_count += 1
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

    def _vibrato_phase_increment(self):
        return (self.vibrato_hz_q8_8 * 65536) // (256 * SAMPLE_HZ)

    def _vibrato_delta(self, phase):
        lfo = ((phase >> 1) & 0x7FFF) - 16384
        return (lfo * self.vibrato_cents_q8_8) >> 14

    @staticmethod
    def _vibrato_increment_delta(base, delta_cents_q8_8):
        return (int(base) * int(delta_cents_q8_8)) // (1200 * 256)

    def sample(self):
        mixed = 0
        count = len(self.voices)
        for offset in range(count):
            voice = self.voices[(self.scan_base + offset) % count]
            if not voice.active:
                continue
            voice.vibrato_phase = (voice.vibrato_phase + self._vibrato_phase_increment()) & 0xFFFF
            voice.vibrato_delta_cents = self._vibrato_delta(voice.vibrato_phase)
            mixed += self._oscillator(voice.phase_a, voice.stage, voice.gain, voice.mix_a)
            mixed += self._oscillator(voice.phase_b, voice.stage, voice.gain, voice.mix_b)
            voice.phase_a = (voice.phase_a + voice.increment_a) & PHASE_MASK
            voice.phase_b = (voice.phase_b + voice.increment_b) & PHASE_MASK
            glide_a = self._bounded_step(voice.increment_a, voice.target_a)
            glide_b = self._bounded_step(voice.increment_b, voice.target_b)
            delta = self._vibrato_increment_delta(glide_a, voice.vibrato_delta_cents)
            voice.increment_a = max(0, min(PHASE_MASK, glide_a + delta))
            voice.increment_b = max(0, min(PHASE_MASK, glide_b - delta))
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
                if voice.steal_hold:
                    voice.steal_hold -= 1
                if voice.env <= RELEASE_STEP and voice.steal_hold == 0:
                    voice.env = 0
                    voice.active = False
                    voice.releasing = False
                    voice.stage = "attack"
                else:
                    voice.env -= RELEASE_STEP
        if self.pending_steal_slot >= 0 and not self.voices[self.pending_steal_slot].active:
            self._allocate(self.voices[self.pending_steal_slot], self.pending_note,
                           self.pending_velocity, self.pending_pitch_mod,
                           self.pending_timbre_mod, self.pending_track,
                           self.pending_tick, self.pending_duration,
                           self.pending_flags)
            self.pending_steal_slot = -1
        self.scan_base = (self.scan_base + 1) % count
        return max(-32768, min(32767, mixed))
