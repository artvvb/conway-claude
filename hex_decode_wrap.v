// hex_decode_wrap.v -- Verilog-2001 IPI wrapper around hex_decode (hex_decode.sv).
//
// The underlying module is purely combinational, so the wrapper has no clock
// or reset.  Both ports are annotated as AXI-Stream interfaces:
//   S_AXIS  : 8-bit ASCII byte in
//   M_AXIS  : 4-bit hex nibble out, with the invalid-character flag carried
//             on TUSER[0].
//
// IPI will not be able to do clock-domain analysis on these interfaces -- the
// module is meant to drop into the same domain as its producer / consumer.

`timescale 1ns / 1ps

module hex_decode_wrap (
    // ---- Slave: ASCII byte stream ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    input  wire [7:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire       s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire       s_axis_tready,

    // ---- Master: 4-bit hex nibble + 1-bit invalid flag on TUSER ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    output wire [3:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire       m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER" *)
    output wire       m_axis_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire       m_axis_tready
);

    hex_decode u_core (
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tuser  (m_axis_tuser),
        .m_axis_tready (m_axis_tready)
    );

endmodule
