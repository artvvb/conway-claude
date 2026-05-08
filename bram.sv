// bram.sv -- Parameterised 1-bit-wide block RAM with synchronous read.
//
// Single write port, single read port, both clocked on the same edge.
// Read latency is one cycle (rdata <= mem[raddr]).  The 1-D mem array is
// the canonical Vivado BRAM-inference template; the (* ram_style = "block" *)
// attribute pins the choice to a true block RAM rather than distributed/LUT
// RAM, even at depths where either could fit.
//
// Default DEPTH = 34240 = ceil(640/3) * ceil(480/3) = W3 * H3 for the
// default 640 x 480 conway grid; conway.sv overrides this at instantiation.
//
// Why a separate module?  Vivado's 3-D-array inference is unreliable
// (Synth 8-11357 "Potential Runtime issue for 3D-RAM ... 308160 registers"
// can stall synthesis), so each conway BRAM is instantiated as a flat 1-D
// array inside its own module instead.

`ifndef BRAM_SV
`define BRAM_SV

`timescale 1ns / 1ps

module bram #(
    parameter int DEPTH = 34240,
    parameter int A_W   = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  wire             clk,

    input  wire             we,
    input  wire [A_W-1:0]   waddr,
    input  wire             wdata,

    input  wire [A_W-1:0]   raddr,
    output logic            rdata
);

    (* ram_style = "block" *) logic mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule

`endif
