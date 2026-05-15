// uart_rx_wrap.v -- Verilog-2001 IPI wrapper around uart_rx (uart_rx.sv).
//
// Annotates the 8-bit byte-out port group as an AXI-Stream master interface
// (M_AXIS) bound to clk / rst_n.  The serial `rxd` pin is left as a plain
// asynchronous input.

`timescale 1ns / 1ps

module uart_rx_wrap #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115_200
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET rst_n" *)
    input  wire       clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire       rst_n,

    input  wire       rxd,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    output wire [7:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire       m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire       m_axis_tready
);

    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_core (
        .clk           (clk),
        .rst_n         (rst_n),
        .rxd           (rxd),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready)
    );

endmodule
