"""Frozen V2 FPGA wire contract serializers."""
from dataclasses import dataclass
import re

@dataclass(frozen=True)
class CSRDefinition:
    address: int
    access: str
    packing: str

    @property
    def write_mask(self) -> int:
        if self.access == "RO":
            return 0
        mask = 0
        for hi, lo in re.findall(r"\[(\d+)(?::(\d+))?\]", self.packing):
            upper, lower = int(hi), int(lo) if lo else int(hi)
            mask |= ((1 << (upper - lower + 1)) - 1) << lower
        if self.address == 0x08:  # BPM active half is readback only.
            mask = 0x0000FFFF
        return mask

    @property
    def field_shifts(self) -> dict[str, int]:
        return {name: int(lo) if lo else int(hi) for name, hi, lo in
                re.findall(r"([A-Za-z0-9_]+)\[(\d+)(?::(\d+))?\]", self.packing)}

@dataclass(frozen=True)
class ParameterDefinition:
    name: str
    family: int
    index: int
    q_format: str
    minimum: int
    maximum: int
    default: int
    scope: str

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
    ("PATCH_SELECT",0x48,"RW","family[1:0],track[4:2],index[15:8]"),
    ("PATCH_SHADOW_DATA",0x4C,"RW","value[31:0]"),
    ("PATCH_ACTIVE_DATA",0x50,"RO","value[31:0]"),
    ("PATCH_STATUS",0x54,"RO","active_version[15:0],shadow_dirty[16],crc_ok[17],apply_busy[18],last_error[31:24]"),
    ("PATCH_CRC",0x58,"RW","crc16_ccitt[15:0]"),
    ("PATCH_APPLY",0x5C,"WO","expected_version[15:0],trigger[31]"),
    ("WT_SELECT",0x60,"RW","table_id[2:0],bank[8],band[11:9],octave[15:12]"),
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

