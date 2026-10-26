import csv, json
from pathlib import Path
from tools.v2_fixed_reference import Profile, process_frame

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "tools" / "capture_fast_01.csv"
out = ROOT / "tools" / "testdata" / "v2_input" / "replay_fast_01.vec"
profile = Profile(neutral=(0,0,0), gain=(1<<16,)*3,
                  workspace=((-32768,32767),(-32768,32767),(0,65535)), epoch=0)
rows=[]
with source.open(newline="") as f:
    for i,r in enumerate(csv.DictReader(f)):
        rows.append(dict(sequence=i, timestamp_ticks=round(float(r["time_ms"])*1000),
                         sensor_raw=(int(r["x"],16),int(r["y"],16),int(r["z"],16)),
                         valid_xyz=bool(int(r["position_valid"])), saturated=False, gap=False, calibration_epoch=0))
# Provenance synthetic boundary and quality rows.
rows += [
 dict(sequence=len(rows),timestamp_ticks=40000000,sensor_raw=(0,0,0),valid_xyz=True,saturated=False,gap=False,calibration_epoch=0),
 dict(sequence=len(rows)+1,timestamp_ticks=40000001,sensor_raw=(32767,32768,40000),valid_xyz=True,saturated=False,gap=False,calibration_epoch=0),
 dict(sequence=len(rows)+2,timestamp_ticks=40000002,sensor_raw=(32768,65535,65535),valid_xyz=True,saturated=False,gap=False,calibration_epoch=0),
 dict(sequence=len(rows)+3,timestamp_ticks=40000003,sensor_raw=(32768,32768,36000),valid_xyz=False,saturated=False,gap=False,calibration_epoch=0),
 dict(sequence=len(rows)+4,timestamp_ticks=40000004,sensor_raw=(32768,32768,40000),valid_xyz=True,saturated=True,gap=False,calibration_epoch=0),
 dict(sequence=len(rows)+6,timestamp_ticks=40000006,sensor_raw=(32768,32768,50000),valid_xyz=True,saturated=False,gap=True,calibration_epoch=0),
 dict(sequence=65535,timestamp_ticks=50000000,sensor_raw=(32768,32768,40000),valid_xyz=True,saturated=False,gap=False,calibration_epoch=0),
 dict(sequence=0,timestamp_ticks=50000001,sensor_raw=(32768,32768,40001),valid_xyz=True,saturated=False,gap=False,calibration_epoch=0),
]
gap_count=0; previous=None
with out.open("w") as fo:
    for fr in rows:
        exp=process_frame(fr,profile,previous_sequence=previous,gap_count=gap_count)
        gap_count=exp["gap_count"]; previous=fr["sequence"]
        sx,sy,sz=fr["sensor_raw"]
        def enc17(v): return v & ((1<<17)-1)
        xyz=exp["xyz"]
        fo.write("%04X %08X %05X %05X %05X %d %d %d %d %02X %08X %08X %08X %d %d %d %04X %02X %d\n" % (
            fr["sequence"]&0xffff, fr["timestamp_ticks"]&0xffffffff, enc17(sx-32768), enc17(sy-32768), sz&0x1ffff,
            1, int(fr["valid_xyz"]), int(fr["saturated"]), int(fr["gap"]), fr["calibration_epoch"],
            xyz[0]&0xffffffff, xyz[1]&0xffffffff, xyz[2]&0xffffffff, int(exp["frame_valid"]), int(exp["lost"]), int(exp["degraded"]), exp["gap_count"], exp["calibration_reason"], int(exp["frame_valid"])))
print(f"wrote {len(rows)} vectors from {source} plus 8 synthetic rows to {out}")
