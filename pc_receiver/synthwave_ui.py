"""Tkinter desktop UI for the six-track MGC3130 Synthwave verifier."""

from __future__ import annotations

import csv
import json
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Dict, List


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from synthwave_loop import (DEFAULT_PITCH_SPACE, STYLE, TRACKS, LeadStartGate,
                            StreamingLeadFilter, _clamp, compile_loop, density_to_lambda,
                            make_cursor, load_jsonl_records, project_sample, render_loop,
                            write_event_table)  # noqa: E402

# Canvas view range in raw sensor counts. The path and the pitch guides share
# it, so the drawn trajectory stays 1:1 with the note grid. Full scale for now:
# replacing it with the measured linear band (from a workspace capture) will
# widen the drawn path without moving it relative to the guides.
VIEW_X_RANGE = (0.0, 65535.0)
VIEW_Y_RANGE = (0.0, 65535.0)
PLOT_MARGIN = 16.0


def _iso_point(x: float, y: float, z: float, width: int, height: int) -> tuple:
    """Isometric projection of a point in the unit cube."""
    left, top, plot_w, plot_h = _plot_rect(width, height, (0.0, 1.0), (0.0, 1.0))
    scale = min(plot_w, plot_h) / 2.4
    cx = left + plot_w / 2.0
    cy = top + plot_h / 2.0
    x, y, z = float(x) - 0.5, float(y) - 0.5, float(z) - 0.5
    return (cx + (x - y) * 0.8660254037844386 * scale, cy + ((x + y) * 0.5 - z) * scale)


def _project_3d(row: dict, width: int, height: int,
                x_range: tuple | None = None, y_range: tuple | None = None) -> tuple:
    """Project a preview row: cursor XY plus the working height.

    All three axes use one pixel scale, so a unit step on X, Y or Z draws the
    same length and the box reads square.
    """
    x = row.get("cursor_x")
    y = row.get("cursor_y")
    z = row.get("z_norm")
    return _iso_point(0.5 if x is None else x, 0.5 if y is None else y, 0.5 if z is None else z,
                      width, height)


