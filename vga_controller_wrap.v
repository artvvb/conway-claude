// vga_controller_wrap.v -- Verilog-2001 IPI wrapper around vga_controller (vga.sv).
//
// Annotates the pixel-input port group as an AXI-Stream slave interface
// (S_AXIS) and binds clk / rst_n to it.  The VGA pin group (vga_r/g/b,
// vga_hsync, vga_vsync, vga_de, frame_start) is left as plain ports
// since it is not a standard AXI bus.

`timescale 1ns / 1ps

module vga_controller_wrap #(
    parameter H_ACTIVE      = 640,
    parameter H_FRONT_PORCH = 16,
    parameter H_SYNC_WIDTH  = 96,
    parameter H_BACK_PORCH  = 48,
    parameter V_ACTIVE      = 480,
    parameter V_FRONT_PORCH = 10,
    parameter V_SYNC_WIDTH  = 2,
    parameter V_BACK_PORCH  = 33,
    parameter HSYNC_POL     = 1'b0,
    parameter VSYNC_POL     = 1'b0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS, ASSOCIATED_RESET rst_n" *)
    input  wire        clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        rst_n,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    input  wire [11:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire        s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire        s_axis_tready,

    output wire [3:0]  vga_r,
    output wire [3:0]  vga_g,
    output wire [3:0]  vga_b,
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        vga_de,
    output wire        frame_start
);

    vga_controller #(
        .H_ACTIVE      (H_ACTIVE),
        .H_FRONT_PORCH (H_FRONT_PORCH),
        .H_SYNC_WIDTH  (H_SYNC_WIDTH),
        .H_BACK_PORCH  (H_BACK_PORCH),
        .V_ACTIVE      (V_ACTIVE),
        .V_FRONT_PORCH (V_FRONT_PORCH),
        .V_SYNC_WIDTH  (V_SYNC_WIDTH),
        .V_BACK_PORCH  (V_BACK_PORCH),
        .HSYNC_POL     (HSYNC_POL),
        .VSYNC_POL     (VSYNC_POL)
    ) u_core (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .vga_r         (vga_r),
        .vga_g         (vga_g),
        .vga_b         (vga_b),
        .vga_hsync     (vga_hsync),
        .vga_vsync     (vga_vsync),
        .vga_de        (vga_de),
        .frame_start   (frame_start)
    );

endmodule
