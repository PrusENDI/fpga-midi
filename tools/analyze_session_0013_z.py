import csv, json, math, statistics, sys
from pathlib import Path

SESSION = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
    r"C:\weizijian\documents\gowin fpga\mgc3130_uart\calibration\session_0013_z"
)
OUT = SESSION / "analysis"
OUT.mkdir(parents=True, exist_ok=True)

def flag(v):
    return str(v).strip().lower() in ("1", "true", "yes")
def q(v, p):
    if not v: return None
    a = sorted(v); k = (len(a)-1)*p; lo, hi = math.floor(k), math.ceil(k)
    return a[lo] if lo == hi else a[lo] + (a[hi]-a[lo])*(k-lo)
def med(v): return statistics.median(v) if v else None
def sd(v): return statistics.stdev(v) if len(v)>1 else 0.0

with open(SESSION / "samples.csv", newline="", encoding="utf-8") as f:
    rows = list(csv.DictReader(f))
for r in rows:
    for k in ("sequence", "timestamp", "gap_before", "x", "y", "z"):
        r[k] = int(r[k], 0)
    r["valid"] = (flag(r["report_valid"]) and flag(r["xyz_valid"])
                  and not flag(r["report_error"])
                  and not (r["x"] == 0x7fff and r["y"] == 0x7fff))

gaps = [i for i,r in enumerate(rows) if r["gap_before"] > 0]
gap_i = max(gaps, key=lambda i: rows[i]["gap_before"]) if gaps else -1
main = rows[gap_i:] if gap_i >= 0 else rows
valid = [r for r in main if r["valid"]]
invalid = [r for r in main if not r["valid"]]

# Quantize z into broad levels to expose the float-to-touch progression.
def level(z):
    if z >= 61440: return "float_high"
    if z >= 49152: return "approach_high"
    if z >= 32768: return "approach_mid"
    if z >= 16384: return "approach_low"
    if z >= 4096: return "near_touch"
    return "touch_low"

level_runs=[]; cur=None
for r in main:
    lab = level(r["z"]) if r["valid"] else "INVALID"
    if cur is None or lab != cur["label"] or r["gap_before"] > 0:
        if cur: level_runs.append(cur)
        cur={"label":lab,"start_sequence":r["sequence"],"end_sequence":r["sequence"],
             "frames":0,"z":[],"x":[],"y":[]}
    cur["end_sequence"] = r["sequence"]; cur["frames"] += 1
    if r["valid"]:
        cur["z"].append(r["z"]); cur["x"].append(r["x"]); cur["y"].append(r["y"])
if cur: level_runs.append(cur)

with open(OUT/"z_level_segments.csv","w",newline="",encoding="utf-8") as f:
    w=csv.writer(f); w.writerow(["level","frames","start_sequence","end_sequence","z_min","z_max","z_median","x_median","y_median"])
    for a in level_runs:
        w.writerow([a["label"],a["frames"],a["start_sequence"],a["end_sequence"],
                    min(a["z"]) if a["z"] else "", max(a["z"]) if a["z"] else "", med(a["z"]), med(a["x"]), med(a["y"])])

# Quantile bins use data distribution and provide robust candidate trigger bands.
zvals=[r["z"] for r in valid]
bins=[]
for name,lo,hi in (("touch_candidate",0,4095),("near_touch",4096,16383),
                   ("mid",16384,32767),("approach",32768,49151),("float_candidate",49152,65535)):
    a=[r for r in valid if lo <= r["z"] <= hi]
    bins.append({"name":name,"z_range":[lo,hi],"frames":len(a),
                 "z_median":med([r["z"] for r in a]),"z_p05":q([r["z"] for r in a],.05),"z_p95":q([r["z"] for r in a],.95),
                 "x_median":med([r["x"] for r in a]),"y_median":med([r["y"] for r in a])})

# Detect monotone approach portions by the sign of frame-to-frame dz.
dirs=[]; prev=None
for r in valid:
    if prev is not None:
        dz=r["z"]-prev["z"]
        dirs.append("down" if dz < -64 else "up" if dz > 64 else "flat")
    prev=r
