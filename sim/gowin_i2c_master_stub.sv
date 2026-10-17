module Gowin_I2C_Master(
    input I_CLK, input I_RESETN, input I_TX_EN, input [2:0] I_WADDR,
    input [7:0] I_WDATA, input I_RX_EN, input [2:0] I_RADDR,
    output [7:0] O_RDATA, output O_IIC_INT, inout SDA, inout SCL
);
    assign O_RDATA=8'h00;
    assign O_IIC_INT=1'b0;
    assign SDA=1'bz;
    assign SCL=1'bz;
endmodule
