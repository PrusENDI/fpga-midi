"""Small hardware-free Tk front end for the V2 parameter/telemetry model.

The UI owns no serial port.  A transport object implementing ``send`` and
``recv`` can be supplied by a board adapter; telemetry is posted into the Tk
queue through :meth:`V2Ui.post_telemetry`, keeping transport work outside the
Tk callback thread.
"""
from __future__ import annotations

import queue
import tkinter as tk
from tkinter import ttk
from typing import Any

from tools.v2_contract import CSR, V2_CSR_BPM, V2_CSR_MODE, V2_OP_WRITE
from .fpga_v2_model import FakeTransport, V2Parameters, apply_patch_delta, build_upload, decode_telemetry


def z_color(z: int) -> str:
    """Map signed display Z to the frozen blue-to-orange depth indicator."""
    value = max(-32768, min(32767, int(z)))
    t = (value + 32768) / 65535.0
    red = int(40 + 215 * t)
    green = int(120 + 75 * (1.0 - abs(2.0 * t - 1.0)))
    blue = int(230 * (1.0 - t) + 50 * t)
    return f"#{red:02x}{green:02x}{blue:02x}"


class V2Ui:
    def __init__(self, root: tk.Misc, transport: Any | None = None) -> None:
        self.root = root
        self.transport = transport or FakeTransport()
        self.parameters = V2Parameters()
        self._sequence = 0
        self._telemetry_queue: queue.Queue[bytes] = queue.Queue()
        self.status = tk.StringVar(value="IDLE · no hardware transport")
        self.cursor = tk.StringVar(value="X 0  Y 0  Z 0")
        self.voices = tk.StringVar(value="voices 0x00000000 · FIFO 0 · fault 0")
        self._build()
        self.root.after(25, self._drain_telemetry)

    def _build(self) -> None:
        self.root.title("MGC3130 V2 FPGA")
        self.root.configure(bg="#10131b")
        frame = ttk.Frame(self.root, padding=12)
        frame.grid(sticky="nsew")
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)
        ttk.Label(frame, text="V2 FPGA control / telemetry").grid(row=0, column=0, columnspan=3, sticky="w")
        ttk.Label(frame, textvariable=self.status).grid(row=1, column=0, columnspan=3, sticky="w")
        ttk.Label(frame, textvariable=self.cursor).grid(row=2, column=0, columnspan=3, sticky="w")
        ttk.Label(frame, textvariable=self.voices).grid(row=3, column=0, columnspan=3, sticky="w")

        ttk.Label(frame, text="BPM").grid(row=4, column=0, sticky="w")
        self.bpm = tk.IntVar(value=self.parameters.bpm)
        ttk.Spinbox(frame, from_=60, to=240, textvariable=self.bpm, width=8,
                    command=self._send_bpm).grid(row=4, column=1, sticky="w")
        ttk.Button(frame, text="LIVE", command=lambda: self._send_mode(1)).grid(row=5, column=0, sticky="ew")
        ttk.Button(frame, text="LOOP", command=lambda: self._send_mode(2)).grid(row=5, column=1, sticky="ew")
        ttk.Button(frame, text="STOP", command=lambda: self._send_mode(0)).grid(row=5, column=2, sticky="ew")
        self.z_indicator = tk.Label(frame, text="Z", width=10, bg=z_color(0), fg="white")
        self.z_indicator.grid(row=6, column=0, columnspan=3, sticky="ew", pady=(8, 0))

    def _send(self, address: int, data: int) -> None:
        from tools.v2_contract import encode_control
        frame = encode_control(V2_OP_WRITE, address, data, self._sequence)
        self._sequence = (self._sequence + 1) & 0xFF
        self.transport.send(frame)

    def _send_mode(self, mode: int) -> None:
        self.parameters = apply_patch_delta(self.parameters, {"mode": mode})
        self._send(V2_CSR_MODE, mode)
        self.status.set(("LIVE" if mode == 1 else "LOOP" if mode == 2 else "IDLE") + " · command queued")

    def _send_bpm(self) -> None:
        value = max(60, min(240, int(self.bpm.get())))
        self.parameters = apply_patch_delta(self.parameters, {"bpm": value})
        self.bpm.set(value)
        self._send(V2_CSR_BPM, value)

    def post_telemetry(self, frame: bytes) -> None:
        """Post raw telemetry from a transport thread; never touches Tk here."""
        self._telemetry_queue.put(frame)

    def _drain_telemetry(self) -> None:
        try:
            while True:
                telemetry = decode_telemetry(self._telemetry_queue.get_nowait())
                self.cursor.set(f"X {telemetry.x}  Y {telemetry.y}  Z {telemetry.z}")
                self.voices.set(
                    f"voices 0x{telemetry.voice_bitmap:08x} · FIFO {telemetry.fifo_level} · fault {telemetry.fault_code}"
                )
                self.z_indicator.configure(bg=z_color(telemetry.z))
                self.status.set(f"telemetry type {telemetry.type} · seq {telemetry.sequence}")
        except queue.Empty:
            pass
        self.root.after(25, self._drain_telemetry)

    def upload_wavetable(self, table_id: int, samples: list[int], version: int) -> int:
        frames = build_upload(table_id, samples, version, self._sequence)
        for frame in frames:
            self.transport.send(frame)
        self._sequence = (self._sequence + len(frames)) & 0xFF
        self.status.set(f"table {table_id} upload queued · {len(frames)} frames")
        return len(frames)


def create_ui(root: tk.Misc | None = None, transport: Any | None = None) -> V2Ui:
    """Construct the UI without opening a serial port or entering mainloop."""
    return V2Ui(root or tk.Tk(), transport)


def main() -> None:
    app = create_ui()
    app.root.mainloop()


if __name__ == "__main__":
    main()
