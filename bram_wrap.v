// bram_wrap.v -- Verilog-2001 IPI wrapper around bram (bram.sv).
//
// bram has no AXI interfaces -- it exposes a plain simple-dual-port write +
// synchronous-read memory.  Only the clock is IPI-annotated so block-design
// auto-connect can attach it to the same domain as its parent.

`timescale 1ns / 1ps

module bram_wrap #(
    parameter DEPTH = 34240,
    parameter A_W   = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    input  wire             clk,

    input  wire             we,
    input  wire [A_W-1:0]   waddr,
    input  wire             wdata,

    input  wire [A_W-1:0]   raddr,
    output wire             rdata
);

    bram #(
        .DEPTH (DEPTH)
    ) u_core (
        .clk   (clk),
        .we    (we),
        .waddr (waddr),
        .wdata (wdata),
        .raddr (raddr),
        .rdata (rdata)
    );

endmodule