counts={k:dirs.count(k) for k in ("down","flat","up")}

# Save every 4th valid sample for plotting/reconstruction.
with open(OUT/"z_trace_sample.csv","w",newline="",encoding="utf-8") as f:
    w=csv.writer(f); w.writerow(["sequence","timestamp","x","y","z","level","gap_before"])
    for i,r in enumerate(valid):
        if i%4==0 or i in (0,len(valid)-1):
            w.writerow([r["sequence"],r["timestamp"],r["x"],r["y"],r["z"],level(r["z"]),r["gap_before"]])

# SVG: z versus sample index, with x/y secondary traces omitted for clarity.
W,H=1100,520; left,right,top,bottom=70,30,45,55
plotw=W-left-right; ploth=H-top-bottom
sx=lambda i: left+(i/max(1,len(valid)-1))*plotw
sy=lambda z: top+(65535-z)/65535*ploth
colors={"float_high":"#2563eb","approach_high":"#0f766e","approach_mid":"#16a34a","approach_low":"#ca8a04","near_touch":"#ea580c","touch_low":"#dc2626"}
svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
     '<rect width="100%" height="100%" fill="white"/>',
     f'<text x="{left}" y="25" font-family="sans-serif" font-size="18" font-weight="bold">{SESSION.name} Z trace (float to touch)</text>',
     f'<rect x="{left}" y="{top}" width="{plotw}" height="{ploth}" fill="#fafafa" stroke="#6b7280"/>']
for z in (0,4096,16384,32768,49152,65535):
    y=sy(z); svg += [f'<line x1="{left}" y1="{y:.1f}" x2="{W-right}" y2="{y:.1f}" stroke="#e5e7eb"/>',f'<text x="{left-8}" y="{y+4:.1f}" text-anchor="end" font-family="sans-serif" font-size="11">{z}</text>']
last=None
for i,r in enumerate(valid):
    if i%4 and i not in (len(valid)-1,): continue
    x,y=sx(i),sy(r["z"]); c=colors[level(r["z"])]
    if last: svg.append(f'<line x1="{last[0]:.1f}" y1="{last[1]:.1f}" x2="{x:.1f}" y2="{y:.1f}" stroke="{c}" stroke-width="1.5" opacity="0.8"/>')
    svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="2.1" fill="{c}"/>'); last=(x,y)
for i,(k,c) in enumerate(colors.items()):
    x=left+i*165; svg.append(f'<circle cx="{x}" cy="{H-22}" r="5" fill="{c}"/><text x="{x+9}" y="{H-18}" font-family="sans-serif" font-size="11">{k}</text>')
svg.append('</svg>'); (OUT/"z_trace.svg").write_text("\n".join(svg),encoding="utf-8")

result={"session":SESSION.name,"frames":len(rows),"valid_frames_all":sum(r["valid"] for r in rows),"invalid_frames_all":sum(not r["valid"] for r in rows),
        "crc_errors_from_summary":json.loads((SESSION/"summary.json").read_text(encoding="utf-8")).get("crc_errors"),
        "largest_gap_before":rows[gap_i]["gap_before"] if gap_i>=0 else 0,"largest_gap_before_sequence":rows[gap_i]["sequence"] if gap_i>=0 else None,
        "principal_track_start_sequence":main[0]["sequence"] if main else None,"principal_track_end_sequence":main[-1]["sequence"] if main else None,
        "principal_track_frames":len(main),"principal_track_valid_frames":len(valid),"principal_track_invalid_sequences":[r["sequence"] for r in invalid],
        "z_range":[min(zvals),max(zvals)],"x_range":[min(r["x"] for r in valid),max(r["x"] for r in valid)],"y_range":[min(r["y"] for r in valid),max(r["y"] for r in valid)],
        "z_direction_counts":counts,"levels":bins,"level_runs":len(level_runs),"outputs":["z_level_segments.csv","z_trace_sample.csv","z_trace.svg"]}
(OUT/"analysis.json").write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
print(json.dumps(result,ensure_ascii=False,indent=2))
