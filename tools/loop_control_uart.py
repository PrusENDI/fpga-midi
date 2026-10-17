#!/usr/bin/env python3
"""PC control client for the FPGA Loop binary UART protocol.

The FPGA command link is 115200 8N1 by default.  A command is ten bytes:
    55 AA opcode 04 arg0_lo arg0_hi arg1_lo arg1_hi sequence checksum
and an ACK is ten bytes:
    AA 55 opcode status data0 data1 data2 data3 sequence checksum

Examples:
    python tools/loop_control_uart.py --port COM7 status
    python tools/loop_control_uart.py --port COM7 bpm 120
    python tools/loop_control_uart.py --port COM7 record
    python tools/loop_control_uart.py --port COM7
"""

from __future__ import annotations

import argparse
import queue
import shlex
import struct
import sys
import threading
import time
from dataclasses import dataclass
from typing import Iterable, Optional


STATUS_NAMES = {
    0: "ACCEPTED",
    1: "APPLIED",
    2: "REJECTED",
    3: "BUSY",
    4: "ERROR",
}

MODE_NAMES = {
    0: "IDLE",
    1: "LIVE",
    2: "RECORD_ARMED",
    3: "RECORDING",
    4: "COMMIT_PENDING",
    5: "PLAY",
    6: "OVERDUB_ARMED",
    7: "OVERDUB",
    8: "ERROR",
}

OPCODES = {
    "status": 0,
    "set-mode": 1,
    "bpm": 2,
    "track": 3,
    "play": 4,
    "stop": 5,
    "record": 6,
    "overdub": 7,
    "clear-track": 8,
    "clear-all": 9,
    "commit": 10,
    "reset": 11,
    "read-csr": 12,
    "thresholds": 13,
}


def command_for_ui(action: str, *, bpm: int = 120, track: int = 0,
                   enter: int = 0x2000, exit: int = 0x3000,
                   csr: int = 0) -> tuple[int, int, int]:
    """Map a button/action name to ``(opcode, arg0, arg1)``."""
    action = action.lower()
    if action == "live":
        return OPCODES["set-mode"], 1, 0
    if action == "idle":
        return OPCODES["set-mode"], 0, 0
    if action == "bpm":
        return OPCODES["bpm"], int(bpm), 0
    if action == "track":
        return OPCODES["track"], int(track), 0
    if action == "thresholds":
        return OPCODES["thresholds"], int(enter), int(exit)
    if action == "read-csr":
        return OPCODES["read-csr"], int(csr), 0
    if action == "diag-input":
        return OPCODES["read-csr"], 0x3C, 0
    if action == "diag-audio":
        return OPCODES["read-csr"], 0x40, 0
    if action == "diag-router":
        return OPCODES["read-csr"], 0x44, 0
    if action not in OPCODES or action in ("set-mode",):
        raise ValueError(f"unknown UI action: {action}")
    return OPCODES[action], 0, 0


def xor_checksum(values: Iterable[int]) -> int:
    result = 0
    for value in values:
        result ^= value & 0xFF
    return result


def build_command(opcode: int, arg0: int = 0, arg1: int = 0, sequence: int = 0) -> bytes:
    """Build one protocol command and calculate its XOR checksum."""
    if not 0 <= opcode <= 0xFF:
        raise ValueError("opcode must fit in one byte")
    if not 0 <= arg0 <= 0xFFFF or not 0 <= arg1 <= 0xFFFF:
        raise ValueError("arguments must be unsigned 16-bit values")
    sequence &= 0xFF
    body = bytes((opcode, 4)) + struct.pack("<HHB", arg0, arg1, sequence)
    return bytes((0x55, 0xAA)) + body + bytes((xor_checksum(body),))


@dataclass(frozen=True)
class Ack:
    opcode: int
    status: int
    data: int
    sequence: int

    @property
    def status_name(self) -> str:
        return STATUS_NAMES.get(self.status, f"STATUS_{self.status}")


def parse_ack(frame: bytes) -> Ack:
    """Parse and validate a complete ten-byte ACK frame."""
    if len(frame) != 10 or frame[:2] != b"\xAA\x55":
        raise ValueError(f"invalid ACK framing: {frame.hex(' ')}")
    if xor_checksum(frame[2:9]) != frame[9]:
        raise ValueError(f"ACK checksum mismatch: {frame.hex(' ')}")
    return Ack(
        opcode=frame[2],
        status=frame[3],
        data=int.from_bytes(frame[4:8], "little"),
        sequence=frame[8],
    )