def _unit_value(value: object, default: float = 0.5) -> float:
    """Normalize either a unit coordinate or a raw MGC3130 count."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    if abs(number) > 1.5:
        number /= 65535.0
    return _clamp(number, 0.0, 1.0)


def _preview_xy_z(row: dict) -> tuple[float, float, float]:
    """Return the XY position and depth used by the 2D preview.

    Lead cursor coordinates are preferred because they are the values the
    compiler consumes in cursor mode.  Compiled/other-track rows fall back to
    normalized application coordinates and finally raw sensor counts.
    """
    x = row.get("cursor_x")
    y = row.get("cursor_y")
    z = row.get("z_norm")
    if x is None:
        x = row.get("q_x", row.get("x"))
    if y is None:
        y = row.get("q_y", row.get("y"))
    if z is None:
        z = row.get("q_z", row.get("z"))
    return _unit_value(x), _unit_value(y), _unit_value(z)


def _z_color(z: float) -> str:
    """Map low Z to blue and high Z to orange for a readable depth cue."""
    ratio = _clamp(float(z), 0.0, 1.0)
    low = (79, 124, 255)
    high = (255, 159, 104)
    rgb = tuple(round(low[i] + (high[i] - low[i]) * ratio) for i in range(3))
    return "#%02x%02x%02x" % rgb


def _project_xy_unit(x: float, y: float, width: int, height: int) -> tuple[float, float]:
    left, top, plot_w, plot_h = _plot_rect(width, height, (0.0, 1.0), (0.0, 1.0))
    return left + _clamp(x, 0.0, 1.0) * plot_w, top + (1.0 - _clamp(y, 0.0, 1.0)) * plot_h


def _thin_xy_z(samples: List[dict], width: int, height: int,
               limit: int | None = None) -> List[tuple[float, float, float, int]]:
    """Project a capture to XY pixels while retaining depth and stroke breaks.

    A lifted hand or invalid frame starts a new stroke.  Z is kept in the
    result even when XY is unchanged, so a pure depth movement remains visible
    through its color change instead of disappearing as a zero-length line.
    """
    points: List[tuple[float, float, float, int]] = []
    previous_key: tuple[int, int, int] | None = None
    stroke = 0
    for row in samples:
        x, y, z = _preview_xy_z(row)
        engaged = row.get("cursor_engaged", True)
        valid = bool(row.get("position_valid", True)) and engaged is not False
        if not valid:
            stroke += 1
            previous_key = None
            continue
        px, py = _project_xy_unit(x, y, width, height)
        key = (round(px), round(py), round(z * 255.0))
        if key != previous_key:
            points.append((px, py, z, stroke))
            previous_key = key
    if limit is not None and len(points) > limit:
        stride = max(1, (len(points) - 1 + limit - 2) // max(1, limit - 1))
        reduced = points[::stride]
        if reduced[-1] != points[-1]:
            reduced.append(points[-1])
        points = reduced[:limit - 1] + [points[-1]] if len(reduced) > limit else reduced
    return points


class _DepthPathCache:
    """Incremental pixel cache for the depth-encoded XY canvas."""

    def __init__(self, limit: int = 2500) -> None:
        self.limit = max(64, int(limit))
        self.reset()

    def reset(self) -> None:
        self._source: List[dict] | None = None
        self._count = 0
        self._size: tuple | None = None
        self._points: List[tuple[float, float, float, int]] = []
        self._last_key: tuple[int, int, int] | None = None
        self._stroke = 0

    def points(self, samples: List[dict], width: int, height: int) -> List[tuple[float, float, float, int]]:
        size = (width, height)
        if self._source is not samples or self._size != size or len(samples) < self._count:
            self.reset()
            self._source = samples
            self._size = size
        for row in samples[self._count:]:
            x, y, z = _preview_xy_z(row)
            if bool(row.get("position_valid", True)) is False or row.get("cursor_engaged", True) is False:
                self._stroke += 1
                self._last_key = None
                continue
            px, py = _project_xy_unit(x, y, width, height)
            key = (round(px), round(py), round(z * 255.0))
            if key != self._last_key:
                self._points.append((px, py, z, self._stroke))
                self._last_key = key
        self._count = len(samples)
        while len(self._points) > self.limit:
            old = self._points
            stride = max(2, (len(old) + self.limit - 2) // max(1, self.limit - 1))
            reduced = old[::stride]
            if reduced[-1] != old[-1]:
                reduced.append(old[-1])
            self._points = reduced[:self.limit - 1] + [old[-1]] if len(reduced) > self.limit else reduced
        return self._points


def _y_to_canvas(value: float, width: int, height: int) -> float:
    _, top, _, plot_h = _plot_rect(width, height, VIEW_X_RANGE, VIEW_Y_RANGE)
    y_lo, y_hi = VIEW_Y_RANGE
    fy = (float(value) - y_lo) / max(1e-9, y_hi - y_lo)
    fy = 0.0 if fy < 0.0 else (1.0 if fy > 1.0 else fy)
    return top + (1.0 - fy) * plot_h


def _clip_percent(samples: List[dict]) -> float:
    """Share of frames pinned at a sensor rail.

    Near the rails the reading stops moving while the hand keeps going, which
    reads as dropped frames or aliasing on the canvas. Counting them makes
    saturation visible instead of mysterious.
    """
    if not samples:
        return 0.0
    hits = 0
    for row in samples:
        x = float(row.get("x", 0))
        y = float(row.get("y", 0))
        if x <= 0.0 or x >= 65535.0 or y <= 0.0 or y >= 65535.0:
            hits += 1
    return 100.0 * hits / len(samples)


def _plot_rect(width: int, height: int,
               x_range: tuple = (0.0, 65535.0),
               y_range: tuple = (0.0, 65535.0)) -> tuple:
    """Return (left, top, width, height) using one scale for both axes.

    The sensor's active area is square, but the canvas is usually wider than it
    is tall. Stretching each axis to fill the canvas makes one count worth a
    different number of pixels on each axis. Fit the range into the canvas at
    one scale, with a compact margin, and centre it instead.
    """
    span_x = max(1e-9, x_range[1] - x_range[0])
    span_y = max(1e-9, y_range[1] - y_range[0])
    usable_w = max(1.0, width - 2.0 * PLOT_MARGIN)
    usable_h = max(1.0, height - 2.0 * PLOT_MARGIN)
    scale = min(usable_w / span_x, usable_h / span_y)
    plot_w = span_x * scale
    plot_h = span_y * scale
    return ((width - plot_w) / 2.0, (height - plot_h) / 2.0, plot_w, plot_h)


def _project_point(row: dict, width: int, height: int,
                   x_range: tuple = (0.0, 65535.0),
                   y_range: tuple = (0.0, 65535.0)) -> tuple:
    """Map a raw report to canvas coordinates without integer rounding.

    Rounding every point to whole pixels is what turned a hand-drawn curve
    into a staircase: a smooth 1 px/step path becomes alternating runs and
    jumps. The cache dedupes on rounded pixels, but the drawn coordinate
    stays fractional so the canvas line is smooth.
    """
    left, top, plot_w, plot_h = _plot_rect(width, height, x_range, y_range)
    x_lo, x_hi = x_range
    y_lo, y_hi = y_range
    fx = (float(row.get("x", 0)) - x_lo) / max(1e-9, x_hi - x_lo)
    fy = (float(row.get("y", 0)) - y_lo) / max(1e-9, y_hi - y_lo)
    fx = 0.0 if fx < 0.0 else (1.0 if fx > 1.0 else fx)
    fy = 0.0 if fy < 0.0 else (1.0 if fy > 1.0 else fy)
    return (left + fx * plot_w, top + (1.0 - fy) * plot_h)


def _thin_path(samples: List[dict], width: int, height: int,
               x_range: tuple = (0.0, 65535.0),
               y_range: tuple = (0.0, 65535.0)) -> List[tuple]:
    """Project the trajectory to canvas pixels and drop repeated pixels.

    Drawing every sample makes the redraw cost grow with the capture
    length; stride sampling instead aliases the shape, which is what makes
    fine drawing impossible late in a take. Mapping to integer pixels and
    dropping points that land on the same pixel keeps the drawn shape exact
    at display resolution and bounds the polyline by the canvas area, not by
    the number of captured frames.
    """
    pixels: List[tuple] = []
    previous: tuple | None = None
    for row in samples:
        point = _project_point(row, width, height, x_range, y_range)
        key = (round(point[0]), round(point[1]))
        if key != previous:
            pixels.append(point)
            previous = key
    return pixels


class _PixelPathCache:
    """Incremental front end for :func:`_thin_path`.

    The capture list only ever grows during a take, so re-projecting all of
    it on every redraw is wasted work: at 200 Hz a 60 s take is 12000 points
    and the scan alone dominates the frame budget. Cache the projected pixels
    and append only the samples added since the previous draw.

    Pixel dedup alone is not a bound: the hand revisits the same pixels, so a
    120 s take still produced 7000 distinct points and a 7 ms redraw. Halving
    the list whenever it exceeds ``limit`` keeps the polyline under a fixed
    budget while roughly preserving the drawn shape.
    """

    def __init__(self, limit: int = 2500) -> None:
        self.limit = max(64, int(limit))
        self.reset()

    def reset(self) -> None:
        self._source: List[dict] | None = None
        self._count = 0
        self._size: tuple | None = None
        self._pixels: List[tuple] = []
        self._last_key: tuple | None = None

    def points(self, samples: List[dict], width: int, height: int,
               x_range: tuple = (0.0, 65535.0),
               y_range: tuple = (0.0, 65535.0),
               projector=None) -> List[tuple]:
        project = projector or _project_point
        size = (width, height, x_range, y_range, getattr(project, "__name__", "projector"))
        if (self._source is not samples or self._size != size
                or len(samples) < self._count):
            self._source = samples
            self._count = 0
            self._size = size
            self._pixels = []
            self._last_key = None
        pending = samples[self._count:]
        for row in pending:
            point = project(row, width, height, x_range, y_range)
            key = (round(point[0]), round(point[1]))
            if key != self._last_key:
                self._pixels.append(point)
                self._last_key = key
        self._count = len(samples)
        while len(self._pixels) > self.limit:
            self._pixels = self._pixels[::2]
        return self._pixels


DIAG_FIELDS = ("wall_ms", "elapsed_s", "state", "rate_hz", "queue", "draw_ms",
               "frames", "preview_points", "drawn_points", "clipped_pct",
               "canvas_w", "canvas_h")


def _capture_filename(label: str, track: str, stamp: str) -> str:
    """Name a raw capture after the protocol step it belongs to."""
    safe = "".join(ch if (ch.isalnum() or ch in "-_") else "_" for ch in str(label or "").strip())
    safe = safe.strip("_") or track
    return f"{safe}_{stamp}.jsonl"


def _append_diag_row(path: Path, row: dict) -> None:
    """Append one diagnostics row, writing the header on first use.

    Opening per row keeps the file valid even if the UI is killed, and one
    write per second costs nothing next to a canvas redraw.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    new_file = not path.exists()
    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=DIAG_FIELDS, extrasaction="ignore")
        if new_file:
            writer.writeheader()
        writer.writerow(row)


