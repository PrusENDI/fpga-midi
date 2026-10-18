// Two-oscillator LIVE/Loop voice with a continuous DDS glide.
module mgc3130_voice_mixer #(
    parameter integer CLK_HZ=50_000_000,
    parameter integer SAMPLE_HZ=48_000,
    parameter integer VOICE_COUNT=4
)(
    input wire clk, input wire rst_n,
    input wire note_on, input wire note_off, input wire note_revoice,
    input wire [6:0] note_number, input wire [7:0] velocity,
    input wire expression_valid,
    output reg sample_valid, output reg signed [15:0] mixed_sample,
    output reg [2:0] active_voice_count
);
    localparam integer PITCH_SLEW_PER_SAMPLE = 512;
    localparam integer GAIN_SLEW_PER_SAMPLE = 2;
    localparam [7:0] GAIN_SLEW = 8'd2;
    localparam [31:0] VIBRATO_STEP = (64'd5 * 64'd4294967296) / SAMPLE_HZ;
    reg [31:0] sample_phase;
    reg [31:0] phase_main, phase_aux;
    reg [31:0] current_step, target_step;
    reg [7:0] gain, target_gain;
    reg active;
    reg [31:0] vibrato_phase;
    integer signed main_wave, aux_wave, mix_value, scaled_value;
    integer signed vib_wave, vib_offset, gain_value;
    wire sample_tick = (sample_phase + SAMPLE_HZ >= CLK_HZ);

    function automatic [31:0] note_step(input [6:0] n);
      begin case(n)
        48:note_step=32'd11704930; 49:note_step=32'd12400941;
        50:note_step=32'd13138339; 51:note_step=32'd13919586;
        52:note_step=32'd14747287; 53:note_step=32'd15624207;
        54:note_step=32'd16553270; 55:note_step=32'd17537579;
        56:note_step=32'd18580418; 57:note_step=32'd19685267;
        58:note_step=32'd20855814; 59:note_step=32'd22095965;
        60:note_step=32'd23409859; 61:note_step=32'd24801882;
        62:note_step=32'd26276679; 63:note_step=32'd27839171;
        64:note_step=32'd29494575; 65:note_step=32'd31248413;
        66:note_step=32'd33106541; 67:note_step=32'd35075158;
        68:note_step=32'd37160835; 69:note_step=32'd39370534;
        70:note_step=32'd41711627; 71:note_step=32'd44191930;
        72:note_step=32'd46819719;
        default:note_step=32'd46819719;
      endcase end
    endfunction
    function automatic integer signed triangle_value(input [31:0] p);
      integer unsigned u;
      begin u=p[31:16]; if(!p[31]) triangle_value=(u*2)-32768;
            else triangle_value=98303-(u*2); end
    endfunction
    function automatic integer signed saw_value(input [31:0] p);
      begin saw_value=p[31:16]-32768; end
    endfunction

    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        sample_phase<=0; sample_valid<=0; mixed_sample<=0;
        active_voice_count<=0; phase_main<=0; phase_aux<=0;
        current_step<=0; target_step<=0; gain<=0; target_gain<=0;
        active<=0; vibrato_phase<=0;
      end else begin
        sample_valid<=0;
        if(note_off) begin active<=0; gain<=0; target_gain<=0; end
        else if(note_on) begin
          active<=1; phase_main<=0; phase_aux<=0;
          current_step<=note_step(note_number); target_step<=note_step(note_number);
          gain<=0; target_gain<=velocity; vibrato_phase<=0;
        end else if(note_revoice && active) target_step<=note_step(note_number);
        if(expression_valid && active) target_gain<=velocity;
        if(sample_tick) begin
          sample_phase <= sample_phase + SAMPLE_HZ - CLK_HZ;
          sample_valid<=1;
          if(active) begin
            if(current_step<target_step) begin
              if((target_step-current_step)<=PITCH_SLEW_PER_SAMPLE) current_step<=target_step;
              else current_step<=current_step+PITCH_SLEW_PER_SAMPLE;
            end else if(current_step>target_step) begin
              if((current_step-target_step)<=PITCH_SLEW_PER_SAMPLE) current_step<=target_step;
              else current_step<=current_step-PITCH_SLEW_PER_SAMPLE;
            end
            if(gain<target_gain) begin
              if((target_gain-gain)<=GAIN_SLEW_PER_SAMPLE) gain<=target_gain;
              else gain<=gain+GAIN_SLEW;
            end else if(gain>target_gain) begin
              if((gain-target_gain)<=GAIN_SLEW_PER_SAMPLE) gain<=target_gain;
              else gain<=gain-GAIN_SLEW;
            end
            vib_wave=triangle_value(vibrato_phase);
            vib_offset=(current_step>>>15)*(vib_wave>>>8);
            phase_main<=phase_main+current_step+vib_offset;
            phase_aux<=phase_aux+current_step+(current_step>>>9)+vib_offset;
            vibrato_phase<=vibrato_phase+VIBRATO_STEP;
            main_wave=triangle_value(phase_main); aux_wave=saw_value(phase_aux);
            gain_value=gain; mix_value=((main_wave*9)+aux_wave)/10;
            scaled_value=(mix_value*gain_value*3)>>>10;
            if(scaled_value>32767) mixed_sample<=16'sh7fff;
            else if(scaled_value< -32768) mixed_sample<=-16'sh8000;
            else mixed_sample<=scaled_value[15:0];
          end else mixed_sample<=0;
        end else begin
          sample_phase <= sample_phase + SAMPLE_HZ;
        end
        active_voice_count<=active?3'd2:3'd0;
      end
    end
endmodule
