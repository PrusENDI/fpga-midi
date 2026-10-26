"""Frozen V2 FPGA wire contract serializers."""
from dataclasses import dataclass

@dataclass(frozen=True)
class CSRDefinition:
    address: int
    access: str
    packing: str

# Machine-readable address and 32-bit data contract. Unassigned word offsets are invalid.
_csr_rows = (
    ("STATUS",0x00,"RO","mode[2:0],active_valid[8],fault[9]"),
    ("MODE",0x04,"RW","mode[2:0]"), ("BPM",0x08,"RW","active_bpm[31:16],shadow_bpm[15:0]"),
    ("TRACK",0x0C,"RW","track[2:0]"),
    ("PLAY",0x10,"WO","trigger[0]"), ("STOP",0x14,"WO","trigger[0]"),
    ("RECORD",0x18,"WO","trigger[0]"), ("OVERDUB",0x1C,"WO","trigger[0]"),
    ("CLEAR_TRACK",0x20,"WO","track[2:0],trigger[8]"),
    ("CLEAR_ALL",0x24,"WO","trigger[0]"), ("COMMIT",0x28,"WO","trigger[0]"),
    ("RESET",0x2C,"WO","trigger[0]"),
    ("THRESHOLDS",0x30,"RW","release[31:16],engage[15:0]"),
    ("POSITION",0x34,"RO","tick[7:0],active_valid[8],commit_pending[9],fault[10]"),
    ("FAULT",0x38,"RO","fault_code[7:0],sticky[8]"),
    ("DIAG_INPUT",0x3C,"RO","invalid_count[15:0],gap_count[31:16]"),
    ("DIAG_AUDIO",0x40,"RO","underrun_count[15:0],peak_q15[31:16]"),
    ("DIAG_ROUTER",0x44,"RO","drop_count[15:0],fifo_level[23:16]"),
    ("PATCH_SELECT",0x48,"RW","patch_id[7:0],track[10:8]"),
    ("PATCH_GAIN",0x4C,"RW","gain_q16_16[31:0]"),
    ("PATCH_BRIGHTNESS",0x50,"RW","brightness_q16_16[31:0]"),
    ("GESTURE",0x54,"RW","touch_threshold[15:0],bow_threshold[31:16]"),
    ("FX",0x58,"RW","fx_level[7:0],mix_q8[15:8],feedback_q8[23:16]"),
    ("PATCH_APPLY",0x5C,"WO","expected_version[15:0],trigger[31]"),
    ("WT_SELECT",0x60,"RW","table_id[7:0],bank[8]"),
    ("WT_INDEX",0x64,"RW","sample_index[15:0]"),
    ("WT_DATA",0x68,"RW","sample_s16[15:0]"),
    ("WT_LENGTH",0x6C,"RW","sample_count[15:0]"),
    ("WT_CRC",0x70,"RW","crc16_ccitt[15:0]"),
    ("WT_VERSION",0x74,"RW","expected_version[15:0]"),
    ("WT_APPLY",0x78,"WO","expected_version[15:0],trigger[31]"),
    ("WT_STATUS",0x7C,"RO","active_version[15:0],shadow_valid[16],apply_busy[17],last_error[31:24]"),
    ("TLM_CONTROL",0x80,"RW","enable[0],period_ms[31:16]"),
    ("TLM_STATUS",0x84,"RO","last_type[7:0],sequence[23:8]"),
    ("TLM_LATENCY",0x88,"RO","latency_us[31:0]"),
    ("TLM_PEAK",0x8C,"RO","peak_q15[15:0]"),
    ("TLM_RMS",0x90,"RO","rms_q15[15:0]"),
    ("TLM_FIFO",0x94,"RO","rx_level[7:0],tx_level[15:8],event_level[23:16]"),
    ("TLM_FAULT",0x98,"RO","fault_code[7:0],fault_count[31:8]"),
    ("TLM_TABLE_VERSION",0x9C,"RO","active_version[15:0],shadow_version[31:16]"),
)
CSR = {name: CSRDefinition(address, access, packing) for name,address,access,packing in _csr_rows}
for _index in range(16):
    CSR[f"TEST_SELECT_{_index:X}"] = CSRDefinition(0xA0 + _index,"RW","selector[7:0],value[31:8]")

SV_CONSTANTS = {
    "V2_VERSION":0x02,"V2_CONTROL_SOF":0xA5,"V2_TELEMETRY_SOF":0x5A,
    "V2_EVENT_BITS":96,"V2_CONTROL_BYTES":11,"V2_TELEMETRY_BYTES":22,
    "V2_RESPONSE_TIMEOUT_MS":1000,"V2_BOUNDARY_TIMEOUT_MS":34000,
    **{f"V2_CSR_{name}": definition.address for name, definition in CSR.items() if not name.startswith("TEST_SELECT_")},
    "V2_CSR_TEST_SELECT":0xA0,
    "V2_EV_NOTE_ON":1,"V2_EV_NOTE_OFF":2,"V2_EV_REVOICE":3,
    "V2_EV_CONTROL":4,"V2_EV_ALL_NOTES_OFF":5,"V2_EV_BOUNDARY":6,
    "V2_FLAG_TOUCH":1,"V2_FLAG_BOW":2,"V2_FLAG_Z":4,
    "V2_FLAG_REBASED":8,"V2_FLAG_DEGRADED":16,"V2_FLAG_GAP":32,
    "V2_FAULT_NONE":0,"V2_FAULT_INVALID":1,"V2_FAULT_REVERSE":2,
    "V2_FAULT_FIFO":3,"V2_FAULT_TICK":4,"V2_FAULT_OVERFLOW":5,"V2_FAULT_ABORT":6,
    "V2_OP_READ":1,"V2_OP_WRITE":2,"V2_OP_PING":3,
    "V2_ACK_ACCEPTED":0,"V2_ACK_APPLIED":1,"V2_ACK_REJECTED":2,
    "V2_ACK_BUSY":3,"V2_ACK_ERROR":4,
    "V2_TLM_SNAPSHOT":1,"V2_TLM_STATS":2,"V2_TLM_TABLE":3,
    "V2_TLM_ACK":0x80,"V2_TLM_NACK":0x81,
    "V2_ERR_NONE":0,"V2_ERR_BAD_CRC":1,"V2_ERR_BAD_ADDRESS":2,
    "V2_ERR_BAD_VERSION":3,"V2_ERR_BAD_LENGTH":4,"V2_ERR_SEQUENCE":5,
    "V2_ACCESS_NONE":0,"V2_ACCESS_RO":1,"V2_ACCESS_WO":2,"V2_ACCESS_RW":3,
}
globals().update(SV_CONSTANTS)

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
    return any(register.address == address for register in CSR.values())

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
    _validate_operation(op, address, data)
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
    try:
        _validate_operation(frame[2], frame[3], int.from_bytes(frame[5:9], "big"))
    except ValueError as exc:
        raise ControlPacketError(str(exc)) from exc
    return {"op": frame[2], "address": frame[3], "sequence": frame[4], "data": int.from_bytes(frame[5:9], "big")}

def _validate_operation(op: int, address: int, data: int) -> None:
    if op == V2_OP_PING:
        if address != V2_CSR_STATUS or data != 0:
            raise ValueError("PING requires STATUS address and zero data")
        return
    access = next(reg.access for reg in CSR.values() if reg.address == address)
    if op == V2_OP_READ and access in ("RO", "RW"):
        if data != 0:
            raise ValueError("READ data must be zero")
        return
    if op == V2_OP_WRITE and access in ("WO", "RW"):
        return
    raise ValueError("invalid op or CSR access")

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
