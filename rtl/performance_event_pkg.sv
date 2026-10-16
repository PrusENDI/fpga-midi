package performance_event_pkg;
    localparam logic [2:0] EVENT_NOTE_ON       = 3'd0;
    localparam logic [2:0] EVENT_NOTE_OFF      = 3'd1;
    localparam logic [2:0] EVENT_CONTROL_POINT = 3'd2;
    localparam logic [2:0] EVENT_LOOP_BOUNDARY = 3'd3;
    localparam logic [2:0] EVENT_ALL_NOTES_OFF = 3'd4;
    localparam logic [2:0] EVENT_ERROR         = 3'd5;

    // [63:62] reserved, [61:58] flags, [57:50] timbre,
    // [49:42] amplitude, [41:34] signed pitch, [33:26] velocity,
    // [25:19] note, [18:12] duration, [11:5] tick,
    // [4:3] track, [2:0] event type.
    localparam integer EVENT_WIDTH = 64;
    localparam integer EVENT_TYPE_LSB = 0;
    localparam integer EVENT_TRACK_LSB = 3;
    localparam integer EVENT_TICK_LSB = 5;
    localparam integer EVENT_DURATION_LSB = 12;
    localparam integer EVENT_NOTE_LSB = 19;
    localparam integer EVENT_VELOCITY_LSB = 26;
    localparam integer EVENT_PITCH_LSB = 34;
    localparam integer EVENT_AMP_LSB = 42;
    localparam integer EVENT_TIMBRE_LSB = 50;
    localparam integer EVENT_FLAGS_LSB = 58;

    function automatic [2:0] event_type;
        input [63:0] value;
        event_type = value[2:0];
    endfunction

    function automatic [1:0] event_track;
        input [63:0] value;
        event_track = value[4:3];
    endfunction

    function automatic [6:0] event_tick;
        input [63:0] value;
        event_tick = value[11:5];
    endfunction

    function automatic [6:0] event_duration;
        input [63:0] value;
        event_duration = value[18:12];
    endfunction
endpackage
