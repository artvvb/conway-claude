// vga.sv — VGA controller with AXI-Stream pixel input and backpressure
//
// Default parameters target 640×480 @ 60 Hz (pixel clock = 25.175 MHz).
// Drive `clk` at the pixel clock rate from a PLL or MMCM.
//
// AXI-Stream backpressure
//   s_axis_tready is deasserted for every blanking cycle (horizontal and
//   vertical).  An upstream pipeline that gates its enable on tready will
//   naturally stall during blanking and produce exactly one pixel per active
//   clock — no explicit frame/line sync signals needed by the producer.
//
// Pixel format
//   tdata[11:8] = R[3:0],  tdata[7:4] = G[3:0],  tdata[3:0] = B[3:0]
//
// Output pipeline
//   All VGA outputs are registered once for glitch-free drive.  The uniform
//   1-cycle latency preserves all setup/hold relationships between de, rgb,
//   hsync, and vsync as seen by the monitor.
//
// Reset
//   Active-low asynchronous assert, synchronous deassert recommended.
//   Counters start at (0,0) = first active pixel on release; hold rst_n low
//   long enough for upstream pipelines to drain before the first active line.

`timescale 1ns / 1ps
`default_nettype none

module vga_controller #(
    // --- Horizontal timing (pixel-clock cycles) ---
    parameter int H_ACTIVE      = 640,
    parameter int H_FRONT_PORCH = 16,
    parameter int H_SYNC_WIDTH  = 96,
    parameter int H_BACK_PORCH  = 48,
    // --- Vertical timing (lines) ---
    parameter int V_ACTIVE      = 480,
    parameter int V_FRONT_PORCH = 10,
    parameter int V_SYNC_WIDTH  = 2,
    parameter int V_BACK_PORCH  = 33,
    // --- Sync polarity: 0 = active-low (standard 640×480), 1 = active-high ---
    parameter bit HSYNC_POL     = 1'b0,
    parameter bit VSYNC_POL     = 1'b0
) (
    input  wire        clk,    // pixel clock — 25.175 MHz nominal for 640×480@60
    input  wire        rst_n,  // asynchronous active-low reset

    // AXI-Stream slave — R4G4B4 pixel data
    input  wire [11:0] s_axis_tdata,   // {R[3:0], G[3:0], B[3:0]}
    input  wire        s_axis_tvalid,
    output logic       s_axis_tready,  // 0 during blanking → stalls upstream

    // VGA outputs
    output logic [3:0] vga_r,
    output logic [3:0] vga_g,
    output logic [3:0] vga_b,
    output logic       vga_hsync,
    output logic       vga_vsync,
    output logic       vga_de,         // display enable, high during active region

    // Frame-start strobe — combinational, asserted for one pixel clock during
    // the very last blanking cycle before the raster counters wrap to (0, 0).
    // The upstream has exactly one full cycle to register pending state changes
    // before s_axis_tready rises for the first pixel of the new frame.
    output wire        frame_start
);

    // -------------------------------------------------------------------------
    // Derived timing constants
    //   Horizontal: active | front porch | sync | back porch  = 800 total
    //   Vertical:   active | front porch | sync | back porch  = 525 total
    // -------------------------------------------------------------------------
    localparam int H_SYNC_START = H_ACTIVE + H_FRONT_PORCH;        // 656
    localparam int H_SYNC_END   = H_SYNC_START + H_SYNC_WIDTH;     // 752
    localparam int H_TOTAL      = H_SYNC_END   + H_BACK_PORCH;     // 800

    localparam int V_SYNC_START = V_ACTIVE + V_FRONT_PORCH;        // 490
    localparam int V_SYNC_END   = V_SYNC_START + V_SYNC_WIDTH;     // 492
    localparam int V_TOTAL      = V_SYNC_END   + V_BACK_PORCH;     // 525

    localparam int H_CNT_W = $clog2(H_TOTAL);   // 10 bits covers 800
    localparam int V_CNT_W = $clog2(V_TOTAL);   // 10 bits covers 525

    // -------------------------------------------------------------------------
    // Raster counters
    // -------------------------------------------------------------------------
    logic [H_CNT_W-1:0] h_cnt;
    logic [V_CNT_W-1:0] v_cnt;

    wire h_last = (h_cnt == H_CNT_W'(H_TOTAL - 1));
    wire v_last = (v_cnt == V_CNT_W'(V_TOTAL - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= '0;
            v_cnt <= '0;
        end else if (h_last) begin
            h_cnt <= '0;
            v_cnt <= v_last ? '0 : v_cnt + 1'b1;
        end else begin
            h_cnt <= h_cnt + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Region decode (combinational from registered counters)
    // -------------------------------------------------------------------------
    wire active   = (h_cnt < H_CNT_W'(H_ACTIVE)) &&
                    (v_cnt < V_CNT_W'(V_ACTIVE));

    wire in_hsync = (h_cnt >= H_CNT_W'(H_SYNC_START)) &&
                    (h_cnt <  H_CNT_W'(H_SYNC_END));

    wire in_vsync = (v_cnt >= V_CNT_W'(V_SYNC_START)) &&
                    (v_cnt <  V_CNT_W'(V_SYNC_END));

    // h_last && v_last is the final cycle of blanking; on the next posedge
    // h_cnt and v_cnt wrap to 0 and s_axis_tready rises for pixel (0, 0).
    assign frame_start = h_last && v_last;

    // -------------------------------------------------------------------------
    // AXI-Stream backpressure
    //
    // tready is asserted combinationally so the upstream sees it one full cycle
    // before the corresponding counter advance, satisfying AXI-S timing and
    // giving the producer a full cycle to present new data.
    //
    // A transaction occurs (upstream pixel consumed) when tready AND tvalid are
    // both 1.  VGA timing is fixed; if the upstream cannot supply data (tvalid=0
    // during active) the pixel outputs black for that position.
    // -------------------------------------------------------------------------
    assign s_axis_tready = active;

    // -------------------------------------------------------------------------
    // Output registers
    //
    // Every VGA output is delayed by exactly one pixel clock from its counter
    // decode.  Because the delay is uniform, all timing relationships — the
    // gap from hsync leading edge to de assertion, from de trailing edge to
    // vsync, etc. — remain exactly as specified by the parameters.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vga_de    <= 1'b0;
            // Idle sync levels: no pulse asserted regardless of polarity
            vga_hsync <= HSYNC_POL ? 1'b0 : 1'b1;
            vga_vsync <= VSYNC_POL ? 1'b0 : 1'b1;
            vga_r     <= 4'h0;
            vga_g     <= 4'h0;
            vga_b     <= 4'h0;
        end else begin
            vga_de    <= active;
            vga_hsync <= HSYNC_POL ? in_hsync : ~in_hsync;
            vga_vsync <= VSYNC_POL ? in_vsync : ~in_vsync;

            if (active && s_axis_tvalid) begin
                vga_r <= s_axis_tdata[11:8];
                vga_g <= s_axis_tdata[7:4];
                vga_b <= s_axis_tdata[3:0];
            end else begin
                // Blanking or underflow — drive black.
                vga_r <= 4'h0;
                vga_g <= 4'h0;
                vga_b <= 4'h0;
            end
        end
    end

endmodule

`default_nettype wire
