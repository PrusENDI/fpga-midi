`timescale 1ns/1ps
module tb_v2_touch_info_decoder;
 logic field_valid; logic [31:0] info; logic [4:0] electrodes; logic touch;
 v2_touch_info_decoder dut(.field_valid,.touch_info(info),.electrode_mask(electrodes),.touch_state(touch));
 initial begin field_valid=0; info=0; #1 if(touch||electrodes!==0)$fatal(1,"absent"); field_valid=1; info=0; #1 if(touch)$fatal(1,"zero touch"); info=32'h1; #1 if(!touch||electrodes!==1)$fatal(1,"touch"); info=32'h20; #1 if(touch||electrodes!==0)$fatal(1,"tap-only"); field_valid=0; info=32'h1; #1 if(touch||electrodes!==0)$fatal(1,"error"); $display("tb_v2_touch_info_decoder PASS"); $finish; end
endmodule
