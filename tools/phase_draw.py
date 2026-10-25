"""Phase canvas: draw one cycle with the mouse, hear it as a wavetable.

This is the plugin way of drawing a waveform. The canvas width is one period,
so a vertical stroke becomes a steep edge and a flat stroke becomes a plateau,
regardless of how fast the hand moves. The drawn polyline is interpolated to
1024 points and played through a phase accumulator.

    python tools/phase_draw.py
"""

from __future__ import annotations

import math
import struct
import sys
import tempfile
import tkinter as tk
import wave
from pathlib import Path
from tkinter import ttk

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

SR = 48000
SIZE = 1024
CANVAS_W = 520
CANVAS_H = 200
PREVIEW = 3.0


def table_from_path(points, size: int = SIZE, band_limit: int = 32):
    """points is [(x, y)] with x in canvas pixels and y in canvas pixels."""
    if len(points) < 2:
        return [math.sin(2.0 * math.pi * index / size) for index in range(size)]
    ordered = sorted(points, key=lambda item: item[0])
    values = []
    for index in range(size):
        phase = index / (size - 1.0) * CANVAS_W
        left = ordered[0]
        right = ordered[-1]
        for position in range(len(ordered) - 1):
            if ordered[position][0] <= phase <= ordered[position + 1][0]:
                left, right = ordered[position], ordered[position + 1]
                break
        span = right[0] - left[0]
        ratio = 0.0 if span <= 0 else (phase - left[0]) / span
        pixel = left[1] + (right[1] - left[1]) * ratio
        values.append(1.0 - 2.0 * pixel / CANVAS_H)
    if band_limit > 0:
        keep = []
        for harmonic in range(1, band_limit + 1):
            real = sum(values[n] * math.cos(2.0 * math.pi * harmonic * n / size) for n in range(size))
            imag = sum(values[n] * math.sin(2.0 * math.pi * harmonic * n / size) for n in range(size))
            keep.append((2.0 * real / size, 2.0 * imag / size))
        rebuilt = []
        for index in range(size):
            angle = 2.0 * math.pi * index / size
            total = 0.0
            for harmonic, (a, b) in enumerate(keep, start=1):
                total += a * math.cos(angle * harmonic) + b * math.sin(angle * harmonic)
            rebuilt.append(total)
        values = rebuilt
    peak = max((abs(value) for value in values), default=0.0) or 1.0
    return [value / peak for value in values]


def render_table(table, output, seconds: float = PREVIEW):
    pattern = [57, 60, 62, 64, 67, 64, 62, 60]
    step = 0.16
    total = int((seconds + 0.4) * SR)
    buffer = [0.0] * total
    index = 0
    tick = 0.0
    while tick * step < seconds:
        note = pattern[index % len(pattern)]
        start = int(tick * step * SR)
        length = int(0.30 * SR)
        freq = 440.0 * 2.0 ** ((note - 69) / 12.0)
        inc = freq * SIZE / SR
        phase = 0.0
        attack = max(1, int(0.006 * SR))
        release = max(1, int(0.06 * SR))
        for sample in range(length):
            if start + sample >= total:
                break
            if sample < attack:
                env = sample / attack
            elif sample > length - release:
                env = max(0.0, (length - sample) / release)
            else:
                env = 1.0
            buffer[start + sample] += table[int(phase) % SIZE] * env * 0.3
            phase += inc
        index += 1
        tick += 2
    peak = max((abs(value) for value in buffer), default=0.0) or 1.0
    with wave.open(str(output), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        handle.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, value / peak)) * 30000))
                                    for value in buffer))


class PhaseDraw(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Draw one cycle")
        self.geometry("560x400")
        self.points = []
        self.drawing = False
        self.band_limit = tk.IntVar(value=32)

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="The canvas width is one period. Draw left to right.").pack(anchor="w")
        self.canvas = tk.Canvas(frame, width=CANVAS_W, height=CANVAS_H, bg="#181d2a",
                                highlightthickness=1, highlightbackground="#333a4d")
        self.canvas.pack(pady=8)
        self.canvas.bind("<ButtonPress-1>", self._start)
        self.canvas.bind("<B1-Motion>", self._move)
        self.canvas.bind("<ButtonRelease-1>", self._end)

        row = ttk.Frame(frame)
        row.pack(fill="x", pady=2)
        ttk.Button(row, text="▶  Play", command=self.play).pack(side="left", padx=2)
        ttk.Button(row, text="Sine", command=lambda: self._preset("sine")).pack(side="left", padx=2)
        ttk.Button(row, text="Saw", command=lambda: self._preset("saw")).pack(side="left", padx=2)
        ttk.Button(row, text="Square", command=lambda: self._preset("square")).pack(side="left", padx=2)
        ttk.Button(row, text="Clear", command=self.clear).pack(side="left", padx=2)
        ttk.Button(row, text="Save WAV…", command=self.save).pack(side="left", padx=2)
        ttk.Label(row, text="band limit").pack(side="left", padx=(12, 2))
        ttk.Spinbox(row, from_=0, to=64, textvariable=self.band_limit, width=4).pack(side="left")

        self.status = tk.StringVar(value="draw a cycle")
        ttk.Label(frame, textvariable=self.status).pack(anchor="w", pady=(8, 0))

    def _redraw(self) -> None:
        self.canvas.delete("path")
        if len(self.points) > 1:
            flat = [value for point in self.points for value in point]
            self.canvas.create_line(*flat, fill="#5b8cff", width=2, tags="path")
        elif self.points:
            x, y = self.points[0]
            self.canvas.create_oval(x - 3, y - 3, x + 3, y + 3, fill="#5b8cff", tags="path")

    def _start(self, event) -> None:
        self.points = [(float(event.x), float(event.y))]
        self.drawing = True
        self._redraw()

    def _move(self, event) -> None:
        if not self.drawing:
            return
        self.points.append((float(event.x), float(event.y)))
        self._redraw()
        self.status.set(f"{len(self.points)} points")

    def _end(self, event) -> None:
        self.drawing = False
        self.points.append((float(event.x), float(event.y)))
        self._redraw()

    def _preset(self, name: str) -> None:
        points = []
        for index in range(65):
            x = index / 64.0 * CANVAS_W
            if name == "sine":
                y = CANVAS_H / 2.0 - math.sin(2.0 * math.pi * index / 64.0) * CANVAS_H * 0.4
            elif name == "saw":
                y = CANVAS_H - index / 64.0 * CANVAS_H
            else:
                y = 20.0 if index < 32 else CANVAS_H - 20.0
            points.append((x, y))
        self.points = points
        self._redraw()
        self.status.set(f"{name} preset")

    def _render(self, path: Path) -> None:
        table = table_from_path(self.points, band_limit=max(0, int(self.band_limit.get())))
        render_table(table, path)

    def play(self) -> None:
        try:
            path = Path(tempfile.gettempdir()) / "phase_draw.wav"
            self._render(path)
            try:
                import winsound
                winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
                self.status.set("playing")
            except Exception:
                self.status.set(f"rendered to {path}")
        except Exception as error:
            self.status.set(f"error: {error}")

    def clear(self) -> None:
        self.points = []
        self.canvas.delete("all")
        self.status.set("cleared")

    def save(self) -> None:
        from tkinter import filedialog
        path = filedialog.asksaveasfilename(defaultextension=".wav", filetypes=(("WAV", "*.wav"),))
        if path:
            try:
                self._render(Path(path))
                self.status.set(f"saved {Path(path).name}")
            except Exception as error:
                self.status.set(f"error: {error}")


if __name__ == "__main__":
    PhaseDraw().mainloop()