def calibration_offset(records: List[dict], centre: float = 32768.0) -> tuple:
    """Offset that puts the resting hand at the centre of the sensing area.

    Takes the median of the valid frames of a hold-still window, so a single
    outlier cannot move the origin. Returns (0, 0) when there is not enough
    trustworthy data, which leaves the take untouched.
    """
    xs = [float(row["x"]) for row in records
          if row.get("position_valid", True) and row.get("x") is not None]
    ys = [float(row["y"]) for row in records
          if row.get("position_valid", True) and row.get("y") is not None]
    if len(xs) < 10 or len(ys) < 10:
        return (0.0, 0.0)
    xs.sort()
    ys.sort()
    return (xs[len(xs) // 2] - centre, ys[len(ys) // 2] - centre)


def apply_offset(record: dict, offset: tuple) -> dict:
    """Shift a raw position so that the calibrated rest position reads centre."""
    dx, dy = offset
    if not dx and not dy:
        return record
    shifted = dict(record)
    shifted["x"] = int(_clamp(float(record.get("x", 32768)) - dx, 0.0, 65535.0))
    shifted["y"] = int(_clamp(float(record.get("y", 32768)) - dy, 0.0, 65535.0))
    return shifted


class SynthwaveUI(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("MGC3130 Melodic Synthwave — Capture & Loop")
        self.geometry("1200x780")
        self.minsize(980, 640)
        self.configure(bg="#10131b")
        self.selected_track = tk.StringVar(value="lead")
        self.take_label = tk.StringVar(value="lead")
        self.status = tk.StringVar(value="IDLE — choose a track, then Record")
        self.bpm = tk.IntVar(value=STYLE.bpm)
        self.swing = tk.DoubleVar(value=STYLE.swing * 100.0)
        self.mapping_mode = tk.StringVar(value="workspace")
        self.note_source = tk.StringVar(value="variational")
        self.gate_source = tk.StringVar(value="touch")
        # 0.6 maps to lambda 6.0, the value agreed for testing.
        self.density = tk.DoubleVar(value=0.6)
        self.records: Dict[str, List[dict]] = {track: [] for track in TRACKS}
        self.active_layer = tk.IntVar(value=0)
        self.lead_layers: List[List[dict]] = [[]]
        self.auto_length = tk.BooleanVar(value=False)
        self.current_capture: List[dict] = []
        self.lead_preview_capture: List[dict] = []
        self.lead_start_gate = LeadStartGate()
        self.lead_filter = StreamingLeadFilter()
        self.lead_cursor = make_cursor()
        self.event_table: dict | None = None
        self.receiver: subprocess.Popen[str] | None = None
        self.receiver_thread: threading.Thread | None = None
        self.inbox: queue.Queue[dict] = queue.Queue()
        self.calibrating = False
        self.calibration_frames: List[dict] = []
        self.calibration_seconds = 2.0
        self._calibration_started = 0.0
        self.take_offset = (0.0, 0.0)
        self.recording = False
        self.playing = False
        # Redraw budget. The sensor streams at 200 Hz, but the trajectory view
        # runs at ~60 fps; drawing more often than that only adds latency to
        # the pointer.
        self.draw_interval_s = 0.016
        self._last_draw = 0.0
        self._draw_cost_ms = 0.0
        self.diag = tk.StringVar(value="idle")
        self._diag_window = (time.monotonic(), 0)
        self._path_cache = _DepthPathCache()
        # Persist the once-per-second readout so a slow take can be analysed
        # offline instead of being read off the screen.
        stamp = time.strftime("%Y%m%d-%H%M%S")
        self.session_started = time.monotonic()
        self.diag_path = ROOT / "pc_receiver" / "diagnostics" / f"ui_{stamp}.csv"
        self.capture_path: Path | None = None
        self._drawn_points = 0
        self._build_style()
        self._build_ui()
        self.after(16, self._poll_inbox)

    def _build_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TFrame", background="#171b26")
        style.configure("TLabel", background="#171b26", foreground="#e9edf5")
        style.configure("Title.TLabel", background="#10131b", foreground="#f3c969", font=("Segoe UI", 18, "bold"))
        style.configure("Muted.TLabel", background="#171b26", foreground="#9da7bb")
        style.configure("TButton", padding=(10, 5))
        style.configure("Track.TButton", padding=(8, 12), font=("Segoe UI", 10, "bold"))

    def _build_ui(self) -> None:
        ttk.Label(self, text="MGC3130  ·  MELODIC SYNTHWAVE", style="Title.TLabel").pack(anchor="w", padx=18, pady=(14, 4))
        ttk.Label(self, text="CAPTURE & LOOP  |  six tracks  |  Lead trajectory + Touch/Tap performance", style="Muted.TLabel").pack(anchor="w", padx=20, pady=(0, 12))
        main = ttk.Frame(self)
        main.pack(fill="both", expand=True, padx=14, pady=6)
        # The left column carries more controls than fit in a short window, so
        # it scrolls: a plain frame silently pushed the Lead controls out of
        # view (they existed at y=0, height 1, and could not be clicked).
        left_host = ttk.Frame(main)
        left_host.pack(side="left", fill="y", padx=(0, 10))
        left_canvas = tk.Canvas(left_host, borderwidth=0, highlightthickness=0, width=214)
        left_bar = ttk.Scrollbar(left_host, orient="vertical", command=left_canvas.yview)
        left_canvas.configure(yscrollcommand=left_bar.set)
        left_bar.pack(side="right", fill="y")
        left_canvas.pack(side="left", fill="both", expand=True)
        left = ttk.Frame(left_canvas)
        left_window = left_canvas.create_window((0, 0), window=left, anchor="nw")
        left.bind("<Configure>", lambda _event: left_canvas.configure(scrollregion=left_canvas.bbox("all")))
        left_canvas.bind("<Configure>", lambda event: left_canvas.itemconfigure(left_window, width=event.width))

        def _in_left(widget) -> bool:
            while widget is not None:
                if widget is left_canvas or widget is left:
                    return True
                widget = getattr(widget, "master", None)
            return False

        def _wheel(event: "tk.Event") -> None:
            if _in_left(self.winfo_containing(event.x_root, event.y_root)):
                left_canvas.yview_scroll(-1 if event.delta > 0 else 1, "units")

        self.bind_all("<MouseWheel>", _wheel)
        center = ttk.Frame(main)
        center.pack(side="left", fill="both", expand=True)
        right = ttk.Frame(main)
        right.pack(side="right", fill="y", padx=(10, 0))

        ttk.Label(left, text="LEAD SPACE", style="Muted.TLabel").pack(anchor="w")
        ttk.Radiobutton(left, text="Workspace (fixed)", value="workspace", variable=self.mapping_mode).pack(anchor="w")
        ttk.Radiobutton(left, text="Gesture-Aligned", value="gesture_aligned", variable=self.mapping_mode).pack(anchor="w")
        ttk.Separator(left).pack(fill="x", pady=10)
        ttk.Label(left, text="NOTE SOURCE", style="Muted.TLabel").pack(anchor="w")
        ttk.Radiobutton(left, text="Anchors (turns)", value="anchors",
                        variable=self.note_source).pack(anchor="w")
        ttk.Radiobutton(left, text="Variational (segments)", value="variational",
                        variable=self.note_source).pack(anchor="w")
        ttk.Label(left, text="GATE", style="Muted.TLabel").pack(anchor="w", pady=(8, 0))
        ttk.Radiobutton(left, text="Touch (contact)", value="touch",
                        variable=self.gate_source).pack(anchor="w")
        ttk.Radiobutton(left, text="Bow (left-right)", value="bow",
                        variable=self.gate_source).pack(anchor="w")
        ttk.Label(left, text="DENSITY", style="Muted.TLabel").pack(anchor="w", pady=(8, 0))
        ttk.Scale(left, from_=0.0, to=1.0, variable=self.density,
                  orient="horizontal").pack(fill="x")
        self.density_label = ttk.Label(left, text="λ 6.0", style="Muted.TLabel")
        self.density_label.pack(anchor="w")
        self.density.trace_add("write", lambda *_: self._update_density_label())
        ttk.Checkbutton(left, text="Auto length (follow take)", variable=self.auto_length).pack(anchor="w", pady=(8, 0))
        self.layer_label = ttk.Label(left, text="layer 1 of 1", style="Muted.TLabel")
        self.layer_label.pack(anchor="w", pady=(6, 0))
        layer_row = ttk.Frame(left)
        layer_row.pack(fill="x")
        ttk.Button(layer_row, text="Add layer", command=self.add_layer).pack(side="left", expand=True, fill="x")
        ttk.Button(layer_row, text="Clear layer", command=self.clear_layer).pack(side="left", expand=True, fill="x")
        ttk.Separator(left).pack(fill="x", pady=12)
        ttk.Label(left, text="TRACKS", style="Muted.TLabel").pack(anchor="w", pady=(0, 6))
        for track in TRACKS:
            label = {"lead": "LEAD  ·  XY + Z depth", "bass": "BASS  ·  touch", "pad": "PAD  ·  touch", "arp": "ARP  ·  touch", "drums": "DRUMS  ·  tap", "texture_fx": "TEXTURE / FX"}[track]
            ttk.Radiobutton(left, text=label, value=track, variable=self.selected_track, command=self._track_changed).pack(fill="x", pady=2)
        ttk.Separator(left).pack(fill="x", pady=12)
        ttk.Label(left, text="TAKE LABEL", style="Muted.TLabel").pack(anchor="w")
        ttk.Entry(left, textvariable=self.take_label).pack(fill="x", pady=(2, 0))
        ttk.Separator(left).pack(fill="x", pady=12)
        ttk.Button(left, text="●  RECORD", style="Track.TButton", command=self.start_record).pack(fill="x", pady=3)
        ttk.Button(left, text="■  STOP", command=self.stop_record).pack(fill="x", pady=3)
        ttk.Button(left, text="COMPILE LOOP", command=self.compile).pack(fill="x", pady=3)
        ttk.Button(left, text="▶  PLAY PREVIEW", command=self.play_preview).pack(fill="x", pady=3)
        ttk.Button(left, text="CLEAR TRACK", command=self.clear_track).pack(fill="x", pady=3)
        ttk.Button(left, text="CLEAR ALL", command=self.clear_all).pack(fill="x", pady=3)
        ttk.Separator(left).pack(fill="x", pady=12)
        ttk.Button(left, text="Import JSONL…", command=self.import_jsonl).pack(fill="x", pady=3)
        ttk.Button(left, text="Export Event JSON…", command=self.export_events).pack(fill="x", pady=3)
        ttk.Button(left, text="Render WAV…", command=self.render_wav).pack(fill="x", pady=3)
        ttk.Separator(left).pack(fill="x", pady=12)

        # The surrounding center pane stays the panel color.  The square plot

        # The surrounding center pane stays the panel color.  The square plot
        # gets its own dark fill below, so the old wide dark canvas no longer
        # reads as an empty rectangle containing a smaller plot.
        self.canvas = tk.Canvas(center, bg="#171b26", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<Configure>", lambda _event: self._draw_canvas())
        ttk.Label(center, textvariable=self.status, anchor="w").pack(fill="x", pady=(8, 2))
        ttk.Label(center, textvariable=self.diag, style="Muted.TLabel", anchor="w").pack(fill="x")
        self.progress = ttk.Progressbar(center, mode="determinate", maximum=128)
        self.progress.pack(fill="x")
        columns = ("track", "tick", "note", "duration", "velocity", "source", "landmarks", "delta", "color")
        # The spatial preview is the primary instrument.  Keep a compact
        # event summary below it so the central square gets the available
        # vertical space without hiding the event table entirely.
        self.tree = ttk.Treeview(center, columns=columns, show="headings", height=6)
        for column in columns:
            self.tree.heading(column, text=column.upper())
            self.tree.column(column, width=88 if column not in ("landmarks", "delta") else 118, anchor="center")
        self.tree.pack(fill="x", pady=(10, 0))

        ttk.Label(right, text="SYNTHWAVE STYLE", style="Muted.TLabel").pack(anchor="w", pady=(0, 8))
        self._value_row(right, "BPM", self.bpm, 90, 120)
        self._value_row(right, "Swing %", self.swing, 50, 56)
        ttk.Label(right, text="Am  ·  F  ·  C  ·  G", font=("Segoe UI", 12, "bold")).pack(anchor="w", pady=(16, 2))
        ttk.Label(right, text="8 bars  ·  4/4  ·  minor pentatonic", style="Muted.TLabel").pack(anchor="w")
        ttk.Label(right, text="PitchSpace  ·  A minor pentatonic  ·  G3–C5", style="Muted.TLabel").pack(anchor="w", pady=(4, 0))
        ttk.Separator(right).pack(fill="x", pady=16)
        ttk.Label(right, text="PLAY PERFORMANCE", style="Muted.TLabel").pack(anchor="w", pady=(0, 8))
        self.mod_x = tk.DoubleVar(value=0.0)
        self.mod_y = tk.DoubleVar(value=0.0)
        self.mod_z = tk.DoubleVar(value=0.0)
        self._slider(right, "X  Timbre / Morph", self.mod_x)
        self._slider(right, "Y  Pitch / Voicing", self.mod_y)
        self._slider(right, "Z  Energy / FX", self.mod_z)
        ttk.Label(right, text="PLAY never adds NOTE_ON.\nIt modulates the active loop only.", style="Muted.TLabel", justify="left").pack(anchor="w", pady=16)
        self.log = tk.Text(right, width=30, height=12, bg="#0c1018", fg="#b9c4d9", relief="flat", state="disabled")
        self.log.pack(fill="both", expand=True)

    def _value_row(self, parent: ttk.Frame, label: str, variable: tk.Variable, low: int, high: int) -> None:
        ttk.Label(parent, text=label).pack(anchor="w", pady=(5, 0))
        ttk.Spinbox(parent, from_=low, to=high, textvariable=variable, width=10).pack(anchor="w")

    def _slider(self, parent: ttk.Frame, label: str, variable: tk.DoubleVar) -> None:
        ttk.Label(parent, text=label).pack(anchor="w", pady=(4, 0))
        ttk.Scale(parent, from_=-1.0, to=1.0, variable=variable, orient="horizontal", length=180).pack(anchor="w")

    def _track_changed(self) -> None:
        if not self.recording:
            self.status.set(f"READY — selected {self.selected_track.get()}")
            self._log(f"selected track: {self.selected_track.get()}")

    def _log(self, message: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", time.strftime("%H:%M:%S ") + message + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def start_record(self) -> None:
        if self.recording:
            return
        self.current_capture = []
        self.lead_preview_capture = []
        # Every take starts with a short hold-still calibration: the hand
        # resting at the centre defines zero, so takes do not drift apart.
        self.calibrating = True
        self.calibration_frames = []
        self._calibration_started = time.monotonic()
        self.calibration_seconds = 2.0
        self.take_offset = (0.0, 0.0)
        # Reset the rate window with the capture, otherwise the first row of a
        # new take reports a large negative rate against the previous take.
        self._diag_window = (time.monotonic(), 0)
        if self.selected_track.get() == "lead":
            self.lead_start_gate = LeadStartGate()
            self.lead_filter = StreamingLeadFilter()
            self.lead_cursor = make_cursor()
        self.recording = True
        track = self.selected_track.get()
        self.status.set(f"CALIBRATING — hand off the sensor, forcing baseline ({self.calibration_seconds:.0f} s)")
        self._log(f"forcing the SDK baseline before {track}")
        self._start_receiver()

    def _maybe_finish_calibration(self) -> None:
        """End the baseline window and start the take proper.

        The receiver called gestic_force_calibration() when it opened, so the
        device has already re-measured its own baseline; this wait only gives
        that measurement time to settle and confirms data is flowing. No host
        side offset is applied: the point is to re-baseline the sensor, not to
        re-centre the numbers.
        """
        elapsed = time.monotonic() - self._calibration_started
        if len(self.calibration_frames) >= 20 and elapsed >= self.calibration_seconds:
            self.take_offset = (0.0, 0.0)
            self.calibrating = False
            self.current_capture = []
            self.lead_preview_capture = []
            self._log("baseline forced; take starts from a clean sensor state")
            self._begin_take()
        elif elapsed > 6.0:
            # No usable data: record anyway, but say the take is uncalibrated.
            self.calibrating = False
            self.take_offset = (0.0, 0.0)
            self.status.set("RECORDING — calibration skipped (no data)")
            self._log("calibration skipped: no position data")

    def _begin_take(self) -> None:
        track = self.selected_track.get()
        prompt = "move to the left edge, then move right" if track == "lead" else "stop when the take is complete"
        self.status.set(f"RECORDING — {track}; {prompt}")
        self._log(f"recording {track}")

    def _prepare_capture_path(self) -> Path | None:
        """Return a raw-capture path the receiver can create, or None.

        The receiver exits if it cannot open --output, so probe first and
        fall back to stdout-only rather than losing the take.
        """
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = ROOT / "pc_receiver" / "captures" / _capture_filename(self.take_label.get(), self.selected_track.get(), stamp)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch(exist_ok=True)
        except OSError:
            return None
        return path

    def _start_receiver(self) -> None:
        if self.receiver is not None:
            return
        receiver = Path(__file__).with_name("Static-Release") / "mgc3130_receiver.exe"
        if not receiver.exists():
            self.status.set("RECORDING — receiver executable not found; import JSONL instead")
            self._log(f"missing receiver: {receiver}")
            return
        command = [str(receiver), "--format", "jsonl", "--force-calibration"]
        self.capture_path = self._prepare_capture_path()
        if self.capture_path is not None:
            command += ["--output", str(self.capture_path)]
        self._log(f"capture → {self.capture_path}" if self.capture_path else "capture → stdout only")
        self._log(f"diagnostics → {self.diag_path}")
        try:
            self.receiver = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        except OSError as error:
            self._log(f"receiver failed: {error}")
            self.receiver = None
            return
        def pump() -> None:
            assert self.receiver is not None and self.receiver.stdout is not None
            for line in self.receiver.stdout:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(record, dict):
                    self.inbox.put(record)
        self.receiver_thread = threading.Thread(target=pump, daemon=True)
        self.receiver_thread.start()

    def _push_lead_preview(self, record: dict) -> None:
        """Run the compiler's own filter and cursor so the view is its input.

        The left-edge gate no longer applies: in cursor mode the phrase starts
        at the first engaged frame, and raising the hand stops the cursor.
        """
        projected = project_sample(record)
        value = self.lead_filter.push(projected["q_app"])
        if value is None:
            return
        z_raw = value[2] * 65535.0
        # The preview must use the same rule as the compiler, otherwise the
        # canvas shows the contact drift that the compiled take already hides.
        touching = bool(record.get("touch_flags") or 0)
        point, gain = self.lead_cursor.push((value[0] * 65535.0, value[1] * 65535.0), z_raw,
                                            touching=touching)
        z_norm = _clamp((z_raw - 4000.0) / 20000.0, 0.0, 1.0)
        self.lead_preview_capture.append({
            "cursor_x": point[0],
            "cursor_y": point[1],
            "z_norm": z_norm,
            "cursor_gain": gain,
            "cursor_engaged": self.lead_cursor.engaged,
            "cursor_touch": touching,
            "start_gate_state": "accepted" if self.lead_cursor.engaged else "prestart",
            "sequence": record.get("sequence"),
        })

    def _poll_inbox(self) -> None:
        latest: dict | None = None
        while True:
            try:
                record = self.inbox.get_nowait()
            except queue.Empty:
                break
            if record.get("type") != "position":
                continue
            if self.calibrating:
                self.calibration_frames.append(record)
                continue
            record = apply_offset(record, self.take_offset)
            self.current_capture.append(record)
            latest = record
            if self.selected_track.get() == "lead":
                self._push_lead_preview(record)
        if self.calibrating:
            self._maybe_finish_calibration()
        now = time.monotonic()
        if latest is not None:
            if self.selected_track.get() == "lead" and not self.lead_preview_capture:
                self.status.set("WAITING — Lead must start at the left edge and move right")
            self.progress["value"] = len(self.current_capture) % 128
            if now - self._last_draw >= self.draw_interval_s:
                self._last_draw = now
                started = time.perf_counter()
                self._draw_canvas(self.lead_preview_capture if self.selected_track.get() == "lead" else None)
                self._draw_cost_ms = (time.perf_counter() - started) * 1000.0
        # Logged even when nothing arrives: "0 Hz" is the answer when the
        # device or the session is silent.
        self._update_diag(now)
        self.after(16, self._poll_inbox)

    def _update_diag(self, now: float) -> None:
        since, frames = self._diag_window
        if now - since < 1.0:
            return
        rate = (len(self.current_capture) - frames) / (now - since)
        queue_depth = self.inbox.qsize()
        clipped = _clip_percent(self.current_capture)
        self.diag.set(f"{rate:5.1f} Hz  ·  queue {queue_depth:3d}  ·  "
                      f"draw {self._draw_cost_ms:4.2f} ms  ·  clip {clipped:4.1f}%  ·  "
                      f"{len(self.current_capture)} frames")
        try:
            _append_diag_row(self.diag_path, {
                "wall_ms": int(time.time() * 1000),
                "elapsed_s": round(now - self.session_started, 3),
                "state": "recording" if self.recording else "idle",
                "rate_hz": round(rate, 2),
                "queue": queue_depth,
                "draw_ms": round(self._draw_cost_ms, 3),
                "frames": len(self.current_capture),
                "preview_points": len(self.lead_preview_capture),
                "drawn_points": self._drawn_points,
                "clipped_pct": round(clipped, 2),
                "canvas_w": self.canvas.winfo_width(),
                "canvas_h": self.canvas.winfo_height(),
            })
        except OSError:
            pass
        self._diag_window = (now, len(self.current_capture))

    def stop_record(self) -> None:
        if not self.recording:
            return
        track = self.selected_track.get()
        self.recording = False
        if self.receiver is not None:
            self.receiver.terminate()
            self.receiver = None
        if track == "lead":
            self.lead_samples.extend(self.current_capture)
        else:
            self.records[track].extend(self.current_capture)
        self.status.set(f"CAPTURED — {track}: {len(self.current_capture)} reports")
        if track == "lead":
            accepted = sum(1 for row in self.lead_preview_capture if row.get("start_gate_state") == "accepted")
            self._log(f"captured {len(self.current_capture)} reports for {track}; {accepted} passed left-edge start gate")
        else:
            self._log(f"captured {len(self.current_capture)} reports for {track}")

    def _update_density_label(self) -> None:
        lam = density_to_lambda(self.density.get())
        self.density_label.configure(text=f"λ {lam:.1f}")

    @property
    def lead_samples(self) -> List[dict]:
        """The take recorded into the currently selected layer."""
        while len(self.lead_layers) <= self.active_layer.get():
            self.lead_layers.append([])
        return self.lead_layers[self.active_layer.get()]

    @lead_samples.setter
    def lead_samples(self, value: List[dict]) -> None:
        while len(self.lead_layers) <= self.active_layer.get():
            self.lead_layers.append([])
        self.lead_layers[self.active_layer.get()] = list(value)

    def add_layer(self) -> None:
        self.lead_layers.append([])
        self.active_layer.set(len(self.lead_layers) - 1)
        self.layer_label.configure(text=f"layer {self.active_layer.get() + 1} of {len(self.lead_layers)}")
        self._log(f"new lead layer {self.active_layer.get() + 1}")

    def clear_layer(self) -> None:
        self.lead_layers[self.active_layer.get()].clear()
        self._log(f"cleared lead layer {self.active_layer.get() + 1}")

    def compile(self) -> None:
        if self.recording:
            self.stop_record()
        if len(self.lead_samples) < 2:
            messagebox.showwarning("Lead required", "Record or import at least two Lead position reports first.")
            return
        lam = density_to_lambda(self.density.get())
        self.event_table = compile_loop(self.lead_samples, self.records, mode=self.mapping_mode.get(),
                                        note_source=self.note_source.get(), lam=lam, gate_source=self.gate_source.get(),
                                        time_map="loop", auto_length=self.auto_length.get(),
                                        lead_layers=[layer for layer in self.lead_layers if layer])
        self._refresh_events()
        diagnostics = self.event_table.get("diagnostics", {})
        self.status.set(f"COMPILED — {diagnostics.get('status', 'ok')} · "
                        f"{len(self.event_table['tracks']['lead'])} Lead events · "
                        f"loop covered {float(diagnostics.get('coverage', 0.0)) * 100:.0f}%")
        self._log(json.dumps(self.event_table["diagnostics"], ensure_ascii=False))

    def _refresh_events(self) -> None:
        for item in self.tree.get_children():
            self.tree.delete(item)
        if not self.event_table:
            return
        for event in self.event_table["events"]:
            landmarks = ",".join(event.get("source_landmarks", []))
            self.tree.insert("", "end", values=(event.get("track"), event.get("tick"), event.get("note", "—"), event.get("duration", "—"), event.get("velocity", "—"), event.get("source"), landmarks or "—", event.get("quantization_delta", "—"), event.get("color_layer", "—")))

    def play_preview(self) -> None:
        if not self.event_table:
            self.compile()
        if not self.event_table:
            return
        output = ROOT / "pc_receiver" / "synthwave_preview.wav"
        render_loop(self.event_table, output)
        self.status.set(f"RENDERED — {output.name}")
        self._log(f"WAV written: {output}")
        try:
            import os
            os.startfile(str(output))
        except (AttributeError, OSError):
            pass

    def import_jsonl(self) -> None:
        path = filedialog.askopenfilename(filetypes=(("JSONL capture", "*.jsonl"), ("JSON", "*.json"), ("All files", "*.*")))
        if not path:
            return
        records = load_jsonl_records(path)
        if not records:
            messagebox.showerror("Import failed", "No position records found in this file.")
            return
        track = self.selected_track.get()
        if track == "lead":
            self.lead_samples.extend(records)
            self.lead_start_gate = LeadStartGate()
            self.lead_filter = StreamingLeadFilter()
            self.lead_cursor = make_cursor()
            self.lead_preview_capture = []
            for record in records:
                self._push_lead_preview(record)
        else:
            self.records[track].extend(records)
        self.status.set(f"IMPORTED — {len(records)} reports into {track}")
        self._log(f"imported {len(records)} reports into {track}")
        self._draw_canvas(self.lead_preview_capture if track == "lead" else records)

    def export_events(self) -> None:
        if not self.event_table:
            self.compile()
        if not self.event_table:
            return
        path = filedialog.asksaveasfilename(defaultextension=".json", filetypes=(("Event JSON", "*.json"),))
        if path:
            write_event_table(self.event_table, path)
            self.status.set(f"EXPORTED — {Path(path).name}")

    def render_wav(self) -> None:
        if not self.event_table:
            self.compile()
        if not self.event_table:
            return
        path = filedialog.asksaveasfilename(defaultextension=".wav", filetypes=(("WAV audio", "*.wav"),))
        if path:
            render_loop(self.event_table, path)
            self.status.set(f"RENDERED — {Path(path).name}")

    def clear_track(self) -> None:
        track = self.selected_track.get()
        if track == "lead":
            self.lead_samples.clear()
        else:
            self.records[track].clear()
        self.event_table = None
        self._refresh_events()
        self.status.set(f"CLEARED — {track}")

    def clear_all(self) -> None:
        self.lead_samples.clear()
        for values in self.records.values():
            values.clear()
        self.event_table = None
        self._refresh_events()
        self.status.set("CLEARED — all captures")

    def _draw_canvas(self, samples: List[dict] | None = None) -> None:
        if samples is None:
            samples = (self.lead_preview_capture or self.current_capture or self.lead_samples
                       if self.selected_track.get() == "lead" else self.current_capture)
        self.canvas.delete("all")
        width, height = max(10, self.canvas.winfo_width()), max(10, self.canvas.winfo_height())
        plot_left, plot_top, plot_w, plot_h = _plot_rect(width, height, (0.0, 1.0), (0.0, 1.0))
        self.canvas.create_rectangle(plot_left, plot_top, plot_left + plot_w, plot_top + plot_h,
                                     fill="#0c1018", outline="#1d2740")
        self.canvas.create_text(plot_left + 12, plot_top + 10, anchor="nw",
                                text="XY path  ·  color = Z depth", fill="#8490a8",
                                font=("Segoe UI", 10, "bold"))
        # A square XY grid keeps the cursor's spatial meaning stable.  The
        # depth channel is deliberately encoded by color instead of moving a
        # point out of the XY plane, so pure Z motion cannot look like XY drift.
        for fraction in (0.0, 0.25, 0.5, 0.75, 1.0):
            x = plot_left + fraction * plot_w
            y = plot_top + (1.0 - fraction) * plot_h
            self.canvas.create_line(x, plot_top, x, plot_top + plot_h, fill="#182235")
            self.canvas.create_line(plot_left, y, plot_left + plot_w, y, fill="#182235")
            self.canvas.create_text(x, plot_top + plot_h - 7, text=f"{fraction:.2f}", fill="#536078",
                                    anchor="s", font=("Segoe UI", 8))
            self.canvas.create_text(plot_left + 7, y, text=f"{fraction:.2f}", fill="#536078",
                                    anchor="w", font=("Segoe UI", 8))
        self.canvas.create_text(plot_left + plot_w / 2, plot_top + plot_h - 23,
                                text="X / horizontal", fill="#9da7bb", anchor="s")
        self.canvas.create_text(plot_left + 23, plot_top + plot_h / 2,
                                text="Y / pitch", fill="#9da7bb", angle=90, anchor="center")
        # Fixed G3–C5 PitchSpace guides, drawn in the same XY coordinates as
        # the trajectory.  They are guides, not a second time-vs-pitch plot.
        for midi in DEFAULT_PITCH_SPACE.scale_pitches:
            ratio = (midi - DEFAULT_PITCH_SPACE.min_midi) / max(1, DEFAULT_PITCH_SPACE.max_midi - DEFAULT_PITCH_SPACE.min_midi)
            y = plot_top + (1.0 - ratio) * plot_h
            self.canvas.create_line(plot_left, y, plot_left + plot_w, y, fill="#27344d", dash=(2, 4))
            self.canvas.create_text(plot_left + 5, y - 2, anchor="sw", text=str(midi), fill="#536078", font=("Segoe UI", 8))
        # Compact depth legend.  It stays inside the plot so the meaning is
        # visible next to the path on narrow windows too.
        legend_x = plot_left + plot_w - 20
        legend_y = plot_top + 18
        for index in range(12):
            z = index / 11.0
            y = legend_y + (1.0 - z) * 84.0
            self.canvas.create_line(legend_x, y, legend_x + 12, y, fill=_z_color(z), width=4)
        self.canvas.create_text(legend_x - 5, legend_y - 9, text="Z high", fill="#ff9f68", anchor="e", font=("Segoe UI", 8))
        self.canvas.create_text(legend_x - 5, legend_y + 93, text="Z low", fill="#4f7cff", anchor="e", font=("Segoe UI", 8))
        if len(samples) < 2:
            self.canvas.create_text(width / 2, height / 2, text="Record Lead or import a JSONL capture", fill="#536078")
            return
        pixels = self._path_cache.points(samples, width, height)
        self._drawn_points = len(pixels)
        if not pixels:
            self.canvas.create_text(width / 2, height / 2, text="Capture is shorter than one pixel", fill="#536078")
            return
        # No spline: corners are intentional.  Depth colour is quantised into
        # ten bands and consecutive segments inside a band are merged into one
        # polyline: drawing a line per segment cost 27 ms at 2000 points, which
        # cannot hold 60 fps, and the bands are indistinguishable at this size.
        runs: list[tuple[int, list[float]]] = []
        dots: dict[tuple[int, int, int], float] = {}
        current: int | None = None
        coords: list[float] = []

        def flush() -> None:
            if len(coords) >= 4 and current is not None:
                runs.append((current, coords[:]))

        for before, after in zip(pixels, pixels[1:]):
            if before[3] != after[3]:
                flush()
                coords = []
                current = None
                continue
            bucket = int(round((before[2] + after[2]) * 0.5 * 9))
            if abs(before[0] - after[0]) < 0.01 and abs(before[1] - after[1]) < 0.01:
                # Stationary points show pure depth motion; cap them, otherwise
                # a slow take builds hundreds of ovals and the redraw stalls.
                if len(dots) < 200:
                    dots[(bucket, round(after[0]), round(after[1]))] = after[2]
            if bucket != current:
                flush()
                coords = [before[0], before[1], after[0], after[1]]
                current = bucket
            else:
                coords.extend((after[0], after[1]))
        flush()
        for bucket, points in runs:
            self.canvas.create_line(*points, fill=_z_color(bucket / 9.0), width=2)
        for (_bucket, px, py), z in dots.items():
            radius = 2.0
            self.canvas.create_oval(px - radius, py - radius, px + radius, py + radius,
                                    fill=_z_color(z), outline="")
        self.canvas.create_oval(pixels[0][0] - 4, pixels[0][1] - 4, pixels[0][0] + 4, pixels[0][1] + 4,
                                fill="#6ce5b1", outline="")
        self.canvas.create_oval(pixels[-1][0] - 4, pixels[-1][1] - 4, pixels[-1][0] + 4, pixels[-1][1] + 4,
                                fill="#ef7896", outline="")
        latest = next((row for row in reversed(samples)
                       if row.get("cursor_x") is not None or row.get("q_x") is not None
                       or row.get("x") is not None), None)
        if latest is not None:
            x, y, z = _preview_xy_z(latest)
            gain = latest.get("cursor_gain")
            engaged = latest.get("cursor_engaged", True)
            mode = "TRACK" if engaged is not False else "LIFT / CLUTCH"
            gate = str(latest.get("start_gate_state", ""))
            gain_text = f"  GAIN {float(gain):.2f}×" if gain is not None else ""
            self.canvas.create_text(plot_left + 12, plot_top + 34,
                                    text=f"X {x:.3f}  Y {y:.3f}  Z {z:.3f}   {mode}{gain_text}",
                                    fill="#e9edf5", anchor="nw", font=("Segoe UI", 9))
            if gate and gate not in {"accepted", ""}:
                self.canvas.create_text(plot_left + 12, plot_top + 52,
                                        text=f"Lead start: {gate}", fill="#f3c969", anchor="nw",
                                        font=("Segoe UI", 8))
        if self.event_table and self.event_table.get("landmarks"):
            colors = {"move": "#6ce5b1", "hold": "#f3c969", "turn": "#ef7896", "apex": "#ff9f68", "valley": "#8aa7ff", "rest": "#667085", "release": "#d58cff"}
            event_samples = self.event_table.get("samples", [])
            for landmark in self.event_table["landmarks"]:
                tick = int(landmark.get("tick", 0))
                if not event_samples or tick >= len(event_samples):
                    continue
                x, y, _ = _preview_xy_z(event_samples[tick])
                px, py = _project_xy_unit(x, y, width, height)
                color = colors.get(str(landmark.get("kind")), "#d9e2f2")
                self.canvas.create_oval(px - 5, py - 5, px + 5, py + 5, fill=color, outline="#10131b", width=1)
                self.canvas.create_text(px + 7, py - 7, anchor="sw", text=str(landmark.get("kind", "")), fill=color, font=("Segoe UI", 8))


def main() -> int:
    app = SynthwaveUI()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
