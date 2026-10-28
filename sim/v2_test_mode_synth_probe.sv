// Standalone resource/timing probe for Task 8.5.
// Every v2_test_mode status/data output is a top-level observable so Gowin
// cannot sweep the test-mode logic during synthesis.
module v2_test_mode_synth_probe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input  logic        csr_valid,
    input  logic        csr_write,
    input  logic [7:0]  csr_addr,
    input  logic [31:0] csr_wdata,
    output logic        csr_ready,
    output logic        csr_rvalid,
    output logic [31:0] csr_rdata,
    output logic signed [15:0] mixed_sample,
    output logic        sample_valid,
    output logic [31:0] active_bitmap,
    output logic [31:0] sample_counter,
    output logic        test_active,
    output logic        fault
);
    (* keep_hierarchy = "yes" *)
    v2_test_mode #(.MAX_TONES(32)) dut (
        .clk,
        .rst_n,
        .sample_ce,
        .csr_valid,
        .csr_write,
        .csr_addr,
        .csr_wdata,
        .csr_ready,
        .csr_rvalid,
        .csr_rdata,
        .mixed_sample,
        .sample_valid,
        .active_bitmap,
        .sample_counter,
        .test_active,
        .fault
    );
endmodule
