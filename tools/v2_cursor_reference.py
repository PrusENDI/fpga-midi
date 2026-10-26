"""Bit-exact scalar reference for the V2 cursor filter.

The model deliberately keeps the input frame clock separate from ``sample_ce``:
``push`` is called once per calibrated frame and ``sample_ce`` only snapshots the
most recent stable control point for the audio domain.
"""
from __future__ import annotations
from dataclasses import dataclass
from typing import Iterable, Optional, Sequence, Tuple

Q16_ONE = 1 << 16
ALPHA_LOW_Q16 = round(0.12 * Q16_ONE)  # high-Z follow floor
ALPHA_HIGH_Q16 = Q16_ONE              # low-Z follows immediately
Z_LOW = 4_000
Z_HIGH = 24_000
Z_ENGAGE = 30_000
Z_RELEASE = 36_000
MAX_STEP_Q16 = Q16_ONE // 16
SETTLE_TICKS = 2

DISENGAGED = "DISENGAGED"
ENGAGED = "ENGAGED"
REBASED = "REBASED"
DEGRADED = "DEGRADED"

REASON_INVALID = 1 << 0
REASON_SATURATED = 1 << 1
REASON_GAP = 1 << 2
REASON_EPOCH = 1 << 3
REASON_CLAMP = 1 << 4
REASON_PROFILE = 1 << 5
REASON_ARITH_SAT = 1 << 6
BAD_REASONS = REASON_INVALID | REASON_SATURATED | REASON_GAP | REASON_EPOCH | REASON_PROFILE | REASON_ARITH_SAT


def clamp(value: int, low: int, high: int) -> int:
    return low if value < low else high if value > high else value


