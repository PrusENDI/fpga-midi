#!/usr/bin/env python3
"""Probe the board UART link and issue one STATUS command.

The Loop bitstream emits ``LOOP UART READY`` once after reset.  This helper
captures that marker when it is still in the UART receive window, then sends a
STATUS frame and prints the decoded ACK.  It is useful before opening the GUI.
"""

from __future__ import annotations

import argparse
import time

import serial  # type: ignore

from loop_control_uart import build_command, format_ack, read_ack


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--wait", type=float, default=3.0,
                        help="seconds to listen for the startup marker")
    parser.add_argument("--timeout", type=float, default=2.0)
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.1,
                       bytesize=8, parity=serial.PARITY_NONE,
                       stopbits=serial.STOPBITS_ONE,
                       rtscts=False, dsrdtr=False) as port:
        raw = bytearray()
        deadline = time.monotonic() + args.wait
        while time.monotonic() < deadline:
            raw.extend(port.read(256))
        marker = b"LOOP UART READY\r\n"
        print(f"{args.port}: startup_marker={'seen' if marker in raw else 'not seen'} "
              f"raw_bytes={len(raw)}")

        sequence = 0
        frame = build_command(0, sequence=sequence)
        port.write(frame)
        port.flush()
        port.timeout = args.timeout
        try:
            ack = read_ack(port)
        except TimeoutError:
            print("RX ACK: timeout; if the board was already running, the one-shot "
                  "startup marker may have been missed. Program SRAM again and "
                  "start this probe immediately.")
            return 2
        print(f"RX ACK: {format_ack(ack)}")
        return 0 if ack.opcode == 0 and ack.sequence == sequence else 2


if __name__ == "__main__":
    raise SystemExit(main())