def _read_exact(port, count: int) -> bytes:
    data = bytearray()
    while len(data) < count:
        chunk = port.read(count - len(data))
        if not chunk:
            raise TimeoutError("timed out while reading UART response")
        data.extend(chunk)
    return bytes(data)


def read_ack(port) -> Ack:
    """Find the next AA 55 sync pair and parse its ten-byte ACK."""
    saw_aa = False
    while True:
        byte = _read_exact(port, 1)[0]
        if saw_aa and byte == 0x55:
            return parse_ack(b"\xAA\x55" + _read_exact(port, 8))
        saw_aa = byte == 0xAA


def parse_command(words: list[str], sequence: int) -> tuple[int, int, int, int]:
    if not words:
        raise ValueError("missing command")
    name = words[0].lower()

    def number(index: int, label: str, base: int = 0) -> int:
        try:
            return int(words[index], base)
        except (IndexError, ValueError) as exc:
            raise ValueError(f"{label} must be an integer") from exc

    if name == "status":
        args = (0, 0)
    elif name in ("live", "idle"):
        if len(words) != 1:
            raise ValueError(f"{name} takes no arguments")
        args = (1 if name == "live" else 0, 0)
        name = "set-mode"
    elif name == "set-mode":
        mode = words[1].upper() if len(words) > 1 else ""
        if mode in MODE_NAMES.values():
            args = (next(k for k, v in MODE_NAMES.items() if v == mode), 0)
        else:
            args = (number(1, "mode"), 0)
    elif name == "bpm":
        args = (number(1, "BPM"), 0)
    elif name == "track":
        args = (number(1, "track"), 0)
    elif name == "thresholds":
        args = (number(1, "enter threshold"), number(2, "exit threshold"))
    elif name == "read-csr":
        args = (number(1, "CSR address"), 0)
    elif name in ("diag-input", "diag-audio", "diag-router"):
        args = ({"diag-input": 0x3C, "diag-audio": 0x40,
                 "diag-router": 0x44}[name], 0)
        name = "read-csr"
    elif name in ("play", "stop", "record", "overdub", "clear-track", "clear-all", "commit", "reset"):
        if len(words) != 1:
            raise ValueError(f"{name} takes no arguments")
        args = (0, 0)
    else:
        raise ValueError(f"unknown command: {name}")

    opcode = OPCODES.get(name)
    if opcode is None:
        raise ValueError(f"unknown command: {name}")
    return opcode, args[0], args[1], sequence & 0xFF


def format_ack(ack: Ack) -> str:
    details = f"data=0x{ack.data:08X}"
    if ack.opcode == 0:
        mode = ack.data & 0xF
        details += f" mode={MODE_NAMES.get(mode, mode)}"
    return f"opcode={ack.opcode} status={ack.status_name} {details} seq={ack.sequence}"


def format_audio_diag(data: int) -> str:
    """Decode CSR_DIAG_AUDIO without hiding the raw 32-bit value."""
    flags = data & 0xFF
    names = []
    if flags & 0x80:
        names.append("flush")
    if flags & 0x40:
        names.append("live_enable")
    if flags & 0x20:
        names.append("live_ready")
    if flags & 0x10:
        names.append("live_valid")
    if flags & 0x08:
        names.append("adapter_overflow")
    router_debug = flags & 0x07
    debug_names = []
    if router_debug & 0x04:
        debug_names.append("monitor_pending")
    if router_debug & 0x02:
        debug_names.append("record_pending")
    if router_debug & 0x01:
        debug_names.append("output_pending")
    return (f"diag-audio: sample_count={(data >> 16) & 0xFFFF} "
            f"note_on_count={(data >> 8) & 0xFF} flags=0x{flags:02X} "
            f"router=0x{router_debug:X} "
            f"[{','.join(names + debug_names) if names or debug_names else 'none'}]")


def format_router_diag(data: int) -> str:
    flags = data & 0xFF
    live_level = flags & 0x0F
    record_level = (flags >> 4) & 0x0F
    return (f"diag-router: levels=0x{flags:02X} "
            f"live={live_level} record={record_level}")


