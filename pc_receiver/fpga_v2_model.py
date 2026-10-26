"""Offline-safe V2 parameter, transport and telemetry model.

This module deliberately has no serial or FPGA dependency.  The hardware wire
format remains owned by :mod:`tools.v2_contract`; the model only assembles
validated control frames and decodes the same telemetry bytes used by V2.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field, replace
from typing import Mapping

from tools.v2_contract import (
    CSR, V2_CSR_WT_APPLY, V2_CSR_WT_CRC, V2_CSR_WT_DATA,
    V2_CSR_WT_INDEX, V2_CSR_WT_LENGTH, V2_CSR_WT_SELECT,
    V2_CSR_WT_VERSION, V2_OP_WRITE, V2_TELEMETRY_BYTES,
    V2_TELEMETRY_SOF, VERSION, V2Telemetry, crc16_ccitt,
    PATCH_PARAMETERS, encode_control, encode_telemetry, validate_patch_value,
)


class V2ProtocolError(ValueError):
    """A frame is not a valid V2 telemetry packet."""


@dataclass(frozen=True)
class V2Parameters:
    mode: int = 0
    bpm: int = 120
    track: int = 0
    gate: int = 0
    lambda_q16: int = 65536
    density_q16: int = 32768
    fixed_scale_mask: int = 4095
    bend_cents: int = 0
    z_gain: int = 0
    z_brightness: int = 0
    z_space: int = 0
    fx_level: int = 0
    fx_cutoff_hz: int = 12000
    fx_delay_ms: int = 0
    fx_feedback: int = 0
    fx_reverb_mix: int = 0
    patch: Mapping[tuple[int, int, int], int] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.patch:
            from tools.v2_contract import default_patch_values
            object.__setattr__(self, "patch", default_patch_values())


_LIMITS = {
    "mode": (0, 5), "bpm": (60, 240), "track": (0, 5), "gate": (0, 4),
    "lambda_q16": (0, 1048576), "density_q16": (0, 65535),
    "fixed_scale_mask": (1, 4095), "bend_cents": (-307200, 307200),
    "z_gain": (0, 32767), "z_brightness": (0, 32767),
    "z_space": (0, 32767), "fx_level": (0, 3),
    "fx_cutoff_hz": (20, 20000), "fx_delay_ms": (0, 1000),
    "fx_feedback": (0, 31129), "fx_reverb_mix": (0, 32767),
}


def _clamp(value: int, low: int, high: int) -> int:
    if not isinstance(value, int):
        raise TypeError("V2 parameter values must be integers")
    return max(low, min(high, value))


def apply_patch_delta(parameters: V2Parameters,
                      delta: Mapping[object, object]) -> V2Parameters:
    """Return a new parameter snapshot with contract-range values clamped.

    Scalar controls use their public field names.  Indexed patch updates use
    ``(family, track, index)`` keys or a ``patch`` mapping.  The input object is
    never modified, which makes it safe to hand snapshots to a Tk queue.
    """
    values = {name: getattr(parameters, name) for name in _LIMITS}
    patch = dict(parameters.patch)
    for key, value in delta.items():
        if key == "patch":
            if not isinstance(value, Mapping):
                raise TypeError("patch delta must be a mapping")
            patch_updates = value.items()
        elif isinstance(key, tuple) and len(key) == 3:
            patch_updates = ((key, value),)
        elif key in _LIMITS:
            if not isinstance(value, int):
                raise TypeError(f"{key} must be an integer")
            low, high = _LIMITS[key]
            values[key] = _clamp(value, low, high)
            continue
        else:
            raise KeyError(f"unknown V2 parameter {key!r}")
        for selector, patch_value in patch_updates:
            try:
                family, track, index = selector
                definition = PATCH_PARAMETERS[(family, index)]
                low, high = definition.minimum, definition.maximum
                patch[(family, track, index)] = _clamp(patch_value, low, high)
                validate_patch_value(family, track, index, patch[(family, track, index)])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError(f"invalid patch selector {selector!r}") from exc
    return replace(parameters, **values, patch=patch)


def decode_telemetry(frame: bytes) -> V2Telemetry:
    if len(frame) != V2_TELEMETRY_BYTES:
        raise V2ProtocolError("telemetry frame must be 22 bytes")
    if frame[0] != V2_TELEMETRY_SOF or frame[1] != VERSION:
        raise V2ProtocolError("invalid telemetry SOF or version")
    expected = int.from_bytes(frame[-2:], "big")
    if crc16_ccitt(frame[:-2]) != expected:
        raise V2ProtocolError("telemetry CRC mismatch")
    return V2Telemetry(
        type=frame[2], sequence=int.from_bytes(frame[3:5], "big"),
        x=int.from_bytes(frame[5:7], "big", signed=True),
        y=int.from_bytes(frame[7:9], "big", signed=True),
        z=int.from_bytes(frame[9:11], "big", signed=True),
        note=frame[11], flags=frame[12], tick=frame[13],
        voice_bitmap=int.from_bytes(frame[14:18], "big"),
        fifo_level=frame[18], fault_code=frame[19],
    )


def build_upload(table_id: int, samples: list[int], version: int,
                 start_sequence: int = 0) -> list[bytes]:
    """Build the frozen 1024-sample shadow upload and APPLY sequence."""
    if table_id not in (0, 1, 2):
        raise ValueError("invalid wavetable ID")
    if len(samples) != 1024:
        raise ValueError("wavetable requires exactly 1024 samples")
    if not 0 <= version <= 0xFFFF or not 0 <= start_sequence <= 0xFF:
        raise ValueError("version or sequence outside wire range")
    payload = bytearray()
    for sample in samples:
        if not isinstance(sample, int) or not -32768 <= sample <= 32767:
            raise ValueError("wavetable samples must be signed 16-bit")
        payload += (sample & 0xFFFF).to_bytes(2, "big")

    frames: list[bytes] = []
    sequence = start_sequence

    def write(address: int, data: int) -> None:
        nonlocal sequence
        frames.append(encode_control(V2_OP_WRITE, address, data, sequence))
        sequence = (sequence + 1) & 0xFF

    write(CSR["WT_SELECT"].address, table_id)
    for block in range(32):
        write(V2_CSR_WT_INDEX, block * 32)
        for index in range(block * 32, block * 32 + 32):
            write(V2_CSR_WT_DATA, samples[index] & 0xFFFF)
    write(V2_CSR_WT_LENGTH, 1024)
    write(V2_CSR_WT_CRC, crc16_ccitt(bytes(payload)))
    write(V2_CSR_WT_VERSION, version)
    write(V2_CSR_WT_APPLY, 0x80000000 | version)
    return frames


class FakeTransport:
    """Deterministic transport for UI tests and offline telemetry replay."""

    def __init__(self) -> None:
        self.sent: list[bytes] = []
        self._received: deque[bytes] = deque()

    def send(self, frame: bytes) -> None:
        if not isinstance(frame, bytes):
            raise TypeError("transport frames must be bytes")
        self.sent.append(frame)

    def inject_telemetry(self, frame: bytes | V2Telemetry) -> None:
        self._received.append(encode_telemetry(frame) if isinstance(frame, V2Telemetry) else frame)

    def recv(self) -> V2Telemetry | None:
        return decode_telemetry(self._received.popleft()) if self._received else None
