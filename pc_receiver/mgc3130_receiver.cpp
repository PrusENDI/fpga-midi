#include <windows.h>

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include <gestic_api.h>

namespace {

struct Options {
    double seconds = 0.0;
    std::string output;
    std::string format = "jsonl";
    bool force_calibration = false;
};

std::string narrow(const wchar_t *value) {
    if (!value) return std::string();
    int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    std::string result(size > 0 ? size - 1 : 0, '\0');
    if (size > 1) {
        WideCharToMultiByte(CP_UTF8, 0, value, -1, &result[0], size, nullptr, nullptr);
    }
    return result;
}

bool parse_options(int argc, wchar_t **argv, Options &options) {
    for (int index = 1; index < argc; ++index) {
        const std::wstring argument(argv[index]);
        if (argument == L"--seconds" && index + 1 < argc) {
            options.seconds = _wtof(argv[++index]);
        } else if (argument == L"--output" && index + 1 < argc) {
            options.output = narrow(argv[++index]);
        } else if (argument == L"--format" && index + 1 < argc) {
            options.format = narrow(argv[++index]);
        } else if (argument == L"--force-calibration") {
            options.force_calibration = true;
        } else if (argument == L"--help" || argument == L"-h") {
            std::cout << "mgc3130_receiver [--seconds N] [--output FILE] [--format jsonl|csv] [--force-calibration]\n";
            return false;
        } else {
            std::cerr << "unknown argument: " << narrow(argv[index]) << "\n";
            return false;
        }
    }
    return options.format == "jsonl" || options.format == "csv";
}

class Output {
public:
    explicit Output(const Options &options) : format_(options.format) {
        if (!options.output.empty()) {
            file_.open(options.output.c_str(), std::ios::out | std::ios::binary);
            if (!file_) throw std::runtime_error("could not open output file");
        }
        if (format_ == "csv") {
            write("timestamp_ms,logical_time_ms,timestamp_raw,sequence,sequence_gap,frame,x,y,z,gesture,gesture_flags,touch_flags,tap_flags,position_valid,xyz_valid,report_error,clipping,environmental_noise,calibration_reason,quality_known\n");
        }
    }

    void calibration(bool ok) {
        if (format_ == "jsonl") {
            write(ok ? "{\"type\":\"calibration\",\"target\":\"baseline\",\"ok\":true}\n"
                     : "{\"type\":\"calibration\",\"target\":\"baseline\",\"ok\":false}\n");
        }
    }

    void ready() {
        if (format_ == "jsonl") {
            write("{\"type\":\"ready\",\"source\":\"Microchip GestIC SDK\",\"schema\":1}\n");
        }
    }

    void position(unsigned long long timestamp, int frame, int sequence_gap, const gestic_t &gestic) {
        const gestic_position_t &position = gestic.result.pos;
        const gestic_gesture_t &gesture = gestic.result.gesture;
        const gestic_touch_t &touch = gestic.result.touch;
        std::ostringstream line;
        if (format_ == "csv") {
            line << timestamp << ',' << timestamp << ',' << gestic.result.frame_counter << ',' << frame << ',' << sequence_gap << ',' << frame << ',' << position.x << ',' << position.y << ',' << position.z
                 << ',' << static_cast<int>(gesture.gesture) << ',' << static_cast<int>(gesture.flags)
                 << ',' << static_cast<int>(touch.flags) << ',' << static_cast<int>(touch.tap_flags)
                 << ",,,," << static_cast<int>(gestic.result.calib.reason) << ",false\n";
        } else {
            line << "{\"type\":\"position\",\"timestamp_ms\":" << timestamp
                 << ",\"logical_time_ms\":" << timestamp
                 << ",\"timestamp_raw\":" << gestic.result.frame_counter
                 << ",\"sequence\":" << frame
                 << ",\"sequence_gap\":" << sequence_gap
                 << ",\"x\":" << position.x
                 << ",\"y\":" << position.y << ",\"z\":" << position.z
                 << ",\"gesture\":" << static_cast<int>(gesture.gesture)
                 << ",\"gesture_flags\":" << static_cast<int>(gesture.flags)
                 << ",\"touch_flags\":" << static_cast<int>(touch.flags)
                 << ",\"tap_flags\":" << static_cast<int>(touch.tap_flags)
                 << ",\"position_valid\":null,\"xyz_valid\":null,\"report_error\":null"
                 << ",\"clipping\":null,\"environmental_noise\":null"
                 << ",\"calibration_reason\":" << static_cast<int>(gestic.result.calib.reason)
                 << ",\"quality_known\":false}\n";
        }
        write(line.str());
    }

private:
    void write(const std::string &line) {
        std::cout << line;
        std::cout.flush();
        if (file_) {
            file_ << line;
            file_.flush();
        }
    }

    std::string format_;
    std::ofstream file_;
};

}  // namespace

int wmain(int argc, wchar_t **argv) {
    Options options;
    if (!parse_options(argc, argv, options)) return argc > 1 ? 2 : 0;

    try {
        Output output(options);
        gestic_t gestic;
        gestic_initialize(&gestic);
        if (gestic_open(&gestic) < 0) {
            std::cerr << "Could not open a Microchip MGC3130 GestIC USB-I2C device.\n";
            gestic_cleanup(&gestic);
            return 3;
        }

        const gestic_data_mask_t stream_flags = static_cast<gestic_data_mask_t>(
            gestic_data_mask_position | gestic_data_mask_gesture | gestic_data_mask_touch);
        if (gestic_set_auto_calibration(&gestic, 1, 100) < 0 ||
            gestic_select_frequencies(&gestic, gestic_all_freq, 100) < 0 ||
            gestic_set_approach_detection(&gestic, 0, 100) < 0 ||
            gestic_set_output_enable_mask(&gestic, stream_flags, stream_flags,
                                          gestic_data_mask_all, 100) < 0) {
            std::cerr << "Could not configure the MGC3130 stream.\n";
            gestic_close(&gestic);
            gestic_cleanup(&gestic);
            return 4;
        }

        if (options.force_calibration) {
            // Force baseline: the SDK re-measures the untouched sensor. Ask for
            // it before the first frame so the take starts from a known state.
            int calibration = gestic_force_calibration(&gestic, 100);
            output.calibration(calibration == 0);
        }

        output.ready();
        const ULONGLONG start = GetTickCount64();
        int frame = 0;
        while (options.seconds <= 0.0 ||
               (GetTickCount64() - start) < static_cast<ULONGLONG>(options.seconds * 1000.0)) {
            int skipped = 0;
            int result;
            do {
                result = gestic_data_stream_update(&gestic, &skipped);
                if (result == GESTIC_NO_ERROR) {
                    output.position(GetTickCount64() - start, frame++, skipped, gestic);
                }
            } while (result == GESTIC_NO_ERROR);
            Sleep(5);
        }

        gestic_close(&gestic);
        gestic_cleanup(&gestic);
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\n";
        return 5;
    }
}
