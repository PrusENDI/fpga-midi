// Atomic CSR request/response bridge. Configuration state is owned by the mode
// manager; this module never writes Loop RAM or bypasses mode validation.
module control_csr (
    input wire clk,rst_n,
    input wire req_valid, output wire req_ready,
    input wire req_write,input wire [7:0] req_addr,input wire [31:0] req_wdata,
    output reg rsp_valid,input wire rsp_ready,
    output reg [7:0] rsp_status,output reg [31:0] rsp_rdata,
    output reg cmd_valid,input wire cmd_ready,output reg [7:0] cmd_opcode,
    output reg [15:0] cmd_arg0,cmd_arg1,
    input wire cmd_rsp_valid,output wire cmd_rsp_ready,
    input wire [7:0] cmd_rsp_status,input wire [31:0] cmd_rsp_data,
    input wire [3:0] mode,input wire [1:0] selected_track,
    input wire [15:0] bpm_shadow,active_bpm,start_enter,start_exit,
    input wire [6:0] loop_tick,input wire active_valid,commit_pending,fault_latched,
    input wire [15:0] report_count,xyz_count,sample_count,
    input wire [7:0] note_on_count,
    input wire [2:0] active_voice_count,
    input wire [7:0] diag_flags,
    input wire [7:0] router_status
);
    import control_protocol_pkg::*;
    reg waiting;
    reg address_valid;
    reg [7:0] decoded_opcode;
    reg [31:0] read_value;
    assign req_ready=rst_n && !cmd_valid && !waiting && !rsp_valid;
    assign cmd_rsp_ready=rst_n && waiting && !rsp_valid;
    always @* begin
        address_valid=1; decoded_opcode=CMD_STATUS;read_value=0;
        if(req_write) begin
            case(req_addr)
                CSR_MODE: decoded_opcode=CMD_SET_MODE;
                CSR_BPM: decoded_opcode=CMD_SET_BPM;
                CSR_TRACK: decoded_opcode=CMD_SELECT_TRACK;
                CSR_PLAY: decoded_opcode=CMD_PLAY;
                CSR_STOP: decoded_opcode=CMD_STOP;
                CSR_RECORD: decoded_opcode=CMD_RECORD;
                CSR_OVERDUB: decoded_opcode=CMD_OVERDUB;
                CSR_CLEAR_TRACK: decoded_opcode=CMD_CLEAR_TRACK;
                CSR_CLEAR_ALL: decoded_opcode=CMD_CLEAR_ALL;
                CSR_COMMIT: decoded_opcode=CMD_COMMIT;
                CSR_RESET: decoded_opcode=CMD_RESET;
                CSR_THRESHOLDS: decoded_opcode=CMD_SET_THRESHOLDS;
                default: address_valid=0;
            endcase
        end else begin
            case(req_addr)
                CSR_STATUS,CSR_MODE: read_value={28'd0,mode};
                CSR_BPM: read_value={active_bpm,bpm_shadow};
                CSR_TRACK: read_value={30'd0,selected_track};
                CSR_THRESHOLDS: read_value={start_exit,start_enter};
                CSR_POSITION: read_value={21'd0,fault_latched,commit_pending,active_valid,1'b0,loop_tick};
                CSR_FAULT: read_value={31'd0,fault_latched};
                CSR_DIAG_INPUT: read_value={xyz_count,report_count};
                CSR_DIAG_AUDIO: read_value={sample_count,note_on_count,diag_flags};
                CSR_DIAG_ROUTER: read_value={24'd0,router_status};
                default: address_valid=0;
            endcase
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            waiting<=0;cmd_valid<=0;cmd_opcode<=0;cmd_arg0<=0;cmd_arg1<=0;
            rsp_valid<=0;rsp_status<=0;rsp_rdata<=0;
        end else begin
            if(rsp_valid && rsp_ready) rsp_valid<=0;
            if(cmd_valid && cmd_ready) begin cmd_valid<=0;waiting<=1;end
            if(cmd_rsp_valid && cmd_rsp_ready) begin
                waiting<=0;rsp_valid<=1;rsp_status<=cmd_rsp_status;rsp_rdata<=cmd_rsp_data;
            end
            if(req_valid && req_ready) begin
                if(!address_valid || !req_write) begin
                    rsp_valid<=1;rsp_status<=address_valid ? ACK_APPLIED : ACK_REJECTED;
                    rsp_rdata<=address_valid ? read_value : 32'd0;
                end else begin
                    cmd_valid<=1;cmd_opcode<=decoded_opcode;
                    cmd_arg0<=req_wdata[15:0];cmd_arg1<=req_wdata[31:16];
                end
            end
        end
    end
endmodule
