`timescale 1ns/1ps
module tb_live_xyz_mapper;
    import performance_event_pkg::*;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, enable=0, flush=0;
    reg report_valid=0, xyz_valid=1, report_error=0;
    reg [15:0] x_position=0, y_position=0, z_position=16'h4a38;
    reg [1:0] selected_track=0;
    wire event_valid; reg event_ready=1; wire [63:0] event_data;
    wire modulation_valid; reg modulation_ready=1; wire [63:0] modulation_data;
    wire idle, overflow;

    // LIVE should accept ordinary hand jitter without requiring a long
    // three-report settling interval.  The production defaults are tested
    // here so a threshold regression is visible before changing RTL.
    live_xyz_mapper dut (.*);

    integer events=0, ons=0, offs=0, revoices=0, mods=0;
    reg [6:0] last_note;
    task tick; begin @(posedge clk); #1; end endtask
    task report(input [15:0] x,input [15:0] y,input [15:0] z);
      begin
        @(negedge clk); x_position=x; y_position=y; z_position=z; report_valid=1;
        tick; @(negedge clk); report_valid=0; repeat(2) tick;
      end
    endtask
    task stable(input [15:0] x,input [15:0] y,input [15:0] z);
      begin report(x,y,z); report(x,y,z); report(x,y,z); end
    endtask
    initial begin
      repeat(2) tick; rst_n=1; enable=1;
      // Half the previous trigger height: 0x5000 must remain released, while
      // 0x4800 (18432) enters the pressure band after XY settles.
      report(16'h1000,16'h8000,16'h5000);
      report(16'h1200,16'h8200,16'h5000);
      report(16'h1400,16'h8400,16'h5000);
      if (ons != 0) $fatal(1,"Z trigger is still above the half-range point");
      report(16'h1600,16'h8600,16'h4800);
      report(16'h1800,16'h8800,16'h4800);
      report(16'h1a00,16'h8a00,16'h4800);
      if (ons != 1) $fatal(1,"Z=18432 did not trigger");
      report(16'h1a00,16'h8a00,16'h5800);
      if (offs != 1) $fatal(1,"Z release buffer did not emit NOTE_OFF");
      // Entering the 4096..36864 pressure band must trigger.  Values below
      // 4096 are touch saturation and are clamped to maximum pressure.
      report(16'h1000,16'h8000,16'h4800);
      report(16'h1200,16'h8200,16'h4800);
      report(16'h1400,16'h8400,16'h4800);
      if (ons != 2 || last_note != 60) $fatal(1,"Z press must select X zone 0 note C4");
      // A real report stream can move several thousand counts between
      // adjacent samples while the hand is already over one note zone.  It
      // must still qualify as settled after the short LIVE confirmation.
      report(16'h1600,16'h8600,16'h4800);
      if (ons != 2) $fatal(1,"moderate XY jitter must not retrigger NOTE_ON");
      report(16'h1800,16'h8800,16'h4800);
      if (ons != 2) $fatal(1,"Y-only movement changed note");
      stable(16'hefff,16'h8000,16'h4800);
      if (revoices != 1 || last_note != 72) $fatal(1,"stable X change must revoice to C5");
      report(16'hefff,16'h8000,16'h5800);
      if (offs != 2) $fatal(1,"Z release must emit NOTE_OFF");
      report(16'hefff,16'h8000,16'h4800);
      if (ons != 3) $fatal(1,"second Z press must emit NOTE_ON");
      // A stationary hand must hold one NOTE_ON; DDS should sustain it rather
      // than receive periodic retriggers from the event mapper.
      repeat (80) report(16'hefff,16'h8000,16'h4800);
      if (ons != 3 || offs != 2) $fatal(1,"stationary XYZ retriggered the note: on=%0d off=%0d",ons,offs);
      modulation_ready=0; report(16'hefff,16'h8000,16'h1000); report(16'hefff,16'h8000,16'h0c00);
      if (!modulation_valid || modulation_data[49:42] == 0) $fatal(1,"pressure latest-value was not held");
      modulation_ready=1; tick; if (mods == 0) $fatal(1,"pressure point was lost");
      flush=1; tick; flush=0; if (!event_valid && !modulation_valid && !idle) $fatal(1,"flush state");
      $display("tb_live_xyz_mapper PASS"); $finish;
    end
    always @(posedge clk) begin
      if (event_valid && event_ready) begin
        events=events+1;
        case (event_data[2:0])
          EVENT_NOTE_ON: begin ons=ons+1; last_note=event_data[25:19]; end
          EVENT_NOTE_OFF: offs=offs+1;
          EVENT_NOTE_REVOICE: begin revoices=revoices+1; last_note=event_data[25:19]; end
          default:;
        endcase
      end
      if (modulation_valid && modulation_ready) mods=mods+1;
    end
    initial begin #100000; $fatal(1,"test timeout"); end
endmodule
