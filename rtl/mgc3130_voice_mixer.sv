// Four-voice DDS mixer. Legacy events select a square-wave chord. LIVE events
// can select a square-wave voice with slew-limited gain and pitch.
module mgc3130_voice_mixer #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SAMPLE_HZ = 48_000,
    parameter integer VOICE_COUNT = 4,
    parameter integer ENV_SHIFT = 3,
    parameter integer GLIDE_SHIFT = 4
) (
    input wire clk, input wire rst_n,
    input wire note_on, input wire note_off,
    input wire [6:0] note_number, input wire [7:0] velocity,
    input wire expression_valid, input wire soft_timbre,
    output reg sample_valid, output reg signed [15:0] mixed_sample,
    output reg [2:0] active_voice_count
);
    localparam integer SAMPLE_DIV = (CLK_HZ / SAMPLE_HZ < 1) ? 1 : CLK_HZ / SAMPLE_HZ;
    localparam [8:0] REST_SAMPLES = SAMPLE_HZ / 200;
    reg [15:0] sample_counter;
    reg [31:0] phase [0:3], phase_step [0:3], target_step [0:3];
    reg [7:0] gain [0:3], target_gain [0:3];
    reg active [0:3];
    reg soft_mode;
    reg [8:0] rest_samples;
    reg pending_valid;
    reg [6:0] pending_note;
    reg [7:0] pending_gain;
    integer i;
    integer signed sum, voice_value, scaled_sum, glide_delta;

    function [31:0] note_step;
        input [6:0] n;
        begin
            case (n)
                7'd48: note_step=32'd11237; 7'd49: note_step=32'd11905;
                7'd50: note_step=32'd12613; 7'd51: note_step=32'd13363;
                7'd52: note_step=32'd14157; 7'd53: note_step=32'd14999;
                7'd54: note_step=32'd15891; 7'd55: note_step=32'd16836;
                7'd56: note_step=32'd17837; 7'd57: note_step=32'd18898;
                7'd58: note_step=32'd20022; 7'd59: note_step=32'd21212;
                7'd60: note_step=32'd22473; 7'd61: note_step=32'd23810;
                7'd62: note_step=32'd25226; 7'd63: note_step=32'd26726;
                7'd64: note_step=32'd28315; 7'd65: note_step=32'd29998;
                7'd66: note_step=32'd31782; 7'd67: note_step=32'd33672;
                7'd68: note_step=32'd35674; 7'd69: note_step=32'd37796;
                7'd70: note_step=32'd40043;
                default: note_step=32'd42424;
            endcase
        end
    endfunction
    function [6:0] chord_third;
        input [6:0] root;
        begin
            if (((root%12)==2)||((root%12)==4)||((root%12)==9)||((root%12)==11)) chord_third=root+3;
            else chord_third=root+4;
        end
    endfunction
    function [6:0] chord_fifth;
        input [6:0] root;
        begin if ((root%12)==11) chord_fifth=root+6; else chord_fifth=root+7; end
    endfunction

    task start_chord;
        input [6:0] root; input [7:0] level;
        begin
            active[0]<=1; active[1]<=1; active[2]<=1; active[3]<=0;
            phase[0]<=0; phase[1]<=0; phase[2]<=0;
            phase_step[0]<=note_step(root); phase_step[1]<=note_step(chord_third(root)); phase_step[2]<=note_step(chord_fifth(root));
            target_step[0]<=note_step(root); target_step[1]<=note_step(chord_third(root)); target_step[2]<=note_step(chord_fifth(root)); target_step[3]<=0;
            gain[0]<=level; gain[1]<=level; gain[2]<=level; gain[3]<=0;
            target_gain[0]<=level; target_gain[1]<=level; target_gain[2]<=level; target_gain[3]<=0;
        end
    endtask

    task start_soft_chord;
        input [6:0] root; input [7:0] level;
        begin
            active[0]<=1; active[1]<=1; active[2]<=1; active[3]<=0;
            target_gain[0]<=level; target_gain[1]<=level; target_gain[2]<=level; target_gain[3]<=0;
            target_step[0]<=note_step(root); target_step[1]<=note_step(chord_third(root)); target_step[2]<=note_step(chord_fifth(root)); target_step[3]<=0;
            if (!(active[0]||active[1]||active[2])) begin
                phase[0]<=0; phase[1]<=0; phase[2]<=0;
                phase_step[0]<=note_step(root); phase_step[1]<=note_step(chord_third(root)); phase_step[2]<=note_step(chord_fifth(root));
                gain[0]<=0; gain[1]<=0; gain[2]<=0; gain[3]<=0;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_counter<=0; sample_valid<=0; mixed_sample<=0; active_voice_count<=0;
            rest_samples<=0; pending_valid<=0; pending_note<=48; pending_gain<=0; soft_mode<=0;
            for(i=0;i<4;i=i+1) begin phase[i]<=0; phase_step[i]<=0; target_step[i]<=0; gain[i]<=0; target_gain[i]<=0; active[i]<=0; end
        end else begin
            sample_valid<=0;
            if (note_off) begin
                if (soft_timbre) begin
                    soft_mode<=1; rest_samples<=0; pending_valid<=0;
                    for(i=0;i<4;i=i+1) target_gain[i]<=0;
                    if (note_on) start_soft_chord(note_number,velocity);
                end else begin
                    soft_mode<=0; rest_samples<=REST_SAMPLES; pending_valid<=note_on;
                    for(i=0;i<4;i=i+1) begin active[i]<=0; gain[i]<=0; target_gain[i]<=0; end
                    if(note_on) begin pending_note<=note_number; pending_gain<=velocity; end
                end
            end else if (note_on) begin
                if (soft_timbre) begin soft_mode<=1; rest_samples<=0; pending_valid<=0; start_soft_chord(note_number,velocity); end
                else begin soft_mode<=0; start_chord(note_number,velocity); end
            end
            if(expression_valid) begin
                if(soft_mode) for(i=0;i<4;i=i+1) target_gain[i]<=velocity;
                else for(i=0;i<4;i=i+1) if(active[i]) gain[i]<=velocity;
            end
            for(i=0;i<4;i=i+1) if(active[i]) begin
                phase[i]<=phase[i]+phase_step[i];
                if(soft_mode && phase_step[i]!=target_step[i]) begin
                    glide_delta=$signed({1'b0,target_step[i]})-$signed({1'b0,phase_step[i]});
                    if(glide_delta>(1<<GLIDE_SHIFT)) phase_step[i]<=phase_step[i]+(glide_delta>>>GLIDE_SHIFT);
                    else if(glide_delta<-(1<<GLIDE_SHIFT)) phase_step[i]<=phase_step[i]-((-glide_delta)>>>GLIDE_SHIFT);
                    else phase_step[i]<=target_step[i];
                end
            end
            if(sample_counter==SAMPLE_DIV-1) begin
                sample_counter<=0; sample_valid<=1;
                if(soft_mode) for(i=0;i<4;i=i+1) begin
                    if(gain[i]<target_gain[i]) begin
                        if((target_gain[i]-gain[i])>(1<<ENV_SHIFT)) gain[i]<=gain[i]+((target_gain[i]-gain[i])>>ENV_SHIFT); else gain[i]<=target_gain[i];
                    end else if(gain[i]>target_gain[i]) begin
                        if((gain[i]-target_gain[i])>(1<<ENV_SHIFT)) gain[i]<=gain[i]-((gain[i]-target_gain[i])>>ENV_SHIFT); else gain[i]<=target_gain[i];
                    end
                    if(target_gain[i]==0 && gain[i]==0) begin active[i]<=0; phase_step[i]<=0; end
                end
                else begin
                    if(rest_samples!=0) rest_samples<=rest_samples-1'b1;
                    else if(pending_valid) begin start_chord(pending_note,pending_gain); pending_valid<=0; end
                end
                sum=0;
                for(i=0;i<4;i=i+1) if(active[i]) begin
                    if(soft_mode) begin
                        if(phase[i][31]) voice_value=gain[i]; else voice_value=-gain[i];
                        sum=sum+voice_value;
                    end else begin if(phase[i][31]) voice_value=gain[i]; else voice_value=-gain[i]; sum=sum+voice_value; end
                end
                if(soft_mode) scaled_sum=sum*256; else scaled_sum=sum*256;
                if(scaled_sum>32767) mixed_sample<=16'sh7fff; else if(scaled_sum< -32768) mixed_sample<=-16'sh8000; else mixed_sample<=scaled_sum[15:0];
            end else sample_counter<=sample_counter+1'b1;
            active_voice_count<=active[0]+active[1]+active[2]+active[3];
        end
    end
endmodule
