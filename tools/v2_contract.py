"""Frozen V2 FPGA wire contract serializers."""
from dataclasses import dataclass

SOF_CONTROL = 0xA5
SOF_TELEMETRY = 0x5A
VERSION = 0x02
CONTROL_LENGTH = 11
TELEMETRY_LENGTH = 22
EVENT_BITS = 96

class ControlPacketError(ValueError):
    pass

def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

def is_valid_address(address: int) -> bool:
    return (0x00 <= address <= 0x44 or 0x48 <= address <= 0x5C or
            0x60 <= address <= 0x7C or 0x80 <= address <= 0x9C or
            0xA0 <= address <= 0xAF)

def _u(value: int, bits: int, name: str) -> int:
    if not isinstance(value, int) or not 0 <= value < (1 << bits):
        raise ValueError(f"{name} must be an unsigned {bits}-bit integer")
    return value

def _s(value: int, bits: int, name: str) -> int:
    if not isinstance(value, int) or not -(1 << (bits - 1)) <= value < (1 << (bits - 1)):
        raise ValueError(f"{name} must be a signed {bits}-bit integer")
    return value & ((1 << bits) - 1)

def encode_control(op: int, address: int, data: int, seq: int) -> bytes:
    op, address, data, seq = _u(op, 8, "op"), _u(address, 8, "address"), _u(data, 32, "data"), _u(seq, 8, "sequence")
    if not is_valid_address(address):
        raise ValueError(f"address 0x{address:02X} is outside the frozen V2 map")
    body = bytes([SOF_CONTROL, VERSION, op, address, seq]) + data.to_bytes(4, "big")
    return body + crc16_ccitt(body).to_bytes(2, "big")

def decode_control(frame: bytes) -> dict:
    if len(frame) != CONTROL_LENGTH:
        raise ControlPacketError(f"control frame must be {CONTROL_LENGTH} bytes")
    if frame[0] != SOF_CONTROL or frame[1] != VERSION:
        raise ControlPacketError("invalid control SOF or version")
    if not is_valid_address(frame[3]):
        raise ControlPacketError(f"address 0x{frame[3]:02X} is outside the frozen V2 map")
    expected = crc16_ccitt(frame[:-2])
    actual = int.from_bytes(frame[-2:], "big")
    if actual != expected:
        raise ControlPacketError("control CRC mismatch")
    return {"op": frame[2], "address": frame[3], "sequence": frame[4], "data": int.from_bytes(frame[5:9], "big")}

@dataclass(frozen=True)
class V2Event:
    type: int
    track: int
    tick: int
    duration: int
    note: int
    velocity: int
    pitch_mod: int
    timbre_mod: int
    flags: int
    sequence: int

@dataclass(frozen=True)
class V2Telemetry:
    type: int
    sequence: int
    x: int
    y: int
    z: int
    note: int
    flags: int
    tick: int
    voice_bitmap: int
    fifo_level: int
    fault_code: int

def encode_event(event: V2Event) -> bytes:
    value = 0
    value = (value << 1)  # reserved MSB, frozen to zero
    value = (value << 4) | _u(event.type, 4, "type")
    value = (value << 3) | _u(event.track, 3, "track")
    for name in ("tick", "duration", "note", "velocity"):
        value = (value << 8) | _u(getattr(event, name), 8, name)
    value = (value << 16) | _s(event.pitch_mod, 16, "pitch_mod")
    value = (value << 16) | _u(event.timbre_mod, 16, "timbre_mod")
    value = (value << 8) | _u(event.flags, 8, "flags")
    value = (value << 16) | _u(event.sequence, 16, "sequence")
    assert value.bit_length() <= EVENT_BITS
    return value.to_bytes(12, "big")

def encode_telemetry(snapshot: V2Telemetry) -> bytes:
    body = bytes([SOF_TELEMETRY, VERSION, _u(snapshot.type, 8, "type")])
    body += _u(snapshot.sequence, 16, "sequence").to_bytes(2, "big")
    for name in ("x", "y", "z"):
        body += _s(getattr(snapshot, name), 16, name).to_bytes(2, "big")
    body += bytes([_u(snapshot.note, 8, "note"), _u(snapshot.flags, 8, "flags"), _u(snapshot.tick, 8, "tick")])
    body += _u(snapshot.voice_bitmap, 32, "voice_bitmap").to_bytes(4, "big")
    body += bytes([_u(snapshot.fifo_level, 8, "fifo_level"), _u(snapshot.fault_code, 8, "fault_code")])
    assert len(body) == 20
    return body + crc16_ccitt(body).to_bytes(2, "big")
