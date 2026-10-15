"""Receive the FPGA 48 kHz PCM stream and save/play it on the PC."""
import argparse
import time
import wave
import serial


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--sample-rate", type=int, default=48000,
                        help="WAV/电脑播放采样率 (default: 48000)")
    parser.add_argument("--output", default="capture.wav",
                        help="输出 WAV 文件路径 (default: capture.wav)")
    parser.add_argument("--no-audio", action="store_true",
                        help="只接收和诊断，不打开电脑音频设备")
    args = parser.parse_args()
    ser = serial.Serial(args.port, args.baud, timeout=1)
    print(f"opened {args.port} at {args.baud} baud; waiting for A5 5A frames",
          flush=True)
    out_context = None
    if not args.no_audio:
        import sounddevice as sd
        out_context = sd.RawOutputStream(samplerate=args.sample_rate, channels=1,
                                         dtype="uint8")
    wav_file = wave.open(args.output, "wb")
    wav_file.setnchannels(1)
    wav_file.setsampwidth(1)
    wav_file.setframerate(args.sample_rate)
    print(f"saving PCM to {args.output}", flush=True)
    total_bytes = 0
    frames = 0
    bad_frames = 0
    missing_frames = 0
    previous_seq = None
    non_silent_samples = 0
    sample_min, sample_max = 255, 0
    started = time.monotonic()
    last_report = time.monotonic()
    try:
        if out_context is not None:
            out_context.__enter__()
        buf = bytearray()
        while True:
            chunk = ser.read(256)
            if chunk:
                total_bytes += len(chunk)
                buf.extend(chunk)
            while True:
                start = buf.find(b"\xA5\x5A")
                if start < 0:
                    if len(buf) > 1:
                        del buf[:-1]
                    break
                if start:
                    del buf[:start]
                if len(buf) < 4 + 32 + 1:
                    break
                if buf[3] != 32:
                    del buf[0]
                    continue
                frame = bytes(buf[:37])
                checksum = 0x20 ^ frame[2]
                for sample in frame[4:-1]:
                    checksum ^= sample
                if checksum != frame[-1]:
                    bad_frames += 1
                    # Rescan one byte later: corrupted frames can contain the
                    # beginning of a subsequent valid frame.
                    del buf[0]
                    continue
                del buf[:37]
                if previous_seq is not None:
                    missing_frames += (frame[2] - previous_seq - 1) & 255
                previous_seq = frame[2]
                frames += 1
                samples = frame[4:-1]
                non_silent_samples += sum(value != 128 for value in samples)
                sample_min = min(sample_min, min(samples))
                sample_max = max(sample_max, max(samples))
                wav_file.writeframesraw(samples)
                if out_context is not None:
                    out_context.write(frame[4:-1])
            now = time.monotonic()
            if now - last_report >= 5:
                print(f"status: bytes={total_bytes} frames={frames} "
                      f"bad_frames={bad_frames} missing_frames={missing_frames} "
                      f"non_silent_samples={non_silent_samples} "
                      f"range={sample_min}..{sample_max} "
                      f"samples_per_second={frames * 32 / (now - started):.0f} "
                      f"buffered={len(buf)}",
                      flush=True)
                last_report = now
    except KeyboardInterrupt:
        print("Stopped; closing WAV file.", flush=True)
    finally:
        if out_context is not None:
            out_context.__exit__(None, None, None)
        wav_file.close()
        ser.close()


if __name__ == "__main__":
    main()
