"""Draw a waveform, use it as an FM modulator.

The drawing is captured as a path, normalised to one period, then band limited
to 32 harmonics so chaotic scribbles become a rough timbre instead of aliasing
noise. A carrier sine is phase modulated by that table; FM index and a square
base mix are the only knobs.

    python tools/fm_draw.py
"""

from __future__ import annotations

import math
import sys
import tempfile
import tkinter as tk
from pathlib import Path
from tkinter import ttk

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

TABLE_SIZE = 1024
PARTIALS = 32
SR = 48000
CANVAS_W = 520
CANVAS_H = 200


def band_limit(points, size: int = TABLE_SIZE, partials: int = PARTIALS):
    """Resample a path to `size` points and keep only `partials` harmonics."""
    if len(points) < 2:
        return [math.sin(2.0 * math.pi * index / size) for index in range(size)]
    values = []
    span = len(points) - 1
    for index in range(size):
        position = index * span / (size - 1)
        left = int(position)
        right = min(len(points) - 1, left + 1)
        frac = position - left
        values.append(points[left] * (1.0 - frac) + points[right] * frac)
    mean = sum(values) / len(values)
    values = [value - mean for value in values]
    amps = []
    for harmonic in range(1, partials + 1):
        real = sum(values[n] * math.cos(2.0 * math.pi * harmonic * n / size) for n in range(size))
        imag = sum(values[n] * math.sin(2.0 * math.pi * harmonic * n / size) for n in range(size))
        amps.append((real * 2.0 / size, imag * 2.0 / size))
    table = []
    for index in range(size):
        phase = 2.0 * math.pi * index / size
        value = 0.0
        for harmonic, (a, b) in enumerate(amps, start=1):
            value += a * math.cos(phase * harmonic) + b * math.sin(phase * harmonic)
        table.append(value)
    peak = max((abs(value) for value in table), default=0.0) or 1.0
    return [value / peak for value in table]


def render_fm(table, notes, seconds_per_tick, output, fm_index=2.5, square_mix=0.2,
              carrier_hz=None, ratio=1.0):
    total_seconds = max(1, notes[-1]["tick"] + notes[-1].get("duration", 1)) * seconds_per_tick + 0.4
    total = int(total_seconds * SR)
    buffer = [0.0] * total
    for note in notes:
        start = int(note["tick"] * seconds_per_tick * SR)
        length = int(max(1, note.get("duration", 1)) * seconds_per_tick * SR)
        freq = carrier_hz or 440.0 * 2.0 ** ((note["note"] - 69) / 12.0)
        cphase = 0.0
        mphase = 0.0
        cstep = freq * TABLE_SIZE / SR
        mstep = freq * ratio * TABLE_SIZE / SR
        attack = max(1, int(0.006 * SR))
        release = max(1, int(0.06 * SR))
        for index in range(length):
            if start + index >= total:
                break
            if index < attack:
                env = index / attack
            elif index > length - release:
                env = max(0.0, (length - index) / release)
            else:
                env = 1.0
            modulator = table[int(mphase) % TABLE_SIZE]
            # The depth must be in table units: one unit of index moves the
            # carrier phase by a fixed fraction of a cycle, otherwise every
            # index sounds identical because the shift is a thousandth.
            phase = cphase + fm_index * modulator * 96.0
            carrier = math.sin(2.0 * math.pi * phase / TABLE_SIZE)
            square = 1.0 if (int(cphase) % TABLE_SIZE) < TABLE_SIZE // 2 else -1.0
            buffer[start + index] += ((1.0 - square_mix) * carrier + square_mix * square * 0.4) * env * 0.3
            cphase += cstep
            mphase += mstep
    peak = max((abs(value) for value in buffer), default=0.0) or 1.0
    import wave, struct
    with wave.open(str(output), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        handle.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, value / peak)) * 30000))
                                    for value in buffer))
    return {"seconds": len(buffer) / SR}