_patch_rows = (
    ("OSC_MIX","UQ0.16",0,65535,32768),("BRIGHTNESS","UQ0.16",0,65535,32768),
    ("DETUNE_CENTS","SQ8.8",-307200,307200,0),("ATTACK_MS","U16",0,10000,35),
    ("DECAY_MS","U16",0,10000,180),("SUSTAIN","UQ1.15",0,32767,23593),
    ("RELEASE_MS","U16",0,10000,520),("GLIDE_MS","U16",0,2000,85),
    ("VIBRATO_HZ","UQ8.8",0,3840,1075),("VIBRATO_CENTS","UQ8.8",0,25600,2816),
    ("Z_GAIN","UQ1.15",0,32767,0),("Z_BRIGHTNESS","UQ1.15",0,32767,0),
    ("Z_SPACE","UQ1.15",0,32767,0),("TRACK_ENABLE","U1",0,1,1),
    ("GAIN","UQ16.16",0,262144,65536),("FX_LEVEL","U8",0,3,0),
    ("FX_CUTOFF_HZ","U16",20,20000,12000),("FX_DELAY_MS","U16",0,1000,0),
    ("FX_FEEDBACK","UQ1.15",0,31129,0),("FX_REVERB_MIX","UQ1.15",0,32767,0),
)
_cal_rows = (
    ("NEUTRAL_X","S32",-32768,32767,0),("NEUTRAL_Y","S32",-32768,32767,0),
    ("NEUTRAL_Z","S32",0,65535,0),("COUPLING_X","SQ16.16",-262144,262144,0),
    ("COUPLING_Y","SQ16.16",-262144,262144,0),
    ("GAIN_X","UQ16.16",0,262144,65536),("GAIN_Y","UQ16.16",0,262144,65536),
    ("GAIN_Z","UQ16.16",0,262144,65536),
    ("WS_X_MIN","S32",-32768,32767,-32768),("WS_X_MAX","S32",-32768,32767,32767),
    ("WS_Y_MIN","S32",-32768,32767,-32768),("WS_Y_MAX","S32",-32768,32767,32767),
    ("WS_Z_MIN","S32",0,65535,0),("WS_Z_MAX","S32",0,65535,65535),
    ("EPOCH","U8",0,255,0),
)
_rule_rows = (
    ("LAMBDA_Q16","UQ16.16",0,1048576,65536),
    ("DENSITY_Q16","UQ0.16",0,65535,32768),
    ("MIN_LENGTH_TICKS","U8",1,128,4),
    ("REST_POLICY","ENUM",0,2,0),
    ("FIXED_SCALE_MASK","U12",1,4095,4095),
    ("BEND_CENTS","SQ8.8",-307200,307200,0),
    ("GATE_MODE","ENUM",0,4,0),
)
_cursor_rows = (
    ("ALPHA_Q16","UQ0.16",0,65535,32768),
    ("Z_ENGAGE","U16",0,65535,30000),
    ("Z_RELEASE","U16",0,65535,36000),
    ("MAX_STEP","U16",0,65535,4096),
    ("SETTLE_FRAMES","U8",0,255,3),
)
PATCH_PARAMETERS = {
    **{(0,index): ParameterDefinition(name,0,index,fmt,low,high,default,"track")
       for index,(name,fmt,low,high,default) in enumerate(_patch_rows)},
    **{(1,index): ParameterDefinition(name,1,index,fmt,low,high,default,"global")
       for index,(name,fmt,low,high,default) in enumerate(_cal_rows)},
    **{(2,index): ParameterDefinition(name,2,index,fmt,low,high,default,"track")
       for index,(name,fmt,low,high,default) in enumerate(_rule_rows)},
    **{(3,index): ParameterDefinition(name,3,index,fmt,low,high,default,"global")
       for index,(name,fmt,low,high,default) in enumerate(_cursor_rows)},
}

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
    **{f"V2_CSR_{name}_WRITE_MASK": definition.write_mask for name,definition in CSR.items() if not name.startswith("TEST_SELECT_")},
    "V2_CSR_TEST_SELECT_WRITE_MASK":0xFFFFFFFF,
    "V2_CSR_TEST_SELECT_SELECTOR_SHIFT":0,"V2_CSR_TEST_SELECT_VALUE_SHIFT":8,
    **{f"V2_CSR_{name}_{field.upper()}_SHIFT": shift
       for name,definition in CSR.items() if not name.startswith("TEST_SELECT_")
       for field,shift in definition.field_shifts.items()},
    **{f"V2_PARAM_{parameter.name}":parameter.index for parameter in PATCH_PARAMETERS.values()},
    "V2_FAMILY_PATCH":0,"V2_FAMILY_CALIBRATION":1,
    "V2_FAMILY_RULE":2,"V2_FAMILY_CURSOR":3,
    "V2_WT_A":0,"V2_WT_B":1,"V2_WT_C":2,"V2_WT_SAMPLES":1024,
    "V2_WT_BAND_BITS":3,"V2_WT_BAND_MAX":7,
    "V2_WT_OCTAVE_BITS":4,"V2_WT_OCTAVE_MAX":15,
    "V2_WT_BAND_DEFAULT":0,"V2_WT_OCTAVE_DEFAULT":0,
    "V2_LOOP_TICKS":128,"V2_TICKS_PER_BEAT":4,
    "V2_LOOP_BANKS":2,"V2_LOOP_TRACKS":6,"V2_LOOP_SLOTS_PER_TRACK":32,
    "V2_LOOP_SLOT_BITS":5,"V2_LOOP_COUNT_BITS":6,"V2_LOOP_TOTAL_SLOTS":192,
    "V2_VOICE_COUNT":32,"V2_OSCILLATORS_PER_VOICE":2,
    "V2_VOICE_STEAL_COUNTER_BITS":16,"V2_VOICE_STEAL_PRIORITY_COUNT":4,
    "V2_VOICE_STEAL_RELEASED":0,"V2_VOICE_STEAL_OLDEST":1,
    "V2_VOICE_STEAL_LOWEST_VELOCITY":2,"V2_VOICE_STEAL_LOWEST_VOICE_ID":3,
    "V2_TEST_SELECTOR_N_TONE":1,"V2_TEST_SELECTOR_VIBRATO_READBACK":2,
    "V2_TEST_N_TONE_COUNT_MIN":1,"V2_TEST_N_TONE_COUNT_MAX":32,
    "V2_TEST_N_TONE_COUNT_DEFAULT":8,
    "V2_VIBRATO_READBACK_PHASE_BITS":16,
    "V2_VIBRATO_READBACK_DELTA_CENTS_BITS":16,
    "V2_VIBRATO_READBACK_PHASE_SHIFT":0,
    "V2_VIBRATO_READBACK_DELTA_CENTS_SHIFT":16,
    "V2_VIBRATO_READBACK_PHASE_MASK":0x0000FFFF,
    "V2_VIBRATO_READBACK_DELTA_CENTS_MASK":0xFFFF0000,
    "V2_BPM_MIN":60,"V2_BPM_MAX":240,"V2_BPM_DEFAULT":120,
    "V2_PATCH_PARAM_COUNT":len(_patch_rows),"V2_CAL_PARAM_COUNT":len(_cal_rows),
    "V2_RULE_PARAM_COUNT":len(_rule_rows),"V2_CURSOR_PARAM_COUNT":len(_cursor_rows),
    "V2_ACK_SHADOW_STORED":5,"V2_ACK_APPLY_ACCEPTED":6,
    "V2_ERR_BAD_OP":6,"V2_ERR_BAD_DATA":7,"V2_ERR_VERSION":8,
    "V2_ERR_INCOMPLETE":9,"V2_ERR_WT_CRC":10,
    "V2_ERR_OVERFLOW":11,"V2_ERR_TIMEOUT":12,
    **{f"V2_PARAM_F{family}_I{index}_{suffix}": getattr(parameter, attr)
       for (family,index),parameter in PATCH_PARAMETERS.items()
       for suffix,attr in (("MIN","minimum"),("MAX","maximum"),("DEFAULT","default"))},
    **{f"V2_PARAM_F{family}_I{index}_Q_CODE": (4 if parameter.q_format.startswith("UQ") else 3 if parameter.q_format.startswith("SQ") else 1)
       for (family,index),parameter in PATCH_PARAMETERS.items()},
    **{f"V2_PARAM_F{family}_I{index}_GLOBAL": int(parameter.scope == "global")
       for (family,index),parameter in PATCH_PARAMETERS.items()},
}
globals().update(SV_CONSTANTS)

