// conway_wrap.v -- Verilog-2001 IPI wrapper around conway (conway.sv).
//
// Annotates the 1-bit pixel output as an AXI-Stream master interface (M_AXIS)
// bound to clk / rst_n.  IP Integrator will warn that TDATA is not a multiple
// of 8 bits; this is intentional -- the conway engine emits one bit per pixel
// cycle and the downstream pixel expander (conway_top in the existing flat
// design, a separate IP block in the IPI flow) widens to 12-bit R4G4B4.
//
// frame_start, run, frame_done, and the prog_* group are plain side-band
// pins; they have no standard AXI mapping.

`timescale 1ns / 1ps

module conway_wrap #(
    parameter W   = 640,
    parameter H   = 480,
    parameter X_W = $clog2(W),
    parameter Y_W = $clog2(H)
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET rst_n" *)
    input  wire             clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire             rst_n,

    input  wire             frame_start,

    // ---- M_AXIS: 1-bit pixel out ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    output wire             m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire             m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire             m_axis_tready,

    // ---- Engine control (plain pins) ----
    input  wire             run,
    output wire             frame_done,

    // ---- Programming interface (plain pins) ----
    input  wire             prog_mode,
    input  wire             prog_we,
    input  wire [X_W-1:0]   prog_x,
    input  wire [Y_W-1:0]   prog_y,
    input  wire             prog_data
);

    conway #(
        .W (W),
        .H (H)
    ) u_core (
        .clk           (clk),
        .rst_n         (rst_n),
        .frame_start   (frame_start),

        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),

        .run           (run),
        .frame_done    (frame_done),

        .prog_mode     (prog_mode),
        .prog_we       (prog_we),
        .prog_x        (prog_x),
        .prog_y        (prog_y),
        .prog_data     (prog_data)
    );

endmodule
