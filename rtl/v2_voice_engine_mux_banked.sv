module v2_voice_engine_mux_banked #(
    parameter integer VOICES = 32
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
    localparam logic [7:0] DEFAULT_MIX_A  = 8'd128;
    localparam logic [7:0] DEFAULT_MIX_B  = 8'd128;

    logic [31:0] phase_a [0:VOICES-1];
    logic [31:0] phase_b [0:VOICES-1];
    logic [31:0] step_a  [0:VOICES-1];
    logic [31:0] step_b  [0:VOICES-1];
    logic [31:0] target_a[0:VOICES-1];
    logic [31:0] target_b[0:VOICES-1];
    logic [15:0] envelope[0:VOICES-1];
    logic [7:0]  gain[0:VOICES-1];
    logic [7:0]  mix_a[0:VOICES-1];
    logic [7:0]  mix_b[0:VOICES-1];
    logic [7:0]  note[0:VOICES-1];
    logic [2:0]  track[0:VOICES-1];
    logic [7:0]  start_tick[0:VOICES-1];
    logic [7:0]  duration[0:VOICES-1];
    logic [7:0]  event_flags[0:VOICES-1];
    logic [1:0]  env_stage[0:VOICES-1];
    logic [VOICES-1:0] active;
    logic [VOICES-1:0] releasing;

    logic [31:0] rom_step;
    logic        scan_active;
    logic [5:0]  scan_index;
    logic [5:0]  scan_base;
    logic [5:0]  scan_slot;
    logic signed [47:0] mix_acc;
    // The scan is split into a state-read stage and a compute/writeback
    // stage.  Keeping the variable-indexed RAM output on the read side of a
    // register prevents the address decode, oscillator arithmetic and state
    // writeback from sharing one 100 MHz timing path.
    logic        rd_valid;
    logic        rd_last;
    logic        rd_active;
    logic [5:0]  rd_slot;
    logic [31:0] rd_phase_a;
    logic [31:0] rd_phase_b;
    logic [31:0] rd_step_a;
    logic [31:0] rd_step_b;
    logic [31:0] rd_target_a;
    logic [31:0] rd_target_b;
    logic [15:0] rd_envelope;
    logic [7:0]  rd_gain;
    logic [7:0]  rd_mix_a;
    logic [7:0]  rd_mix_b;
    logic [1:0]  rd_env_stage;
    logic        calc_valid;
    logic        calc_last;
    logic        calc_active;
    logic [5:0]  calc_slot;
    logic signed [47:0] calc_osc_sum;
    logic [31:0] calc_phase_a;
    logic [31:0] calc_phase_b;
    logic [31:0] calc_step_a;
    logic [31:0] calc_step_b;
    logic [15:0] calc_envelope;
    logic [1:0]  calc_env_stage;
    logic        calc_active_next;
    logic [15:0] last_event_sequence;
    logic        reserved_event_seen;

    integer i;
    integer count_idx;
    integer slot;
    integer free_slot;
    integer revoice_hits;
    integer count_i;

    v2_note_increment_rom note_rom (
        .note      (event_data[71:64]),
        .increment (rom_step)
    );

    assign active_bitmap = active;
    // Events remain independently handshakeable while the pipelined scan is
    // active; their writes are separated from the oscillator scan by the
    // registered state-read stage.
    assign event_ready = rst_n;

    always_comb begin
        count_i = 0;
        for (count_idx = 0; count_idx < VOICES; count_idx = count_idx + 1)
            count_i = count_i + (active[count_idx] ? 1 : 0);
        active_voice_count = count_i[5:0];
    end

    // Add a signed Q0.16 event offset to an unsigned Q0.32 phase increment.
    // The explicit 33-bit sum prevents tool-dependent expression truncation.
    function automatic logic [31:0] apply_delta(
        input logic [31:0] base,
        input logic signed [16:0] delta
    );
        logic signed [32:0] sum;
        begin
            sum = $signed({1'b0, base}) + $signed({{16{delta[16]}}, delta});
            if (sum < 33'sd0)
                apply_delta = 32'd0;
            else if (sum > 33'sh0FFFFFFFF)
                apply_delta = 32'hFFFFFFFF;
            else
                apply_delta = sum[31:0];
        end
    endfunction

    function automatic logic [31:0] bounded_step(
        input logic [31:0] current,
        input logic [31:0] target
    );
        logic [31:0] distance;
        begin
            if (current < target) begin
                distance = target - current;
                bounded_step = current + ((distance > 32'd512) ? 32'd512 : distance);
            end else if (current > target) begin
                distance = current - target;
                bounded_step = current - ((distance > 32'd512) ? 32'd512 : distance);
            end else begin
                bounded_step = current;
            end
        end
    endfunction

    // Saw phase is deliberately used until Task 9 installs the shared A/B/C
    // wavetable. The arithmetic path and saturation are the same as the final
    // table-backed path, so the voice lifecycle can be verified independently.
    function automatic logic signed [47:0] oscillator_value(
        input logic [31:0] phase,
        input logic [1:0]  stage,
        input logic [7:0]  velocity,
        input logic [7:0]  mix
    );
        logic signed [16:0] raw;
        logic signed [47:0] scaled;
        integer attenuation;
        begin
            raw = $signed({1'b0, phase[31:16]}) - 17'sd32768;
            // The sample path is deliberately multiplier-free. The envelope,
            // velocity and oscillator mix are represented by bounded power-of-
            // two attenuations; the full Q1.15 envelope is still retained in
            // state for telemetry and release timing. This keeps the 32-slot
            // scan on the 100 MHz path without a long DSP cascade.
            attenuation = 0;
            if (stage == ENV_ATTACK)  attenuation = attenuation + 2;
            if (stage == ENV_DECAY)   attenuation = attenuation + 1;
            if (stage == ENV_RELEASE) attenuation = attenuation + 3;
            if (velocity < 8'd64)      attenuation = attenuation + 3;
            else if (velocity < 8'd128) attenuation = attenuation + 2;
            else if (velocity < 8'd192) attenuation = attenuation + 1;
            if (mix < 8'd64)           attenuation = attenuation + 3;
            else if (mix < 8'd128)      attenuation = attenuation + 2;
            else if (mix < 8'd192)      attenuation = attenuation + 1;
            scaled = raw;
            oscillator_value = scaled >>> attenuation;
        end
    endfunction

    function automatic logic signed [15:0] saturate_sample(
        input logic signed [47:0] value
    );
        begin
            if (value > 48'sd32767)
                saturate_sample = 16'sh7FFF;
            else if (value < -48'sd32768)
                saturate_sample = -16'sd32768;
            else
                saturate_sample = value[15:0];
        end
    endfunction

    // Voice state reset is synchronous to the 100 MHz engine clock. The V2
    // clock/reset block still provides asynchronous assertion globally; using
    // a local synchronous reset avoids routing an async reset to every RAM bit.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active              <= '0;
            releasing           <= '0;
            voice_overflow      <= 1'b0;
            revoice_count       <= 8'd0;
            scan_active         <= 1'b0;
            scan_index          <= 6'd0;
            scan_base           <= 6'd0;
            scan_slot           <= 6'd0;
            mix_acc             <= '0;
            rd_valid            <= 1'b0;
            rd_last             <= 1'b0;
            rd_active           <= 1'b0;
            rd_slot             <= 6'd0;
            rd_phase_a          <= 32'd0;
            rd_phase_b          <= 32'd0;
            rd_step_a           <= 32'd0;
            rd_step_b           <= 32'd0;
            rd_target_a         <= 32'd0;
            rd_target_b         <= 32'd0;
            rd_envelope         <= 16'd0;
            rd_gain             <= 8'd0;
            rd_mix_a            <= DEFAULT_MIX_A;
            rd_mix_b            <= DEFAULT_MIX_B;
            rd_env_stage        <= ENV_ATTACK;
            calc_valid          <= 1'b0;
            calc_last           <= 1'b0;
            calc_active         <= 1'b0;
            calc_slot           <= 6'd0;
            calc_osc_sum        <= 48'sd0;
            calc_phase_a        <= 32'd0;
            calc_phase_b        <= 32'd0;
            calc_step_a         <= 32'd0;
            calc_step_b         <= 32'd0;
            calc_envelope       <= 16'd0;
            calc_env_stage      <= ENV_ATTACK;
            calc_active_next    <= 1'b0;
            mixed_sample        <= 16'sd0;
            sample_valid        <= 1'b0;
            last_event_sequence <= 16'd0;
            reserved_event_seen <= 1'b0;
            // Per-slot state is written on NOTE_ON before active is asserted.
            // Leaving inactive RAM words without an async reset permits the
            // implementation to use compact memory/register banks instead of
            // routing a reset tree through all 32 slots.
        end else begin
            sample_valid <= 1'b0;

            if (event_valid && event_ready) begin
                last_event_sequence <= event_data[15:0];
                reserved_event_seen <= event_data[95];
                if (!event_data[95]) begin
                    free_slot = -1;
                    revoice_hits = 0;
                    if (event_data[94:91] == V2_EV_NOTE_ON) begin
                        for (i = 0; i < VOICES; i = i + 1)
                            if (!active[i] && free_slot < 0)
                                free_slot = i;
                        if (free_slot >= 0) begin
                            active[free_slot]       <= 1'b1;
                            releasing[free_slot]    <= 1'b0;
                            env_stage[free_slot]    <= ENV_ATTACK;
                            envelope[free_slot]     <= 16'd0;
                            phase_a[free_slot]      <= 32'd0;
                            phase_b[free_slot]      <= 32'd0;
                            step_a[free_slot]       <= rom_step;
                            step_b[free_slot]       <= rom_step;
                            target_a[free_slot]     <= apply_delta(rom_step, $signed({event_data[55], event_data[55:40]}));
                            target_b[free_slot]     <= apply_delta(rom_step, -$signed({event_data[55], event_data[55:40]}));
                            gain[free_slot]         <= event_data[63:56];
                            note[free_slot]         <= event_data[71:64];
                            track[free_slot]        <= event_data[90:88];
                            start_tick[free_slot]   <= event_data[87:80];
                            duration[free_slot]     <= event_data[79:72];
                            event_flags[free_slot]  <= event_data[23:16];
                            mix_a[free_slot]        <= (event_data[39:24] == 16'd0) ? DEFAULT_MIX_A : event_data[39:32];
                            mix_b[free_slot]        <= (event_data[39:24] == 16'd0) ? DEFAULT_MIX_B : event_data[31:24];
                        end else begin
                            voice_overflow <= 1'b1;
                        end
                    end else if (event_data[94:91] == V2_EV_NOTE_OFF) begin
                        for (i = 0; i < VOICES; i = i + 1)
                            if (active[i] && note[i] == event_data[71:64]) begin
                                releasing[i] <= 1'b1;
                                env_stage[i] <= ENV_RELEASE;
                            end
                    end else if (event_data[94:91] == V2_EV_REVOICE) begin
                        for (i = 0; i < VOICES; i = i + 1)
                            if (active[i] && note[i] == event_data[71:64]) begin
                                target_a[i] <= apply_delta(rom_step, $signed({event_data[55], event_data[55:40]}));
                                target_b[i] <= apply_delta(rom_step, -$signed({event_data[55], event_data[55:40]}));
                                revoice_hits = revoice_hits + 1;
                            end
                        if (revoice_hits != 0)
                            revoice_count <= revoice_count + revoice_hits[7:0];
                    end else if (event_data[94:91] == V2_EV_ALL_NOTES_OFF) begin
                        for (i = 0; i < VOICES; i = i + 1)
                            if (active[i]) begin
                                releasing[i] <= 1'b1;
                                env_stage[i] <= ENV_RELEASE;
                            end
                    end
                end
            end

            // Stage 3 writes the state and accumulates the contribution
            // computed on the previous clock.  The final sample is produced
            // here, after the oscillator result has crossed a register.
            if (calc_valid && calc_active) begin
                mix_acc <= mix_acc + calc_osc_sum;
                phase_a[calc_slot] <= calc_phase_a;
                phase_b[calc_slot] <= calc_phase_b;
                step_a[calc_slot]  <= calc_step_a;
                step_b[calc_slot]  <= calc_step_b;
                envelope[calc_slot] <= calc_envelope;
                env_stage[calc_slot] <= calc_env_stage;
                if (!calc_active_next) begin
                    active[calc_slot] <= 1'b0;
                    releasing[calc_slot] <= 1'b0;
                end
            end

            if (calc_valid && calc_last) begin
                if (calc_active)
                    mixed_sample <= saturate_sample(mix_acc + calc_osc_sum);
                else
                    mixed_sample <= saturate_sample(mix_acc);
                sample_valid <= 1'b1;
                scan_index   <= 6'd0;
                scan_base    <= (scan_base == VOICES - 1) ? 6'd0 : scan_base + 6'd1;
                mix_acc      <= 48'sd0;
            end

            // Stage 2 computes one state transition and one oscillator sum per
            // clock.  Its outputs are registered before the dynamic state
            // writeback and mixer accumulator, isolating both long paths.
            calc_valid       <= rd_valid;
            calc_last        <= rd_last;
            calc_active      <= rd_active;
            calc_slot        <= rd_slot;
            calc_osc_sum     <= 48'sd0;
            calc_phase_a     <= rd_phase_a + rd_step_a;
            calc_phase_b     <= rd_phase_b + rd_step_b;
            calc_step_a      <= rd_step_a;
            calc_step_b      <= rd_step_b;
            calc_envelope    <= rd_envelope;
            calc_env_stage   <= rd_env_stage;
            calc_active_next <= rd_active;
            if (rd_valid && rd_active) begin
                calc_osc_sum <= oscillator_value(rd_phase_a, rd_env_stage, rd_gain, rd_mix_a)
                              + oscillator_value(rd_phase_b, rd_env_stage, rd_gain, rd_mix_b);
                if (rd_step_a < rd_target_a)
                    calc_step_a <= rd_step_a + 32'd512;
                else if (rd_step_a > rd_target_a)
                    calc_step_a <= rd_step_a - 32'd512;
                if (rd_step_b < rd_target_b)
                    calc_step_b <= rd_step_b + 32'd512;
                else if (rd_step_b > rd_target_b)
                    calc_step_b <= rd_step_b - 32'd512;

                if (rd_env_stage == ENV_ATTACK) begin
                    if (rd_envelope + ATTACK_STEP >= 16'hFFFF) begin
                        calc_envelope <= 16'hFFFF;
                        calc_env_stage <= ENV_DECAY;
                    end else begin
                        calc_envelope <= rd_envelope + ATTACK_STEP;
                    end
                end else if (rd_env_stage == ENV_DECAY) begin
                    if (rd_envelope <= SUSTAIN_LEVEL + DECAY_STEP) begin
                        calc_envelope <= SUSTAIN_LEVEL;
                        calc_env_stage <= ENV_SUSTAIN;
                    end else begin
                        calc_envelope <= rd_envelope - DECAY_STEP;
                    end
                end else if (rd_env_stage == ENV_RELEASE) begin
                    if (rd_envelope <= RELEASE_STEP) begin
                        calc_envelope <= 16'd0;
                        calc_env_stage <= ENV_ATTACK;
                        calc_active_next <= 1'b0;
                    end else begin
                        calc_envelope <= rd_envelope - RELEASE_STEP;
                    end
                end
            end

            // Stage 1 reads one voice state per clock.  It runs concurrently
            // with stage 2 and stage 3, so the scan still accepts one slot per
            // cycle while the variable-indexed RAM output is isolated from
            // oscillator arithmetic and state writeback.
            if (scan_active) begin
                rd_valid     <= 1'b1;
                rd_last      <= (scan_index == VOICES - 1);
                rd_slot      <= scan_slot;
                rd_active    <= active[scan_slot];
                rd_phase_a   <= phase_a[scan_slot];
                rd_phase_b   <= phase_b[scan_slot];
                rd_step_a    <= step_a[scan_slot];
                rd_step_b    <= step_b[scan_slot];
                rd_target_a  <= target_a[scan_slot];
                rd_target_b  <= target_b[scan_slot];
                rd_envelope  <= envelope[scan_slot];
                rd_gain      <= gain[scan_slot];
                rd_mix_a     <= mix_a[scan_slot];
                rd_mix_b     <= mix_b[scan_slot];
                rd_env_stage <= env_stage[scan_slot];

                if (scan_index == VOICES - 1) begin
                    scan_active <= 1'b0;
                end else begin
                    scan_index <= scan_index + 6'd1;
                    scan_slot  <= (scan_slot == VOICES - 1) ? 6'd0 : scan_slot + 6'd1;
                end
            end else begin
                rd_valid <= 1'b0;
                rd_last  <= 1'b0;
                if (sample_ce) begin
                    scan_active <= 1'b1;
                    scan_index  <= 6'd0;
                    scan_slot   <= scan_base;
                    mix_acc     <= 48'sd0;
                end
            end
        end
    end

endmodule
