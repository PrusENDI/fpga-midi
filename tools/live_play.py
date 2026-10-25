"""Live instrument: draw one cycle, then play the MGC3130 through it.

Left canvas: draw a single period with the mouse (x is phase). The table is
built immediately and the synthesiser starts using it while the sensor streams
in. Audio goes out through sounddevice; the sensor comes from the receiver
executable over its JSONL stream.

    python tools/live_play.py
"""

from __future__ import annotations

import json
import math
import queue
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import ttk

import sounddevice as sd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

SR = 48000
BLOCK = 512
SIZE = 1024
CANVAS_W = 460
CANVAS_H = 160
RECEIVER = ROOT / "pc_receiver" / "Static-Release" / "mgc3130_receiver.exe"
SCALE = [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24, 26]
BASE_NOTE = 55


def build_table(points, band_limit: int = 32):
    if len(points) < 2:
        return [math.sin(2.0 * math.pi * i / SIZE) for i in range(SIZE)]
    ordered = sorted(points, key=lambda item: item[0])
    values = []
    for index in range(SIZE):
        phase = index / (SIZE - 1.0) * CANVAS_W
        left, right = ordered[0], ordered[-1]
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
            real = sum(values[n] * math.cos(2.0 * math.pi * harmonic * n / SIZE) for n in range(SIZE))
            imag = sum(values[n] * math.sin(2.0 * math.pi * harmonic * n / SIZE) for n in range(SIZE))
            keep.append((2.0 * real / SIZE, 2.0 * imag / SIZE))
        values = [sum(a * math.cos(2.0 * math.pi * i / SIZE * h) + b * math.sin(2.0 * math.pi * i / SIZE * h)
                      for h, (a, b) in enumerate(keep, start=1)) for i in range(SIZE)]
    peak = max((abs(value) for value in values), default=0.0) or 1.0
    return [value / peak for value in values]


class Instrument:
    """One waveform, one voice, driven by the sensor stream."""

    def __init__(self) -> None:
        self.table = [math.sin(2.0 * math.pi * i / SIZE) for i in range(SIZE)]
        self.note = 60
        self.gain = 0.0
        self.phase = 0.0
        self.cursor = 0.5
        self.locked = False

    def set_table(self, table) -> None:
        self.table = table

    def feed(self, x: float, y: float, z: float, touching: bool) -> None:
        self.locked = touching
        if touching:
            return
        alpha = 0.5 - 0.4 * min(1.0, max(0.0, z))
        self.cursor += alpha * (y - self.cursor)

    def next_sample(self) -> float:
        index = int(max(0.0, min(0.9999, self.cursor)) * (len(SCALE) - 1))
        note = BASE_NOTE + SCALE[index]
        freq = 440.0 * 2.0 ** ((note - 69) / 12.0)
        self.phase += freq * SIZE / SR
        return self.table[int(self.phase) % SIZE] * 0.3


def audio_callback(outdata, frames, time_info, status) -> None:
    instrument = audio_callback.instrument
    for index in range(frames):
        outdata[index][0] = instrument.next_sample()


class LiveApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Live instrument")
        self.geometry("500x380")
        self.instrument = Instrument()
        audio_callback.instrument = self.instrument
        self.points = []
        self.drawing = False
        self.stream = None
        self.process = None
        self.queue: queue.Queue = queue.Queue()

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Draw one period, then start the sensor.").pack(anchor="w")
        self.canvas = tk.Canvas(frame, width=CANVAS_W, height=CANVAS_H, bg="#181d2a",
                                highlightthickness=1, highlightbackground="#333a4d")
        self.canvas.pack(pady=8)
        self.canvas.bind("<ButtonPress-1>", self._start)
        self.canvas.bind("<B1-Motion>", self._move)
        self.canvas.bind("<ButtonRelease-1>", self._end)

        row = ttk.Frame(frame)
        row.pack(fill="x", pady=2)
        ttk.Button(row, text="Sine", command=lambda: self._preset("sine")).pack(side="left", padx=2)
        ttk.Button(row, text="Saw", command=lambda: self._preset("saw")).pack(side="left", padx=2)
        ttk.Button(row, text="Square", command=lambda: self._preset("square")).pack(side="left", padx=2)
        ttk.Button(row, text="Start sensor", command=self.start_sensor).pack(side="left", padx=8)
        ttk.Button(row, text="Stop", command=self.stop_all).pack(side="left", padx=2)

        self.status = tk.StringVar(value="idle")
        ttk.Label(frame, textvariable=self.status).pack(anchor="w", pady=(8, 0))
        self.after(30, self._poll)

    # ---- drawing ---------------------------------------------------------
    def _redraw(self) -> None:
        self.canvas.delete("path")
        if len(self.points) > 1:
            flat = [value for point in self.points for value in point]
            self.canvas.create_line(*flat, fill="#5b8cff", width=2, tags="path")

    def _start(self, event) -> None:
        self.points = [(float(event.x), float(event.y))]
        self.drawing = True
        self._redraw()

    def _move(self, event) -> None:
        if self.drawing:
            self.points.append((float(event.x), float(event.y)))
            self._redraw()

    def _end(self, event) -> None:
        self.drawing = False
        self.points.append((float(event.x), float(event.y)))
        self._redraw()
        self.instrument.set_table(build_table(self.points))
        self.status.set(f"table from {len(self.points)} points")

    def _preset(self, name: str) -> None:
        points = []
        for index in range(65):
            x = index / 64.0 * CANVAS_W
            if name == "sine":
                y = CANVAS_H / 2 - math.sin(2 * math.pi * index / 64) * CANVAS_H * 0.4
            elif name == "saw":
                y = CANVAS_H - index / 64.0 * CANVAS_H
            else:
                y = 15 if index < 32 else CANVAS_H - 15
            points.append((x, y))
        self.points = points
        self._redraw()
        self.instrument.set_table(build_table(points))
        self.status.set(f"{name} preset")

    # ---- runtime ---------------------------------------------------------
    def start_sensor(self) -> None:
        if not RECEIVER.exists():
            self.status.set("receiver executable not found")
            return
        if self.stream is None:
            self.stream = sd.OutputStream(channels=1, samplerate=SR, blocksize=BLOCK,
                                          callback=audio_callback)
            self.stream.start()
        if self.process is None:
            self.process = subprocess.Popen([str(RECEIVER), "--format", "jsonl"],
                                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                            text=True, encoding="utf-8")
            threading.Thread(target=self._pump, daemon=True).start()
        self.status.set("sensor running")

    def _pump(self) -> None:
        assert self.process and self.process.stdout
        for line in self.process.stdout:
            if '"position"' in line:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                self.queue.put(row)

    def _poll(self) -> None:
        latest = None
        while not self.queue.empty():
            latest = self.queue.get()
        if latest is not None:
            z = (float(latest.get("z") or 0)) / 65535.0
            self.instrument.feed(float(latest.get("x") or 0) / 65535.0,
                                 float(latest.get("y") or 0) / 65535.0, z,
                                 int(latest.get("touch_flags") or 0) != 0)
            self.status.set(f"y {self.instrument.cursor:.2f}  z {z:.2f}")
        self.after(30, self._poll)

    def stop_all(self) -> None:
        if self.stream is not None:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        if self.process is not None:
            self.process.terminate()
            self.process = None
        self.status.set("stopped")


if __name__ == "__main__":
    LiveApp().mainloop()