# Ordered tie-break policy for deterministic 33rd-note allocation.  These
# names intentionally remain a Python tuple rather than a packed wire field;
# the individual enum values above are mirrored in v2_contract_pkg.sv.
V2_VOICE_STEAL_PRIORITY = (
    V2_VOICE_STEAL_RELEASED,
    V2_VOICE_STEAL_OLDEST,
    V2_VOICE_STEAL_LOWEST_VELOCITY,
    V2_VOICE_STEAL_LOWEST_VOICE_ID,
)

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

def encode_patch_select(family: int, track: int, index: int) -> int:
    parameter = PATCH_PARAMETERS.get((family, index))
    if parameter is None:
        raise ValueError("unknown indexed parameter")
    if not isinstance(track, int) or not 0 <= track <= 7 or (parameter.scope == "global" and track != 7):
        raise ValueError("invalid selector track")
    if parameter.scope == "track" and track >= 6:
        raise ValueError("track parameter requires track 0..5")
    return family | (track << 2) | (index << 8)

def validate_patch_value(family: int, track: int, index: int, value: int) -> int:
    encode_patch_select(family, track, index)
    definition = PATCH_PARAMETERS[(family, index)]
    if not isinstance(value, int) or not definition.minimum <= value <= definition.maximum:
        raise ValueError(f"{definition.name} outside frozen range")
    return value & 0xFFFFFFFF

def patch_wire_to_value(family: int, index: int, wire_value: int) -> int:
    definition = PATCH_PARAMETERS[(family, index)]
    wire_value &= 0xFFFFFFFF
    return wire_value - 0x100000000 if definition.q_format.startswith("S") else wire_value

def patch_value_to_wire(family: int, index: int, value: int) -> int:
    validate_patch_value(family, 7 if PATCH_PARAMETERS[(family,index)].scope == "global" else 0, index, value)
    return value & 0xFFFFFFFF

def default_patch_values() -> dict[tuple[int, int, int], int]:
    values = {}
    for (family,index),definition in PATCH_PARAMETERS.items():
        for track in (range(6) if definition.scope == "track" else (7,)):
            values[(family,track,index)] = definition.default
    return values

def patch_shadow_crc(values: dict[tuple[int, int, int], int], family: int, track: int) -> int:
    encode_patch_select(family, track, 0)
    expected = {key: value for key,value in default_patch_values().items()
                if key[0] == family and key[1] == track}
    if values.keys() != expected.keys():
        raise ValueError("incomplete indexed shadow parameter set")
    body = bytearray()
    for family,track,index in sorted(expected):
        body += validate_patch_value(family, track, index, values[(family,track,index)]).to_bytes(4,"big")
    return crc16_ccitt(body)

def validate_wavetable_upload(table_id: int, samples: list[int], covered: set[int],
                              expected_crc: int, apply_version: int, active_version: int) -> None:
    if table_id not in (V2_WT_A,V2_WT_B,V2_WT_C):
        raise ValueError("invalid wavetable ID")
    if len(samples) != V2_WT_SAMPLES or covered != set(range(V2_WT_SAMPLES)):
        raise ValueError("incomplete wavetable coverage")
    if apply_version != active_version:
        raise ValueError("wavetable version mismatch")
    payload = b"".join(_s(sample,16,"sample").to_bytes(2,"big") for sample in samples)
    if crc16_ccitt(payload) != expected_crc:
        raise ValueError("wavetable CRC mismatch")