class FmDraw(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Draw a modulator")
        self.geometry("560x420")
        self.points = []
        self.table = band_limit([math.sin(2.0 * math.pi * i / 64.0) * 100.0 for i in range(64)])
        self.drawing = False

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Draw anything: a wave, a square, a scribble. Apply, then play.").pack(anchor="w")
        self.canvas = tk.Canvas(frame, width=CANVAS_W, height=CANVAS_H, bg="#181d2a", highlightthickness=0)
        self.canvas.pack(pady=8)
        self.canvas.bind("<ButtonPress-1>", self._start)
        self.canvas.bind("<B1-Motion>", self._move)
        self.canvas.bind("<ButtonRelease-1>", self._end)

        row = ttk.Frame(frame)
        row.pack(fill="x")
        self.fm_index = tk.DoubleVar(value=2.5)
        self.square_mix = tk.DoubleVar(value=0.2)
        for label, variable, high in (("FM index", self.fm_index, 8.0), ("Square", self.square_mix, 1.0)):
            ttk.Label(row, text=label, width=9).pack(side="left")
            ttk.Scale(row, from_=0.0, to=high, variable=variable, orient="horizontal").pack(
                side="left", fill="x", expand=True, padx=4)

        row2 = ttk.Frame(frame)
        row2.pack(fill="x", pady=(8, 2))
        ttk.Button(row2, text="Apply", command=self.apply).pack(side="left", padx=2)
        ttk.Button(row2, text="▶  Play", command=self.play).pack(side="left", padx=2)
        ttk.Button(row2, text="Clear", command=self.clear).pack(side="left", padx=2)
        ttk.Button(row2, text="Save WAV…", command=self.save).pack(side="left", padx=2)
        self.status = tk.StringVar(value="draw on the canvas")
        ttk.Label(frame, textvariable=self.status).pack(anchor="w", pady=(8, 0))

    def _redraw(self):
        self.canvas.delete("path")
        if len(self.points) > 1:
            flat = [value for point in self.points for value in point]
            self.canvas.create_line(*flat, fill="#5b8cff", width=2, tags="path")
        elif self.points:
            x, y = self.points[0]
            self.canvas.create_oval(x - 3, y - 3, x + 3, y + 3, fill="#5b8cff", tags="path")

    def _start(self, event):
        self.points = [(float(event.x), float(event.y))]
        self.drawing = True
        self._redraw()

    def _move(self, event):
        if not self.drawing:
            return
        self.points.append((float(event.x), float(event.y)))
        self._redraw()

    def _end(self, event):
        self.drawing = False
        self.status.set(f"{len(self.points)} points captured")

    def _path_values(self):
        if len(self.points) < 4:
            return None
        ys = [value for _x, value in self.points]
        mid = (max(ys) + min(ys)) / 2.0
        return [-(value - mid) for value in ys]

    def apply(self):
        values = self._path_values()
        if values is None:
            self.status.set("draw a longer path first")
            return
        self.table = band_limit(values)
        self.status.set("band limited to 32 harmonics")

    def _notes(self):
        pattern = [57, 60, 62, 64, 67, 64, 62, 60]
        return [{"tick": index * 2, "duration": 2, "note": pattern[index % len(pattern)]}
                for index in range(8)]

    def _render(self, path):
        if not self.table:
            self.apply()
        render_fm(self.table, self._notes(), 0.16, path,
                  fm_index=self.fm_index.get(), square_mix=self.square_mix.get())

    def play(self):
        try:
            path = Path(tempfile.gettempdir()) / "fm_draw.wav"
            self._render(path)
            try:
                import winsound
                winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
                self.status.set("playing")
            except Exception:
                self.status.set(f"rendered to {path}")
        except Exception as error:
            self.status.set(f"error: {error}")

    def clear(self):
        self.canvas.delete("all")
        self.points = []
        self.status.set("cleared")

    def save(self):
        from tkinter import filedialog
        path = filedialog.asksaveasfilename(defaultextension=".wav", filetypes=(("WAV", "*.wav"),))
        if path:
            try:
                self._render(Path(path))
                self.status.set(f"saved {Path(path).name}")
            except Exception as error:
                self.status.set(f"error: {error}")


if __name__ == "__main__":
    FmDraw().mainloop()
