"""Generate the Task 4 file-driven cursor replay from the Task 3 vectors."""
from pathlib import Path

from tools.v2_cursor_reference import CursorFilter, CursorFrame, DISENGAGED, ENGAGED, REBASED, DEGRADED, q16_to_u16

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools" / "testdata" / "v2_input" / "replay_fast_01.vec"
OUTPUT = ROOT / "tools" / "testdata" / "v2_input" / "cursor_replay_fast_01.vec"
STATE_CODE = {DISENGAGED: 0, ENGAGED: 1, REBASED: 2, DEGRADED: 3}

def u17(value: int) -> int:
    return value & 0x1FFFF

def s32(value: int) -> int:
    return value & 0xFFFFFFFF

def main() -> None:
    filt = CursorFilter(settle_ticks=2)
    audio = None
    stable_wire = 0
    rows = []
    with SOURCE.open() as source:
        for index, line in enumerate(source):
            fields = line.split()
            if len(fields) < 19:
                continue
            seq = int(fields[0], 16)
            sensor_x = (int(fields[2], 16) + 32768) & 0xFFFF
            sensor_y = (int(fields[3], 16) + 32768) & 0xFFFF
            sensor_z = int(fields[4], 16) & 0xFFFF
            valid_xyz = bool(int(fields[6]))
            saturated = bool(int(fields[7]))
            gap = bool(int(fields[8]))
            cal_x = int(fields[10], 16); cal_y = int(fields[11], 16); cal_z = int(fields[12], 16)
            cal_x = cal_x - (1 << 32) if cal_x & (1 << 31) else cal_x
            cal_y = cal_y - (1 << 32) if cal_y & (1 << 31) else cal_y
            cal_z = cal_z - (1 << 32) if cal_z & (1 << 31) else cal_z
            frame_valid = bool(int(fields[13])); degraded = bool(int(fields[15]))
            reason = int(fields[17], 16)
            timestamp_source = int(fields[1], 16)
            # Keep left-edge explicit in the file.  The capture has no SDK
            # left-edge field; x=0 also exercises the mapped-edge arm path.
            left_edge = index == 0
            sample_ce = (index % 7 == 3) or index in (967, 968, 969, 970)
            frame = CursorFrame(cal_x, cal_y, cal_z, valid=frame_valid,
                                valid_xyz=valid_xyz, saturated=saturated, gap=gap,
                                reason=reason, degraded=degraded, left_edge=left_edge,
                                sequence=seq, timestamp_ticks=timestamp_source)
            if sample_ce and filt.sample_ce() is not None:
                p = filt.sample_ce()
                audio = (p.x, p.y, p.z, p.normalized_pitch_q16, p.velocity_q16,
                         p.depth_q16, p.sequence, p.timestamp_ticks, 1)
            elif audio is None:
                audio = (0, 0, 0, 0, 0, 0, 0, 0, 0)
            point = filt.push(frame)
            if point.state == ENGAGED and point.stable:
                stable_wire = 1
            elif point.state == REBASED:
                stable_wire = 0
            rows.append((seq, sensor_x, sensor_y, sensor_z, int(valid_xyz), int(saturated),
                         int(gap), int(left_edge), int(sample_ce), point, audio, stable_wire))
    with OUTPUT.open("w") as out:
        for seq, sx, sy, sz, valid, sat, gap, edge, sample_ce, p, audio, stable_wire in rows:
            ax, ay, az, ap, av, ad, aseq, ats, aval = audio
            out.write(
                f"{seq:04X} {sx:04X} {sy:04X} {sz:04X} {valid:d} {sat:d} {gap:d} {edge:d} {sample_ce:d} "
                f"{s32(p.x):08X} {s32(p.y):08X} {s32(p.z):08X} {q16_to_u16(p.normalized_pitch_q16):04X} "
                f"{q16_to_u16(p.velocity_q16):04X} {q16_to_u16(p.depth_q16):04X} {STATE_CODE[p.state]:X} {int(p.rebased):d} {stable_wire:d} "
                f"{int(p.sequence):04X} {int(p.timestamp_ticks):08X} {p.calibration_reason:02X} "
                f"{s32(ax):08X} {s32(ay):08X} {s32(az):08X} {q16_to_u16(ap):04X} {q16_to_u16(av):04X} {q16_to_u16(ad):04X} {aseq:04X} {ats:08X} {aval:d}\n"
            )
    print(f"wrote {len(rows)} cursor vectors from {SOURCE} to {OUTPUT}")

if __name__ == "__main__":
    main()
