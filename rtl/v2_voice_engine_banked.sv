// V2 32-voice engine with a deterministic GW5A state bank.
//
// The hot oscillator state is held in one simple-dual-port bank. The scan
// issues one read per cycle and the registered bank output feeds the existing
// read/compute/writeback pipeline. Events are accepted only while the scan
// pipeline is quiescent, so the bank has exactly one write owner per cycle.
module v2_voice_engine_banked #(
    parameter integer VOICES = 32,
    parameter integer USE_GOWIN_RAM = 0
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   sample_ce,
    input  logic                   event_valid,
    output logic                   event_ready,
    input  logic [95:0]            event_data,
    output logic signed [15:0]     mixed_sample,
    output logic                   sample_valid,
    output logic [VOICES-1:0]      active_bitmap,
    output logic                   voice_overflow,
    output logic [7:0]             revoice_count,
    output logic [5:0]             active_voice_count
);
    import v2_contract_pkg::*;

    localparam logic [1:0] ENV_ATTACK  = 2'd0;
    localparam logic [1:0] ENV_DECAY   = 2'd1;
    localparam logic [1:0] ENV_SUSTAIN = 2'd2;
    localparam logic [1:0] ENV_RELEASE = 2'd3;
    localparam logic [15:0] SUSTAIN_LEVEL = 16'd49152;
    localparam logic [15:0] ATTACK_STEP   = 16'd4096;
    localparam logic [15:0] DECAY_STEP    = 16'd256;
    localparam logic [15:0] RELEASE_STEP  = 16'd1024;
    localparam logic [7:0] DEFAULT_MIX_A = 8'd128;
    localparam logic [7:0] DEFAULT_MIX_B = 8'd128;

    // Metadata is small and is only touched by the event path. All oscillator
    // state, including both glide targets, is packed in the BSRAM bank. This
    // is intentional: leaving target_a/target_b as variable-indexed arrays
    // makes Gowin infer RAMREG writeback logic and recreates the 100 MHz
    // critical path that this bank is meant to remove.
    logic [VOICES-1:0] active;
    logic [VOICES-1:0] releasing;
    logic [7:0]  note [0:VOICES-1];

    // Bank word layout: phase_a, phase_b, step_a, step_b, target_a,
    // target_b, envelope, gain, mix_a, mix_b, env_stage, and reserved bits
    // (240 total = fifteen independent 16-bit DPB lanes).
    logic [239:0] bank_rd_data;
    logic         bank_rd_en;
    logic [4:0]   bank_rd_addr;
    logic         bank_wr_en;
    logic [4:0]   bank_wr_addr;
    logic [239:0] bank_wr_data;
    v2_voice_state_bank #(.WIDTH(240), .USE_GOWIN_RAM(USE_GOWIN_RAM)) state_bank (
        .clk, .rd_en(bank_rd_en), .rd_addr(bank_rd_addr), .rd_data(bank_rd_data),
        .wr_en(bank_wr_en), .wr_addr(bank_wr_addr), .wr_data(bank_wr_data)
    );



    logic [31:0] rom_step;
    v2_note_increment_rom note_rom (.note(event_data[71:64]), .increment(rom_step));

    logic        scan_active;
    logic        scan_busy;
    logic [5:0]  scan_index;
    logic [5:0]  scan_base;
    logic [5:0]  scan_slot;
    logic signed [47:0] mix_acc;

    logic        bank_rd_pending;
    logic        bank_rd_last_pending;
    logic [4:0]  bank_rd_slot_pending;
    logic        rd_valid;
    logic        rd_last;
    logic        rd_active;
    logic        rd_releasing;
    logic [4:0]  rd_slot;
    logic [31:0] rd_phase_a, rd_phase_b, rd_step_a, rd_step_b;
    logic [31:0] rd_target_a, rd_target_b;
    logic [15:0] rd_envelope;
    logic [7:0]  rd_gain, rd_mix_a, rd_mix_b;
    logic [1:0]  rd_env_stage;

    logic        calc_valid;
    logic        calc_last;
    logic        calc_active;
    logic [4:0]  calc_slot;
    logic signed [47:0] calc_osc_sum;
    logic [31:0] calc_phase_a, calc_phase_b, calc_step_a, calc_step_b;
    logic [31:0] calc_target_a, calc_target_b;
    logic [15:0] calc_envelope;
    logic [7:0]  calc_gain, calc_mix_a, calc_mix_b;
    logic [1:0]  calc_env_stage;
    logic        calc_active_next;

    integer i;
    integer count_idx;
    integer free_slot;
    integer revoice_hits;
    integer count_i;
    logic event_accept;
    logic event_note_on;
    logic revoice_pending;
    logic [7:0] revoice_note_pending;
    logic [31:0] revoice_target_a_pending, revoice_target_b_pending;

    always_comb begin
        count_i = 0;
        for (count_idx = 0; count_idx < VOICES; count_idx = count_idx + 1)
            count_i = count_i + (active[count_idx] ? 1 : 0);
        active_voice_count = count_i[5:0];
        active_bitmap = active;

        free_slot = -1;
        if (event_data[94:91] == V2_EV_NOTE_ON)
            for (count_idx = 0; count_idx < VOICES; count_idx = count_idx + 1)
                if (!active[count_idx] && free_slot < 0)
                    free_slot = count_idx;

        // A command is held by its producer during the complete scan. This
        // gives the bank a single deterministic write port.
        event_ready = rst_n && !scan_busy && !revoice_pending;
        event_accept = event_valid && event_ready;
        event_note_on = event_accept && !event_data[95] &&
                        (event_data[94:91] == V2_EV_NOTE_ON) && (free_slot >= 0);

        bank_rd_en = scan_active;
        bank_rd_addr = scan_slot[4:0];
        bank_wr_en = 1'b0;
        bank_wr_addr = 5'd0;
        bank_wr_data = 240'd0;
        if (calc_valid && calc_active) begin
            bank_wr_en = 1'b1;
            bank_wr_addr = calc_slot;
            bank_wr_data[31:0]   = calc_phase_a;
            bank_wr_data[63:32]  = calc_phase_b;
            bank_wr_data[95:64]  = calc_step_a;
            bank_wr_data[127:96] = calc_step_b;
            bank_wr_data[159:128] = calc_target_a;
            bank_wr_data[191:160] = calc_target_b;
            bank_wr_data[207:192] = calc_envelope;
            bank_wr_data[215:208] = calc_gain;
            bank_wr_data[223:216] = calc_mix_a;
            bank_wr_data[231:224] = calc_mix_b;
            bank_wr_data[233:232] = calc_env_stage;
        end else if (event_note_on) begin
            bank_wr_en = 1'b1;
            bank_wr_addr = free_slot[4:0];
            bank_wr_data[31:0]   = 32'd0;
            bank_wr_data[63:32]  = 32'd0;
            bank_wr_data[95:64]  = rom_step;
            bank_wr_data[127:96] = rom_step;
            bank_wr_data[159:128] = apply_delta(rom_step, $signed({event_data[55], event_data[55:40]}));
            bank_wr_data[191:160] = apply_delta(rom_step, -$signed({event_data[55], event_data[55:40]}));
            bank_wr_data[207:192] = 16'd0;
            bank_wr_data[215:208] = event_data[63:56];
            bank_wr_data[223:216] = (event_data[39:24] == 16'd0) ? DEFAULT_MIX_A : event_data[39:32];
            bank_wr_data[231:224] = (event_data[39:24] == 16'd0) ? DEFAULT_MIX_B : event_data[31:24];
            bank_wr_data[233:232] = ENV_ATTACK;
        end
    end

    function automatic logic [31:0] apply_delta(
        input logic [31:0] base, input logic signed [16:0] delta
    );
        logic signed [32:0] sum;
        begin
            sum = $signed({1'b0, base}) + $signed({{16{delta[16]}}, delta});
            if (sum < 33'sd0) apply_delta = 32'd0;
            else if (sum > 33'sh0FFFFFFFF) apply_delta = 32'hFFFFFFFF;
            else apply_delta = sum[31:0];
        end
    endfunction

    function automatic logic [31:0] bounded_step(input logic [31:0] current, target);
        logic [31:0] distance;
        begin
            if (current < target) begin
                distance = target - current;
                bounded_step = current + ((distance > 32'd512) ? 32'd512 : distance);
            end else if (current > target) begin
                distance = current - target;
                bounded_step = current - ((distance > 32'd512) ? 32'd512 : distance);
            end else bounded_step = current;
        end
    endfunction

    function automatic logic signed [47:0] oscillator_value(
        input logic [31:0] phase, input logic [1:0] stage,
        input logic [7:0] velocity, input logic [7:0] mix
    );
        logic signed [16:0] raw;
        integer attenuation;
        begin
            raw = $signed({1'b0, phase[31:16]}) - 17'sd32768;
            attenuation = 0;
            if (stage == ENV_ATTACK) attenuation = attenuation + 2;
            if (stage == ENV_DECAY) attenuation = attenuation + 1;
            if (stage == ENV_RELEASE) attenuation = attenuation + 3;
            if (velocity < 8'd64) attenuation = attenuation + 3;
            else if (velocity < 8'd128) attenuation = attenuation + 2;
            else if (velocity < 8'd192) attenuation = attenuation + 1;
            if (mix < 8'd64) attenuation = attenuation + 3;
            else if (mix < 8'd128) attenuation = attenuation + 2;
            else if (mix < 8'd192) attenuation = attenuation + 1;
            oscillator_value = raw >>> attenuation;
        end
    endfunction

    function automatic logic signed [15:0] saturate_sample(input logic signed [47:0] value);
        begin
            if (value > 48'sd32767) saturate_sample = 16'sh7FFF;
            else if (value < -48'sd32768) saturate_sample = -16'sd32768;
            else saturate_sample = value[15:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active <= '0;
            releasing <= '0;
            voice_overflow <= 1'b0;
            revoice_count <= 8'd0;
            scan_active <= 1'b0;
            scan_busy <= 1'b0;
            scan_index <= 6'd0;
            scan_base <= 6'd0;
            scan_slot <= 6'd0;
            mix_acc <= '0;
            bank_rd_pending <= 1'b0;
            bank_rd_last_pending <= 1'b0;
            bank_rd_slot_pending <= 5'd0;
            rd_valid <= 1'b0;
            rd_last <= 1'b0;
            rd_active <= 1'b0;
            rd_releasing <= 1'b0;
            rd_slot <= 5'd0;
            rd_phase_a <= 0; rd_phase_b <= 0; rd_step_a <= 0; rd_step_b <= 0;
            rd_target_a <= 0; rd_target_b <= 0; rd_envelope <= 0;
            rd_gain <= 0; rd_mix_a <= DEFAULT_MIX_A; rd_mix_b <= DEFAULT_MIX_B;
            rd_env_stage <= ENV_ATTACK;
            calc_valid <= 1'b0; calc_last <= 1'b0; calc_active <= 1'b0;
            calc_slot <= 5'd0; calc_osc_sum <= 0;
            calc_phase_a <= 0; calc_phase_b <= 0; calc_step_a <= 0; calc_step_b <= 0;
            calc_target_a <= 0; calc_target_b <= 0; calc_envelope <= 0;
            calc_gain <= 0; calc_mix_a <= DEFAULT_MIX_A; calc_mix_b <= DEFAULT_MIX_B;
            calc_env_stage <= ENV_ATTACK; calc_active_next <= 1'b0;
            mixed_sample <= 16'sd0;
            sample_valid <= 1'b0;
            revoice_pending <= 1'b0;
            revoice_note_pending <= 8'd0;
            revoice_target_a_pending <= 32'd0;
            revoice_target_b_pending <= 32'd0;
        end else begin
            sample_valid <= 1'b0;

            if (event_accept && !event_data[95]) begin
                if (event_data[94:91] == V2_EV_NOTE_ON) begin
                    if (free_slot >= 0) begin
                        active[free_slot] <= 1'b1;
                        releasing[free_slot] <= 1'b0;
                        note[free_slot] <= event_data[71:64];
                    end else voice_overflow <= 1'b1;
                end else if (event_data[94:91] == V2_EV_NOTE_OFF) begin
                    for (i = 0; i < VOICES; i = i + 1)
                        if (active[i] && note[i] == event_data[71:64]) releasing[i] <= 1'b1;
                end else if (event_data[94:91] == V2_EV_REVOICE) begin
                    revoice_hits = 0;
                    for (i = 0; i < VOICES; i = i + 1)
                        if (active[i] && note[i] == event_data[71:64])
                            revoice_hits = revoice_hits + 1;
                    if (revoice_hits != 0) begin
                        // REVOICE is a mailbox command. It is applied by the
                        // next complete scan so the DPB has one serialized
                        // write owner and no event-side target array writes.
                        revoice_pending <= 1'b1;
                        revoice_note_pending <= event_data[71:64];
                        revoice_target_a_pending <= apply_delta(rom_step, $signed({event_data[55], event_data[55:40]}));
                        revoice_target_b_pending <= apply_delta(rom_step, -$signed({event_data[55], event_data[55:40]}));
                        revoice_count <= revoice_count + revoice_hits[7:0];
                    end
                end else if (event_data[94:91] == V2_EV_ALL_NOTES_OFF) begin
                    for (i = 0; i < VOICES; i = i + 1)
                        if (active[i]) releasing[i] <= 1'b1;
                end
            end

            if (calc_valid && calc_active) begin
                mix_acc <= mix_acc + calc_osc_sum;
                if (!calc_active_next) begin
                    active[calc_slot] <= 1'b0;
                    releasing[calc_slot] <= 1'b0;
                end
            end
            if (calc_valid && calc_last) begin
                mixed_sample <= calc_active ? saturate_sample(mix_acc + calc_osc_sum) : saturate_sample(mix_acc);
                sample_valid <= 1'b1;
                scan_index <= 6'd0;
                scan_base <= (scan_base == VOICES - 1) ? 6'd0 : scan_base + 6'd1;
                mix_acc <= 48'sd0;
                scan_busy <= 1'b0;
                revoice_pending <= 1'b0;
            end

            // Compute stage.
            calc_valid <= rd_valid;
            calc_last <= rd_last;
            calc_active <= rd_active;
            calc_slot <= rd_slot;
            calc_gain <= rd_gain;
            calc_mix_a <= rd_mix_a;
            calc_mix_b <= rd_mix_b;
            calc_target_a <= rd_target_a;
            calc_target_b <= rd_target_b;
            calc_phase_a <= rd_phase_a + rd_step_a;
            calc_phase_b <= rd_phase_b + rd_step_b;
            calc_step_a <= rd_step_a;
            calc_step_b <= rd_step_b;
            calc_target_a <= rd_target_a;
            calc_target_b <= rd_target_b;
            calc_envelope <= rd_envelope;
            calc_env_stage <= rd_env_stage;
            calc_active_next <= rd_active;
            calc_osc_sum <= 48'sd0;
            if (rd_valid && rd_active) begin
                calc_osc_sum <= oscillator_value(rd_phase_a, rd_releasing ? ENV_RELEASE : rd_env_stage, rd_gain, rd_mix_a)
                              + oscillator_value(rd_phase_b, rd_releasing ? ENV_RELEASE : rd_env_stage, rd_gain, rd_mix_b);
                calc_step_a <= bounded_step(rd_step_a, rd_target_a);
                calc_step_b <= bounded_step(rd_step_b, rd_target_b);
                if (rd_releasing) begin
                    calc_env_stage <= ENV_RELEASE;
                    if (rd_envelope <= RELEASE_STEP) begin
                        calc_envelope <= 16'd0;
                        calc_active_next <= 1'b0;
                    end else calc_envelope <= rd_envelope - RELEASE_STEP;
                end else if (rd_env_stage == ENV_ATTACK) begin
                    if ({1'b0, rd_envelope} + {1'b0, ATTACK_STEP} >= 17'h0FFFF) begin
                        calc_envelope <= 16'hFFFF; calc_env_stage <= ENV_DECAY;
                    end else calc_envelope <= rd_envelope + ATTACK_STEP;
                end else if (rd_env_stage == ENV_DECAY) begin
                    if (rd_envelope <= SUSTAIN_LEVEL + DECAY_STEP) begin
                        calc_envelope <= SUSTAIN_LEVEL; calc_env_stage <= ENV_SUSTAIN;
                    end else calc_envelope <= rd_envelope - DECAY_STEP;
                end
            end

            // Capture the registered bank output and issue the next address.
            rd_valid <= bank_rd_pending;
            rd_last <= bank_rd_last_pending;
            rd_slot <= bank_rd_slot_pending;
            rd_active <= active[bank_rd_slot_pending];
            rd_releasing <= releasing[bank_rd_slot_pending];
            if (bank_rd_pending) begin
                rd_phase_a <= bank_rd_data[31:0];
                rd_phase_b <= bank_rd_data[63:32];
                rd_step_a <= bank_rd_data[95:64];
                rd_step_b <= bank_rd_data[127:96];
                if (revoice_pending && (note[bank_rd_slot_pending] == revoice_note_pending)) begin
                    rd_target_a <= revoice_target_a_pending;
                    rd_target_b <= revoice_target_b_pending;
                end else begin
                    rd_target_a <= bank_rd_data[159:128];
                    rd_target_b <= bank_rd_data[191:160];
                end
                rd_envelope <= bank_rd_data[207:192];
                rd_gain <= bank_rd_data[215:208];
                rd_mix_a <= bank_rd_data[223:216];
                rd_mix_b <= bank_rd_data[231:224];
                rd_env_stage <= bank_rd_data[233:232];
            end
            bank_rd_pending <= bank_rd_en;
            bank_rd_last_pending <= scan_active && (scan_index == VOICES - 1);
            bank_rd_slot_pending <= scan_slot[4:0];

            if (scan_active) begin
                if (scan_index == VOICES - 1) scan_active <= 1'b0;
                else begin
                    scan_index <= scan_index + 6'd1;
                    scan_slot <= (scan_slot == VOICES - 1) ? 6'd0 : scan_slot + 6'd1;
                end
            end else if (sample_ce && !scan_busy) begin
                scan_busy <= 1'b1;
                scan_active <= 1'b1;
                scan_index <= 6'd0;
                scan_slot <= scan_base;
                mix_acc <= 48'sd0;
            end
        end
    end
endmodule
