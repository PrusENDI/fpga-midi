"""Bit-exact scalar reference for the V2 input calibration/quality chain."""
from dataclasses import dataclass, replace
from typing import Tuple

REASON_INVALID = 1 << 0
REASON_SATURATED = 1 << 1
REASON_GAP = 1 << 2
REASON_EPOCH = 1 << 3
REASON_CLAMP = 1 << 4
REASON_PROFILE = 1 << 5

@dataclass(frozen=True)
class Profile:
    neutral: Tuple[int, int, int] = (0, 0, 0)
    coupling: Tuple[int, int] = (0, 0)       # Q16.16 x/z and y/z
    gain: Tuple[int, int, int] = (1 << 16, 1 << 16, 1 << 16)
    workspace: Tuple[Tuple[int, int], Tuple[int, int], Tuple[int, int]] = ((-32768, 32767),) * 3
    epoch: int = 0
    def _replace(self, **kwargs):
        return replace(self, **kwargs)

def sign_extend(value: int, bits: int = 16) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value

def sat32(value: int) -> tuple[int, bool]:
    lo, hi = -(1 << 31), (1 << 31) - 1
    return (lo, True) if value < lo else ((hi, True) if value > hi else (value, False))

def round_q16(value: int) -> int:
    # Round to nearest, ties away from zero, then arithmetic shift.
    return (value + (1 << 15)) >> 16 if value >= 0 else -((-value + (1 << 15)) >> 16)

def process_frame(frame: dict, profile: Profile, previous_sequence: int | None = None,
                  gap_count: int = 0) -> dict:
    raw = tuple(sign_extend(v) for v in frame.get("raw", (0, 0, 0)))
    reason = 0
    seq = int(frame.get("sequence", 0)) & 0xFFFF
    seq_gap = 0
    if previous_sequence is not None:
        seq_gap = (seq - (previous_sequence & 0xFFFF)) & 0xFFFF
        if seq_gap > 1:
            reason |= REASON_GAP
            gap_count += seq_gap - 1
    if frame.get("gap", False):
        reason |= REASON_GAP
        if seq_gap <= 1:
            gap_count += 1
    if not frame.get("valid_xyz", False):
        reason |= REASON_INVALID
    if frame.get("saturated", False):
        reason |= REASON_SATURATED
    if int(frame.get("calibration_epoch", profile.epoch)) != profile.epoch:
        reason |= REASON_EPOCH
    centered = tuple(raw[i] - profile.neutral[i] for i in range(3))
    coupling_x = round_q16(profile.coupling[0] * centered[2])
    coupling_y = round_q16(profile.coupling[1] * centered[2])
    decoupled = (centered[0] - coupling_x, centered[1] - coupling_y, centered[2])
    gained = tuple(round_q16(decoupled[i] * profile.gain[i]) for i in range(3))
    xyz = []
    clamped = False
    for i, value in enumerate(gained):
        value, sat = sat32(value)
        lo, hi = profile.workspace[i]
        if value < lo:
            value, clamped = lo, True
        elif value > hi:
            value, clamped = hi, True
        xyz.append(value)
    if clamped:
        reason |= REASON_CLAMP
    lost = bool(reason & REASON_GAP)
    frame_valid = not bool(reason & (REASON_INVALID | REASON_SATURATED | REASON_GAP | REASON_EPOCH | REASON_PROFILE))
    degraded = bool(reason & (REASON_CLAMP | REASON_GAP | REASON_EPOCH | REASON_PROFILE))
    return {
        "sequence": seq, "timestamp_ticks": int(frame.get("timestamp_ticks", 0)) & 0xFFFFFFFF,
        "xyz": tuple(xyz), "centered": centered, "decoupled": decoupled, "gained": gained,
        "frame_valid": frame_valid, "lost": lost, "degraded": degraded,
        "gap_count": gap_count, "calibration_reason": reason,
    }