def encode_wavetable_select(table_id: int, bank: int, band: int, octave: int) -> int:
    """Pack the frozen WT_SELECT table/bank/band/octave selector."""
    if table_id not in (V2_WT_A, V2_WT_B, V2_WT_C):
        raise ValueError("invalid wavetable ID")
    if bank not in (0, 1):
        raise ValueError("wavetable bank must be 0 or 1")
    if not 0 <= band <= V2_WT_BAND_MAX:
        raise ValueError("wavetable band outside frozen range")
    if not 0 <= octave <= V2_WT_OCTAVE_MAX:
        raise ValueError("wavetable octave outside frozen range")
    return table_id | (bank << 8) | (band << 9) | (octave << 12)

def decode_wavetable_select(value: int) -> dict[str, int]:
    """Decode a WT_SELECT word and reject reserved bits."""
    value = _u(value, 32, "WT_SELECT")
    if value & ~CSR["WT_SELECT"].write_mask:
        raise ValueError("WT_SELECT reserved bits must be zero")
    return {
        "table_id": value & 0x7,
        "bank": (value >> 8) & 0x1,
        "band": (value >> 9) & 0x7,
        "octave": (value >> 12) & 0xF,
    }

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

def encode_control(op: int, address: int, data: int, seq: int,
                   indexed_selector: tuple[int, int, int] | None = None) -> bytes:
    op, address, seq = _u(op, 8, "op"), _u(address, 8, "address"), _u(seq, 8, "sequence")
    if indexed_selector and address == V2_CSR_PATCH_SHADOW_DATA:
        family, _, index = indexed_selector
        data = patch_value_to_wire(family, index, data)
    else:
        data = _u(data, 32, "data")
    if not is_valid_address(address):
        raise ValueError(f"address 0x{address:02X} is outside the frozen V2 map")
    _validate_operation(op, address, data, indexed_selector)
    body = bytes([SOF_CONTROL, VERSION, op, address, seq]) + data.to_bytes(4, "big")
    return body + crc16_ccitt(body).to_bytes(2, "big")

def decode_control(frame: bytes, indexed_selector: tuple[int, int, int] | None = None) -> dict:
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
        _validate_operation(frame[2], frame[3], int.from_bytes(frame[5:9], "big"), indexed_selector)
    except ValueError as exc:
        raise ControlPacketError(str(exc)) from exc
    return {"op": frame[2], "address": frame[3], "sequence": frame[4], "data": int.from_bytes(frame[5:9], "big")}

def _validate_operation(op: int, address: int, data: int,
                        indexed_selector: tuple[int, int, int] | None = None) -> None:
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
        register = next(reg for reg in CSR.values() if reg.address == address)
        if data & ~register.write_mask:
            raise ValueError("reserved write bits must be zero")
        if address == V2_CSR_MODE and data > 5:
            raise ValueError("invalid V2 mode")
        if address == V2_CSR_TRACK and data > 5:
            raise ValueError("invalid track")
        if address == V2_CSR_BPM and not 60 <= data <= 240:
            raise ValueError("BPM must be 60..240")
        if address == V2_CSR_PATCH_SELECT:
            encode_patch_select(data & 3, (data >> 2) & 7, (data >> 8) & 255)
        if address == V2_CSR_PATCH_SHADOW_DATA:
            if indexed_selector is None:
                raise ValueError("indexed PATCH_SHADOW_DATA requires selector context")
            family, track, index = indexed_selector
            validate_patch_value(family, track, index, patch_wire_to_value(family, index, data))
        if address == V2_CSR_WT_SELECT and (data & 7) > V2_WT_C:
            raise ValueError("invalid wavetable ID")
        if address == V2_CSR_WT_INDEX and data >= V2_WT_SAMPLES:
            raise ValueError("wavetable index outside 1024 samples")
        if address == V2_CSR_WT_LENGTH and data != V2_WT_SAMPLES:
            raise ValueError("wavetable length must be 1024")
        if address in (V2_CSR_PATCH_APPLY,V2_CSR_WT_APPLY) and not (data & 0x80000000):
            raise ValueError("APPLY trigger bit missing")
        if address in (V2_CSR_PLAY,V2_CSR_STOP,V2_CSR_RECORD,V2_CSR_OVERDUB,
                       V2_CSR_CLEAR_ALL,V2_CSR_COMMIT,V2_CSR_RESET) and data != 1:
            raise ValueError("trigger register requires bit zero set")
        if address == V2_CSR_THRESHOLDS and not (data & 0xFFFF) < (data >> 16):
            raise ValueError("engage threshold must be below release threshold")
        if address == V2_CSR_PATCH_CRC and data > 0xFFFF:
            raise ValueError("patch CRC is 16-bit")
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
    if event.type not in range(V2_EV_NOTE_ON, V2_EV_BOUNDARY + 1):
        raise ValueError("reserved event type")
    if event.flags & 0xC0:
        raise ValueError("reserved event flag bits")
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