def median(values: Sequence[int]) -> int:
    if not values:
        raise ValueError("median requires at least one value")
    return sorted(values)[len(values) // 2]


def median5(history: Sequence[int]) -> int:
    """Causal five point median (fewer than five points use all available)."""
    return median(tuple(history[-5:]))


def alpha_q16(z: int, *, alpha_low_q16: int = ALPHA_LOW_Q16,
              alpha_high_q16: int = ALPHA_HIGH_Q16,
              z_low: int = Z_LOW, z_high: int = Z_HIGH) -> int:
    if z_high <= z_low:
        return clamp(alpha_high_q16, 0, Q16_ONE)
    ratio = clamp(((int(z) - z_low) * Q16_ONE) // (z_high - z_low), 0, Q16_ONE)
    return clamp(alpha_high_q16 - ((alpha_high_q16 - alpha_low_q16) * ratio // Q16_ONE), 0, Q16_ONE)


def raw_to_q16(value: int, low: int = -32768, high: int = 32767) -> int:
    """Map a calibrated signed sensor axis to a 0..1 Q16.16 absolute point."""
    if high <= low:
        return 0
    return clamp(((int(value) - low) * Q16_ONE) // (high - low), 0, Q16_ONE)


@dataclass(frozen=True)
class CursorFrame:
    x: int
    y: int
    z: int
    valid: bool = True
    valid_xyz: bool = True
    saturated: bool = False
    gap: bool = False
    reason: int = 0
    degraded: bool = False
    left_edge: bool = False
    sequence: int = 0
    timestamp_ticks: int = 0

    @property
    def bad(self) -> bool:
        reason = int(self.reason)
        return (not self.valid or not self.valid_xyz or self.saturated or self.gap or bool(reason & BAD_REASONS))


@dataclass(frozen=True)
class CursorPoint:
    cursor_x_q16: int
    cursor_y_q16: int
    cursor_z: int
    normalized_pitch_q16: int
    velocity_q16: int
    depth_q16: int
    state: str
    rebased: bool
    stable: bool
    sequence: int
    timestamp_ticks: int
    calibration_reason: int = 0

    @property
    def x(self) -> int:
        return self.cursor_x_q16

    @property
    def y(self) -> int:
        return self.cursor_y_q16

    @property
    def z(self) -> int:
        return self.cursor_z


class CursorFilter:
    """Five point median, adaptive Q16 IIR, slew and anchor-relative clutch."""

    def __init__(self, *, alpha_low_q16: int = ALPHA_LOW_Q16,
                 alpha_high_q16: int = ALPHA_HIGH_Q16,
                 z_low: int = Z_LOW, z_high: int = Z_HIGH,
                 z_engage: int = Z_ENGAGE, z_release: int = Z_RELEASE,
                 max_step_q16: int = MAX_STEP_Q16,
                 settle_ticks: int = SETTLE_TICKS,
                 require_left_edge: bool = True,
                 start: Tuple[int, int] = (Q16_ONE // 2, Q16_ONE // 2)) -> None:
        self.alpha_low_q16 = int(alpha_low_q16)
        self.alpha_high_q16 = int(alpha_high_q16)
        self.z_low, self.z_high = int(z_low), int(z_high)
        self.z_engage, self.z_release = int(z_engage), int(z_release)
        self.max_step_q16 = max(0, int(max_step_q16))
        self.settle_ticks = max(0, int(settle_ticks))
        self.require_left_edge = bool(require_left_edge)
        self.cursor_x_q16, self.cursor_y_q16 = map(int, start)
        self.cursor_z = 0
        self.engaged = False
        self.anchor_valid = False
        self.anchor_x_q16 = 0
        self.anchor_y_q16 = 0
        self._filtered_x_q16: Optional[int] = None
        self._filtered_y_q16: Optional[int] = None
        self._previous_target_x_q16: Optional[int] = None
        self._previous_target_y_q16: Optional[int] = None
        self._filtered_z: Optional[int] = None
        self._history_x: list[int] = []
        self._history_y: list[int] = []
        self._history_z: list[int] = []
        self._last_raw_x: Optional[int] = None
        self._last_raw_y: Optional[int] = None
        self._settle_remaining = 0
        self._have_frame = False
        self._latest_stable: Optional[CursorPoint] = None
        self._last = CursorPoint(self.cursor_x_q16, self.cursor_y_q16, 0,
                                 self.cursor_y_q16, 0, 0, DISENGAGED, False,
                                 False, 0, 0)

    def _filtered(self, frame: CursorFrame) -> Tuple[int, int, int]:
        self._history_x.append(int(frame.x)); self._history_x = self._history_x[-5:]
        self._history_y.append(int(frame.y)); self._history_y = self._history_y[-5:]
        self._history_z.append(int(frame.z)); self._history_z = self._history_z[-5:]
        med_x, med_y, med_z = median5(self._history_x), median5(self._history_y), median5(self._history_z)
        if self._filtered_x_q16 is None:
            fx, fy = raw_to_q16(med_x), raw_to_q16(med_y)
        elif self._last_raw_x == int(frame.x) and self._last_raw_y == int(frame.y):
            # A depth-only vector must not move pitch, even when Z changes the
            # adaptive IIR coefficient.
            fx, fy = self._filtered_x_q16, self._filtered_y_q16
        else:
            a = alpha_q16(med_z, alpha_low_q16=self.alpha_low_q16,
                          alpha_high_q16=self.alpha_high_q16,
                          z_low=self.z_low, z_high=self.z_high)
            tx, ty = raw_to_q16(med_x), raw_to_q16(med_y)
            fx = self._filtered_x_q16 + ((tx - self._filtered_x_q16) * a >> 16)
            fy = self._filtered_y_q16 + ((ty - self._filtered_y_q16) * a >> 16)
        if self._filtered_z is None:
            fz = med_z
        else:
            a = alpha_q16(med_z, alpha_low_q16=self.alpha_low_q16,
                          alpha_high_q16=self.alpha_high_q16,
                          z_low=self.z_low, z_high=self.z_high)
            fz = self._filtered_z + ((med_z - self._filtered_z) * a >> 16)
        self._filtered_x_q16, self._filtered_y_q16, self._filtered_z = fx, fy, fz
        self._last_raw_x, self._last_raw_y = int(frame.x), int(frame.y)
        return fx, fy, fz

    def _controls(self, z: int, speed_q16: int) -> Tuple[int, int]:
        depth = clamp(((int(z) - self.z_low) * Q16_ONE) // max(1, self.z_high - self.z_low), 0, Q16_ONE)
        # Low/near hand is louder; movement contributes a bounded extra term.
        proximity = Q16_ONE - depth
        velocity = clamp((Q16_ONE // 2) + ((proximity * 7) // 16) + ((min(Q16_ONE, speed_q16) * 3) // 16), 0, Q16_ONE)
        return velocity, depth

    def push(self, frame: CursorFrame) -> CursorPoint:
        if frame.bad:
            self._last = CursorPoint(self.cursor_x_q16, self.cursor_y_q16, self.cursor_z,
                                     self.cursor_y_q16, self._last.velocity_q16,
                                     self._last.depth_q16, DEGRADED, False, False,
                                     int(frame.sequence) & 0xFFFF, int(frame.timestamp_ticks) & 0xFFFFFFFF,
                                     int(frame.reason))
            return self._last

        fx, fy, fz = self._filtered(frame)
        self.cursor_z = fz
        depth = clamp(((fz - self.z_low) * Q16_ONE) // max(1, self.z_high - self.z_low), 0, Q16_ONE)
        # Clutch thresholds use the current calibrated Z sample.  The XY/Z
        # IIR remains causal, but waiting for a damped Z value would delay the
        # freeze and allow a lifted frame to move the cursor.
        engagement_z = int(frame.z)
        if self.engaged and engagement_z > self.z_release:
            self.engaged = False
            self.anchor_valid = False  # frozen zone hides the anchor
            self._settle_remaining = 0
            vx, _ = self._controls(fz, 0)
            self._last = CursorPoint(self.cursor_x_q16, self.cursor_y_q16, self.cursor_z,
                                     self.cursor_y_q16, vx, depth, DISENGAGED, False,
                                     False, int(frame.sequence) & 0xFFFF,
                                     int(frame.timestamp_ticks) & 0xFFFFFFFF)
            return self._last

        if not self.engaged:
            # Initial arm uses the left edge. A post-lift rebase is z-only: the
            # current point becomes the hidden anchor and contributes zero motion.
            left_edge = (not self.require_left_edge) or bool(frame.left_edge) or fx <= Q16_ONE // 32
            if engagement_z < self.z_engage and (self._have_frame and (not self.anchor_valid) or left_edge):
                was_hidden = self._have_frame and not self.anchor_valid
                self.engaged = True
                self.anchor_valid = True
                self.anchor_x_q16, self.anchor_y_q16 = fx, fy
                self._previous_target_x_q16, self._previous_target_y_q16 = fx, fy
                self._settle_remaining = self.settle_ticks
                vx, _ = self._controls(fz, 0)
                self._last = CursorPoint(self.cursor_x_q16, self.cursor_y_q16, self.cursor_z,
                                         self.cursor_y_q16, vx, depth, REBASED if was_hidden else ENGAGED,
                                         was_hidden, False, int(frame.sequence) & 0xFFFF,
                                         int(frame.timestamp_ticks) & 0xFFFFFFFF)
                # Initial left-edge arm is an engage, not a rebase pulse.
                self._have_frame = True
                return self._last
            self._have_frame = True
            vx, _ = self._controls(fz, 0)
            self._last = CursorPoint(self.cursor_x_q16, self.cursor_y_q16, self.cursor_z,
                                     self.cursor_y_q16, vx, depth, DISENGAGED, False,
                                     False, int(frame.sequence) & 0xFFFF,
                                     int(frame.timestamp_ticks) & 0xFFFFFFFF)
            return self._last

        # Engaged path: integrate only XY relative motion. Z therefore cannot
        # create pitch or cursor displacement by itself.
        old_x, old_y = self._previous_target_x_q16, self._previous_target_y_q16
        dx, dy = fx - old_x, fy - old_y
        a = alpha_q16(fz, alpha_low_q16=self.alpha_low_q16,
                      alpha_high_q16=self.alpha_high_q16,
                      z_low=self.z_low, z_high=self.z_high)
        step_x, step_y = (dx * a) >> 16, (dy * a) >> 16
        if self._settle_remaining > 0:
            step_x = step_y = 0
            self._settle_remaining -= 1
        step_x = clamp(step_x, -self.max_step_q16, self.max_step_q16)
        step_y = clamp(step_y, -self.max_step_q16, self.max_step_q16)
        self.cursor_x_q16 = clamp(self.cursor_x_q16 + step_x, 0, Q16_ONE)
        self.cursor_y_q16 = clamp(self.cursor_y_q16 + step_y, 0, Q16_ONE)
        self._previous_target_x_q16, self._previous_target_y_q16 = fx, fy
        speed = max(abs(step_x), abs(step_y))
        velocity, depth = self._controls(fz, speed)
        self._have_frame = True
        self._last = CursorPoint(self.cursor_x_q16, self.cursor_y_q16, self.cursor_z,
                                 self.cursor_y_q16, velocity, depth, ENGAGED, False,
                                 True, int(frame.sequence) & 0xFFFF,
                                 int(frame.timestamp_ticks) & 0xFFFFFFFF)
        self._latest_stable = self._last
        return self._last

    def sample_ce(self) -> Optional[CursorPoint]:
        """Return the latest stable point; sample_ce never advances filter state."""
        return self._latest_stable

    @property
    def last(self) -> CursorPoint:
        return self._last


def process_frames(frames: Iterable[CursorFrame], **kwargs) -> list[CursorPoint]:
    filt = CursorFilter(**kwargs)
    return [filt.push(frame) for frame in frames]


__all__ = [name for name in globals() if not name.startswith("_")]
