"""Small independent Task 9 reference for patch validation and bounded FX."""

from dataclasses import dataclass, replace

from tools.v2_contract import PATCH_PARAMETERS, crc16_ccitt, patch_value_to_wire


@dataclass
class FxParameters:
    gain_q16: int = 65536
    cutoff_hz: int = 12000
    delay_samples: int = 0
    feedback_q15: int = 0
    reverb_mix_q15: int = 0
    z_gain_q15: int = 0
    z_brightness_q15: int = 0
    z_space_q15: int = 0


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, int(value)))


def clamp_fx_parameters(params: FxParameters) -> FxParameters:
    return replace(
        params,
        gain_q16=_clamp(params.gain_q16, 0, 262144),
        cutoff_hz=_clamp(params.cutoff_hz, 20, 20000),
        delay_samples=_clamp(params.delay_samples, 0, 1023),
        feedback_q15=_clamp(params.feedback_q15, 0, 31129),
        reverb_mix_q15=_clamp(params.reverb_mix_q15, 0, 32767),
        z_gain_q15=_clamp(params.z_gain_q15, 0, 32767),
        z_brightness_q15=_clamp(params.z_brightness_q15, 0, 32767),
        z_space_q15=_clamp(params.z_space_q15, 0, 32767),
    )


class PatchBank:
    def __init__(self):
        self.values = {}
        for (family, index), definition in PATCH_PARAMETERS.items():
            tracks = range(6) if definition.scope == "track" else (7,)
            for track in tracks:
                self.values[(family, track, index)] = definition.default


def apply_patch_value(bank: PatchBank, family: int, track: int, index: int, value: int) -> None:
    definition = PATCH_PARAMETERS.get((family, index))
    if definition is None:
        raise ValueError("unknown patch parameter")
    if definition.scope == "global" and track != 7:
        raise ValueError("global patch requires track 7")
    if definition.scope == "track" and not 0 <= track < 6:
        raise ValueError("track patch requires track 0..5")
    if not definition.minimum <= value <= definition.maximum:
        raise ValueError(f"{definition.name} outside frozen range")
    bank.values[(family, track, index)] = int(value)


def crc16_samples(samples: list[int]) -> int:
    payload = b"".join((int(sample) & 0xFFFF).to_bytes(2, "big") for sample in samples)
    return crc16_ccitt(payload)


def patch_bank_crc(bank: PatchBank, family: int, track: int) -> int:
    values = []
    for (candidate_family, candidate_index), definition in sorted(PATCH_PARAMETERS.items()):
        if candidate_family != family:
            continue
        key = (family, track, candidate_index)
        if key not in bank.values:
            raise ValueError("incomplete patch bank")
        values.append(patch_value_to_wire(family, candidate_index, bank.values[key]).to_bytes(4, "big"))
    return crc16_ccitt(b"".join(values))