def transact(port, opcode: int, arg0: int, arg1: int, sequence: int, timeout: float) -> list[Ack]:
    port.timeout = timeout
    frame = build_command(opcode, arg0, arg1, sequence)
    port.write(frame)
    port.flush()
    replies: list[Ack] = []
    deadline = time.monotonic() + timeout
    while True:
        remaining = max(0.01, deadline - time.monotonic())
        port.timeout = remaining
        ack = read_ack(port)
        if ack.sequence != sequence or ack.opcode != opcode:
            print(f"ignored unrelated response: {format_ack(ack)}", file=sys.stderr)
            continue
        replies.append(ack)
        print(format_ack(ack))
        if opcode == OPCODES["read-csr"] and arg0 == 0x40 and ack.status == 1:
            print(format_audio_diag(ack.data))
        if opcode == OPCODES["read-csr"] and arg0 == 0x44 and ack.status == 1:
            print(format_router_diag(ack.data))
        if ack.status != 0:
            return replies
        if time.monotonic() >= deadline:
            raise TimeoutError("waiting for final ACK after ACCEPTED")


def run_command(port, words: list[str], sequence: int, timeout: float) -> int:
    opcode, arg0, arg1, sequence = parse_command(words, sequence)
    replies = transact(port, opcode, arg0, arg1, sequence, timeout)
    return 0 if replies[-1].status in (0, 1) else 2


def serial_port_names() -> list[str]:
    """Return available serial ports, sorted for a predictable Windows UI."""
    from serial.tools import list_ports  # type: ignore
    return sorted(info.device for info in list_ports.comports())


