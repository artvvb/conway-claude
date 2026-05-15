// uart_cmd_wrap.v -- Verilog-2001 IPI wrapper around uart_cmd (uart_cmd.sv).
//
// The underlying module accepts the raw byte stream from uart_rx AND the
// hex-decoded nibble + invalid flag from hex_decode IN PARALLEL on a single
// shared tvalid/tready handshake (hex_decode is purely combinational, so its
// outputs track the byte stream cycle-for-cycle).  This is not a standard
// AXI-Stream pattern.
//
// IPI annotation strategy
//   - The byte path (s_axis_byte_tdata + s_axis_tvalid + s_axis_tready) is
//     annotated as a regular AXI-Stream slave called S_AXIS.  Block-designs
//     can auto-connect uart_rx_wrap.M_AXIS -> uart_cmd_wrap.S_AXIS this way.
//   - The nibble + invalid inputs are left as plain side-band signals, NOT
//     part of any AXIS interface.  Wire them from hex_decode_wrap.M_AXIS.TDATA
//     and M_AXIS.TUSER manually in the block design.  The two consumers
//     (uart_cmd, hex_decode) of the same byte stream share TREADY through
//     hex_decode's pass-through.
//
// The engine-control / programming-interface ports are not AXI buses; they
// pass through unchanged.

`timescale 1ns / 1ps

module uart_cmd_wrap #(
    parameter W   = 640,
    parameter H   = 480,
    parameter X_W = $clog2(W),
    parameter Y_W = $clog2(H)
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS, ASSOCIATED_RESET rst_n" *)
    input  wire             clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire             rst_n,

    // ---- S_AXIS: raw byte stream from uart_rx ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    input  wire [7:0]       s_axis_byte_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire             s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire             s_axis_tready,

    // ---- Side-band nibble inputs (synchronised to S_AXIS handshake) ----
    input  wire [3:0]       s_axis_nibble_tdata,
    input  wire             s_axis_nibble_tuser,

    // ---- Engine control (plain pins) ----
    output wire             run,
    input  wire             frame_done,
    input  wire             frame_start,

    // ---- Programming interface (plain pins) ----
    output wire             prog_mode,
    output wire             prog_we,
    output wire [X_W-1:0]   prog_x,
    output wire [Y_W-1:0]   prog_y,
    output wire             prog_data
);

    uart_cmd #(
        .W (W),
        .H (H)
    ) u_core (
        .clk                 (clk),
        .rst_n               (rst_n),

        .s_axis_byte_tdata   (s_axis_byte_tdata),
        .s_axis_nibble_tdata (s_axis_nibble_tdata),
        .s_axis_nibble_tuser (s_axis_nibble_tuser),
        .s_axis_tvalid       (s_axis_tvalid),
        .s_axis_tready       (s_axis_tready),

        .run                 (run),
        .frame_done          (frame_done),
        .frame_start         (frame_start),

        .prog_mode           (prog_mode),
        .prog_we             (prog_we),
        .prog_x              (prog_x),
        .prog_y              (prog_y),
        .prog_data           (prog_data)
    );

endmodule
