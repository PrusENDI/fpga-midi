"""Protocol helpers for the temporary MGC3130 calibration capture path."""

from __future__ import annotations

from typing import Dict, List

SYNC = b"\xA5\x5A"
VERSION = 1
FRAME_TYPE_METADATA = 0
FRAME_TYPE_REPORT = 1
FRAME_LENGTH = 32


def crc8(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ 0x07) & 0xFF if value & 0x80 else (value << 1) & 0xFF
    return value


def encode_frame(frame_type: int, sequence: int, timestamp: int, flags: int,
                 x: int, y: int, z: int, gesture: int, error_code: int,
                 touch_info: int, *, build_tag: int = 0,
                 reserved: bytes = b"\x00\x00\x00") -> bytes:
    if len(reserved) != 3:
        raise ValueError("reserved must contain exactly three bytes")
    body = bytes((VERSION, frame_type, FRAME_LENGTH))
    body += int(sequence & 0xFFFF).to_bytes(2, "little")
    body += int(timestamp & 0xFFFFFFFF).to_bytes(4, "little")
    body += bytes((flags & 0xFF,))
    body += int(x & 0xFFFF).to_bytes(2, "little")
    body += int(y & 0xFFFF).to_bytes(2, "little")
    body += int(z & 0xFFFF).to_bytes(2, "little")
    body += bytes((gesture & 0xFF, error_code & 0xFF))
    body += int(touch_info & 0xFFFFFFFF).to_bytes(4, "little")
    body += int(build_tag & 0xFFFFFFFF).to_bytes(4, "little")
    body += reserved
    frame = SYNC + body + bytes((crc8(body),))
    if len(frame) != FRAME_LENGTH:
        raise AssertionError(f"frame length is {len(frame)}, expected {FRAME_LENGTH}")
    return frame


def _parse(frame: bytes) -> Dict[str, int]:
    if len(frame) != FRAME_LENGTH or frame[:2] != SYNC:
        raise ValueError("invalid frame")
    body = frame[2:-1]
    if frame[2] != VERSION or frame[4] != FRAME_LENGTH:
        raise ValueError("unsupported frame version or length")
    if crc8(body) != frame[-1]:
        raise ValueError("CRC mismatch")
    return {
        "version": frame[2],
        "frame_type": frame[3],
        "sequence": int.from_bytes(frame[5:7], "little"),
        "timestamp": int.from_bytes(frame[7:11], "little"),
        "flags": frame[11],
        "report_valid": bool(frame[11] & 0x01),
        "xyz_valid": bool(frame[11] & 0x02),
        "report_error": bool(frame[11] & 0x04),
        "touch_valid": bool(frame[11] & 0x08),
        "mgc_ready": bool(frame[11] & 0x10),
        "reader_busy": bool(frame[11] & 0x20),
        "capture_overflow": bool(frame[11] & 0x40),
        "x": int.from_bytes(frame[12:14], "little"),
        "y": int.from_bytes(frame[14:16], "little"),
        "z": int.from_bytes(frame[16:18], "little"),
        "gesture": frame[18],
        "error_code": frame[19],
        "touch_info": int.from_bytes(frame[20:24], "little"),
        "build_tag": int.from_bytes(frame[24:28], "little"),
        "reserved": frame[28:31],
        "crc": frame[31],
    }


def decode_frames(data: bytes) -> List[Dict[str, int]]:
    """Decode complete frames, skipping corrupt bytes and tracking gaps."""
    frames: List[Dict[str, int]] = []
    cursor = 0
    crc_errors = 0
    while True:
        start = data.find(SYNC, cursor)
        if start < 0 or len(data) - start < FRAME_LENGTH:
            break
        candidate = data[start:start + FRAME_LENGTH]
        if candidate[2] != VERSION or candidate[4] != FRAME_LENGTH:
            cursor = start + 1
            continue
        try:
            frame = _parse(candidate)
        except ValueError:
            crc_errors += 1
            cursor = start + 1
            continue
        if frames:
            frame["gap_before"] = (frame["sequence"] - frames[-1]["sequence"] - 1) & 0xFFFF
        else:
            frame["gap_before"] = 0
        frame["crc_errors"] = crc_errors
        frames.append(frame)
        cursor = start + FRAME_LENGTH
    return frames