class LoopControlGui:
    """Small Tkinter panel for the commands used during board bring-up."""

    def __init__(self, root, args):
        import tkinter as tk
        from tkinter import messagebox, ttk

        self.tk = tk
        self.messagebox = messagebox
        self.ttk = ttk
        self.root = root
        self.args = args
        self.port = None
        self.reader_thread = None
        self.stop_reader = threading.Event()
        self.incoming: queue.Queue[object] = queue.Queue()
        self.sequence = args.sequence & 0xFF
        self.pending: dict[int, tuple[int, float]] = {}
        self.fpga_ready_at = 0.0

        root.title("MGC3130 Loop 控制台")
        root.geometry("760x600")
        root.minsize(680, 500)
        root.protocol("WM_DELETE_WINDOW", self.close)

        self.port_var = tk.StringVar(value=args.port or "")
        self.baud_var = tk.StringVar(value=str(args.baud))
        self.connection_var = tk.StringVar(value="未连接")
        self.startup_var = tk.StringVar(value="")
        self.mode_var = tk.StringVar(value="—")
        self.bpm_var = tk.StringVar(value="120")
        self.track_var = tk.IntVar(value=0)
        self.enter_var = tk.StringVar(value="0x2000")
        self.exit_var = tk.StringVar(value="0x3000")
        self.auto_status_var = tk.BooleanVar(value=True)

        self._build_layout()
        self.refresh_ports()
        self.root.after(100, self._poll_incoming)
        self.root.after(1500, self._auto_status)

    def _build_layout(self):
        tk, ttk = self.tk, self.ttk
        root = self.root
        root.columnconfigure(0, weight=1)
        root.rowconfigure(2, weight=1)

        conn = ttk.LabelFrame(root, text="串口连接", padding=8)
        conn.grid(row=0, column=0, sticky="ew", padx=10, pady=(10, 5))
        conn.columnconfigure(1, weight=1)
        ttk.Label(conn, text="端口").grid(row=0, column=0, padx=(0, 5))
        self.port_combo = ttk.Combobox(conn, textvariable=self.port_var, width=16)
        self.port_combo.grid(row=0, column=1, sticky="w")
        ttk.Button(conn, text="刷新", command=self.refresh_ports).grid(row=0, column=2, padx=5)
        ttk.Label(conn, text="波特率").grid(row=0, column=3, padx=(12, 5))
        ttk.Combobox(conn, textvariable=self.baud_var, values=("115200",), width=9,
                     state="readonly").grid(row=0, column=4)
        self.connect_button = ttk.Button(conn, text="连接", command=self.toggle_connection)
        self.connect_button.grid(row=0, column=5, padx=(12, 5))
        ttk.Label(conn, textvariable=self.connection_var).grid(row=0, column=6, padx=5)
        ttk.Label(conn, textvariable=self.startup_var).grid(row=1, column=0, columnspan=7, sticky="w", pady=(6, 0))

        mode = ttk.LabelFrame(root, text="演奏模式", padding=8)
        mode.grid(row=1, column=0, sticky="ew", padx=10, pady=5)
        ttk.Button(mode, text="LIVE 实时", command=lambda: self.send_action("live")).grid(row=0, column=0, padx=3)
        ttk.Button(mode, text="IDLE 空闲", command=lambda: self.send_action("idle")).grid(row=0, column=1, padx=3)
        ttk.Button(mode, text="PLAY 播放", command=lambda: self.send_action("play")).grid(row=0, column=2, padx=3)
        ttk.Button(mode, text="STOP 停止", command=lambda: self.send_action("stop")).grid(row=0, column=3, padx=3)
        ttk.Button(mode, text="RESET 复位", command=lambda: self.send_action("reset")).grid(row=0, column=4, padx=3)
        ttk.Label(mode, text="当前状态:").grid(row=0, column=5, padx=(20, 4))
        ttk.Label(mode, textvariable=self.mode_var, width=18).grid(row=0, column=6, sticky="w")
        ttk.Checkbutton(mode, text="自动刷新", variable=self.auto_status_var).grid(row=0, column=7, padx=(15, 0))

        controls = ttk.Frame(root, padding=(10, 2))
        controls.grid(row=2, column=0, sticky="nsew")
        controls.columnconfigure(0, weight=1)
        controls.columnconfigure(1, weight=1)
        controls.rowconfigure(3, weight=1)

        tempo = ttk.LabelFrame(controls, text="节拍和轨道", padding=8)
        tempo.grid(row=0, column=0, sticky="ew", padx=(0, 5), pady=5)
        ttk.Label(tempo, text="BPM (60–180)").grid(row=0, column=0, sticky="w")
        ttk.Spinbox(tempo, from_=60, to=180, textvariable=self.bpm_var, width=8).grid(row=0, column=1, padx=5)
        ttk.Button(tempo, text="设置 BPM", command=self.set_bpm).grid(row=0, column=2)
        ttk.Label(tempo, text="选择轨道").grid(row=1, column=0, sticky="w", pady=(8, 0))
        for index in range(4):
            ttk.Radiobutton(tempo, text=f"轨道 {index + 1}", variable=self.track_var,
                            value=index, command=self.set_track).grid(row=1, column=index + 1, padx=2, pady=(8, 0))

        take = ttk.LabelFrame(controls, text="录音和 Loop", padding=8)
        take.grid(row=0, column=1, sticky="ew", padx=(5, 0), pady=5)
        ttk.Button(take, text="● RECORD", command=lambda: self.send_action("record")).grid(row=0, column=0, padx=3)
        ttk.Button(take, text="OVERDUB 叠录", command=lambda: self.send_action("overdub")).grid(row=0, column=1, padx=3)
        ttk.Button(take, text="提交", command=lambda: self.send_action("commit")).grid(row=0, column=2, padx=3)
        ttk.Button(take, text="清除当前轨", command=lambda: self.confirm_action("clear-track", "清除当前轨道？")).grid(row=1, column=0, padx=3, pady=8)
        ttk.Button(take, text="清除全部", command=lambda: self.confirm_action("clear-all", "清除全部 Loop？")).grid(row=1, column=1, padx=3, pady=8)
        ttk.Label(take, text="录音：按 RECORD 后，从左边界进入才开始录制").grid(row=2, column=0, columnspan=3, sticky="w")

        threshold = ttk.LabelFrame(controls, text="输入阈值", padding=8)
        threshold.grid(row=1, column=0, columnspan=2, sticky="ew", pady=5)
        ttk.Label(threshold, text="进入").grid(row=0, column=0)
        ttk.Entry(threshold, textvariable=self.enter_var, width=10).grid(row=0, column=1, padx=5)
        ttk.Label(threshold, text="退出").grid(row=0, column=2)
        ttk.Entry(threshold, textvariable=self.exit_var, width=10).grid(row=0, column=3, padx=5)
        ttk.Button(threshold, text="应用阈值", command=self.set_thresholds).grid(row=0, column=4, padx=8)

        log_frame = ttk.LabelFrame(controls, text="通信日志", padding=5)
        log_frame.grid(row=3, column=0, columnspan=2, sticky="nsew", pady=5)
        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)
        self.log = tk.Text(log_frame, height=10, state="disabled", wrap="word")
        self.log.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(log_frame, orient="vertical", command=self.log.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=scroll.set)

    def log_message(self, message: str):
        self.log.configure(state="normal")
        self.log.insert("end", time.strftime("[%H:%M:%S] ") + message + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def refresh_ports(self):
        try:
            ports = serial_port_names()
        except Exception as exc:
            self.log_message(f"无法枚举串口：{exc}")
            return
        self.port_combo["values"] = ports
        if not self.port_var.get() and ports:
            self.port_var.set(ports[0])

    def toggle_connection(self):
        if self.port is None:
            self.connect()
        else:
            self.disconnect()

    def connect(self):
        try:
            import serial  # type: ignore
            self.port = serial.Serial(self.port_var.get(), int(self.baud_var.get()), timeout=0.2,
                                      bytesize=8, parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE)
        except Exception as exc:
            self.messagebox.showerror("连接失败", str(exc))
            self.port = None
            return
        self.stop_reader.clear()
        self.reader_thread = threading.Thread(target=self._reader_loop, daemon=True)
        self.reader_thread.start()
        self.connection_var.set("已连接")
        self.connect_button.configure(text="断开")
        self.log_message(f"已连接 {self.port_var.get()} @ {self.baud_var.get()}")
        self.fpga_ready_at = time.monotonic() + 2.4
        self.startup_var.set("FPGA 上电初始化中，约 2.4 秒后可发送命令")
        self.root.after(100, self._update_startup)

    def disconnect(self):
        self.stop_reader.set()
        if self.port is not None:
            try:
                self.port.close()
            except Exception:
                pass
        self.port = None
        self.connection_var.set("未连接")
        self.startup_var.set("")
        self.connect_button.configure(text="连接")
        self.pending.clear()
        self.log_message("已断开")

    def _update_startup(self):
        if self.port is None:
            return
        remaining = self.fpga_ready_at - time.monotonic()
        if remaining > 0:
            self.startup_var.set(f"FPGA 上电初始化中，还需 {remaining:.1f} 秒")
            self.root.after(100, self._update_startup)
        else:
            self.startup_var.set("FPGA 已就绪")

    def _reader_loop(self):
        while not self.stop_reader.is_set():
            try:
                self.incoming.put(read_ack(self.port))
            except TimeoutError:
                continue
            except Exception as exc:
                if not self.stop_reader.is_set():
                    self.incoming.put(exc)
                break

    def _poll_incoming(self):
        try:
            while True:
                item = self.incoming.get_nowait()
                if isinstance(item, Ack):
                    self.log_message(format_ack(item))
                    self.pending.pop(item.sequence, None)
                    if item.opcode == OPCODES["status"]:
                        self.mode_var.set(MODE_NAMES.get(item.data & 0xF, f"0x{item.data & 0xF:X}"))
                else:
                    self.log_message(f"接收错误：{item}")
        except queue.Empty:
            pass
        now = time.monotonic()
        expired = [seq for seq, (_, sent_at) in self.pending.items() if now - sent_at >= self.args.timeout]
        for seq in expired:
            opcode, _ = self.pending.pop(seq)
            self.log_message(f"ACK 超时：opcode={opcode} seq={seq}；请检查位流、B3/C3 接线和波特率")
        self.root.after(100, self._poll_incoming)

    def _auto_status(self):
        if self.auto_status_var.get() and self.port is not None and time.monotonic() >= self.fpga_ready_at:
            self.send_action("status", quiet=True)
        self.root.after(1500, self._auto_status)

    def _send(self, opcode: int, arg0: int = 0, arg1: int = 0, quiet: bool = False):
        if self.port is None:
            self.messagebox.showwarning("未连接", "请先选择 COM 端口并点击连接")
            return
        if time.monotonic() < self.fpga_ready_at:
            remaining = self.fpga_ready_at - time.monotonic()
            self.log_message(f"FPGA 仍在启动，请 {remaining:.1f} 秒后再发送")
            return
        sequence = self.sequence
        self.sequence = (self.sequence + 1) & 0xFF
        frame = build_command(opcode, arg0, arg1, sequence)
        try:
            self.port.write(frame)
            self.port.flush()
            self.pending[sequence] = (opcode, time.monotonic())
            if not quiet:
                self.log_message(f"TX {frame.hex(' ')}")
        except Exception as exc:
            self.log_message(f"发送失败：{exc}")
            self.disconnect()

    def send_action(self, action: str, quiet: bool = False):
        try:
            opcode, arg0, arg1 = command_for_ui(action)
        except ValueError as exc:
            self.log_message(str(exc))
            return
        self._send(opcode, arg0, arg1, quiet)

    def confirm_action(self, action: str, question: str):
        if self.messagebox.askyesno("请确认", question):
            self.send_action(action)

    def set_bpm(self):
        try:
            bpm = int(self.bpm_var.get())
            if not 60 <= bpm <= 180:
                raise ValueError
            opcode, arg0, arg1 = command_for_ui("bpm", bpm=bpm)
            self._send(opcode, arg0, arg1)
        except ValueError:
            self.messagebox.showerror("参数错误", "BPM 必须是 60 到 180")

    def set_track(self):
        opcode, arg0, arg1 = command_for_ui("track", track=self.track_var.get())
        self._send(opcode, arg0, arg1)

    def set_thresholds(self):
        try:
            enter = int(self.enter_var.get(), 0)
            exit_value = int(self.exit_var.get(), 0)
            if not 0 <= enter < exit_value <= 0xFFFF:
                raise ValueError
            opcode, arg0, arg1 = command_for_ui("thresholds", enter=enter, exit=exit_value)
            self._send(opcode, arg0, arg1)
        except ValueError:
            self.messagebox.showerror("参数错误", "请输入 0 到 0xFFFF，且进入阈值小于退出阈值")

    def close(self):
        self.disconnect()
        self.root.destroy()


def run_gui(args) -> int:
    try:
        import tkinter as tk
    except ImportError:
        print("当前 Python 没有 Tkinter；请使用 Windows 官方 Python，或改用命令行模式。", file=sys.stderr)
        return 3
    root = tk.Tk()
    LoopControlGui(root, args)
    root.mainloop()
    return 0


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FPGA Loop binary UART controller")
    parser.add_argument("--gui", action="store_true", help="open the graphical control panel")
    parser.add_argument("--port", help="serial port, for example COM7 or /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=2.0, help="seconds to wait for each command")
    parser.add_argument("--sequence", type=int, default=0, help="initial sequence number (0..255)")
    parser.add_argument("command", nargs="*", help="command and arguments; omit for interactive mode")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = make_parser().parse_args(argv)
    if args.gui:
        try:
            import serial  # type: ignore  # noqa: F401
        except ImportError:
            print("pyserial is required: python -m pip install pyserial", file=sys.stderr)
            return 3
        return run_gui(args)
    if not args.port:
        print("--port is required for command-line mode; use --gui for the control panel", file=sys.stderr)
        return 2
    try:
        import serial  # type: ignore
    except ImportError:
        print("pyserial is required: python -m pip install pyserial", file=sys.stderr)
        return 3

    try:
        port = serial.Serial(args.port, args.baud, timeout=args.timeout, bytesize=8,
                             parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE)
    except serial.SerialException as exc:
        print(f"cannot open {args.port}: {exc}", file=sys.stderr)
        return 3

    sequence = args.sequence & 0xFF
    try:
        if args.command:
            return run_command(port, args.command, sequence, args.timeout)
        print("Loop UART interactive mode; type help or quit.")
        while True:
            try:
                line = input("loop> ").strip()
            except EOFError:
                break
            if not line:
                continue
            if line.lower() in ("quit", "exit"):
                break
            if line.lower() == "help":
                print("status, live, idle, bpm N, track N, play, stop, record, overdub,")
                print("clear-track, clear-all, commit, reset, thresholds ENTER EXIT, read-csr ADDR,")
                print("diag-input (CSR 0x3C), diag-audio (CSR 0x40), diag-router (CSR 0x44)")
                continue
            try:
                result = run_command(port, shlex.split(line), sequence, args.timeout)
                sequence = (sequence + 1) & 0xFF
                if result:
                    print("command failed", file=sys.stderr)
            except (ValueError, TimeoutError) as exc:
                print(f"error: {exc}", file=sys.stderr)
    finally:
        port.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
