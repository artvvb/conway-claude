// conway.sv -- Streaming Conway's Game of Life with dual BRAM-banked framebuffers.
//
// Mirrors conway.py.  Each framebuffer is a 3x3 array of 1-bit inferred BRAMs;
// pixel (x, y) lives in BRAM[x%3][y%3] at address (y/3)*W3 + (x/3), where
// W3 = ceil(W/3) and H3 = ceil(H/3).  Any 3x3 neighbourhood reads each of the
// nine BRAMs at most once -> conflict-free parallel read.
//
// Boundary policy
//   conway.py wraps toroidally; that requires W%3 == H%3 == 0 to keep the
//   x-1, x, x+1 neighbours in distinct mod-3 banks at the wrap point.  This
//   module instead uses BOUNDED edges: pixels outside [0, W-1] x [0, H-1]
//   contribute 0 to the live count.  With bounded edges the three pixels
//   {cx-1, cx, cx+1} (clipped, never wrapped) always sit in distinct mod-3
//   banks for any cx, so W and H may be ANY positive integers (in particular
//   640 x 480 works without any 3-divisibility constraint).
//
// Pipeline (1 register stage = synchronous BRAM read)
//   Cycle N    : read addresses for (cx, cy) presented to the read FB.
//                Mask bits indicating off-grid neighbours computed in parallel.
//   Cycle N+1  : bram_rdata holds the 3x3 neighbourhood for (cx, cy).
//                (cx_s1, cy_s1, mask_s1) registered alongside it.
//                Conway rule combinational; if `run`, write to write_fb.
//                m_axis_tdata = centre pixel (current state of read_fb).
//
// Frame synchronisation
//   `frame_start` (one-cycle pulse, last blanking cycle from vga.sv) clears
//   counters and pipeline-valid.  The first active cycle has tvalid=0
//   (one-cycle pipeline-fill) and pixel(0,0) appears on the second active
//   cycle -- a one-pixel raster offset, accepted for simplicity.
//
// Backpressure
//   tready=0 freezes counters, the pipeline-valid register, and BRAM activity.
//   On resume the pipeline picks up exactly where it left off.
//
// Run / step
//   run=1 (and !prog_mode): engine writes to write_fb on every valid cycle
//     and swaps framebuffers when the (W-1, H-1) pixel is written.
//   run=0: engine still raster-scans for the OUTPUT path so the screen keeps
//     showing the live frame; writes and the swap are suppressed.
//   frame_done pulses for one cycle on the swap.
//
// Programming
//   prog_mode=1 disables the engine.  prog_we / prog_x / prog_y / prog_data
//   write the addressed pixel into BOTH framebuffers in the same cycle so the
//   read_fb (whichever it currently is) and its swap partner are identical
//   when programming completes.

`timescale 1ns / 1ps
`default_nettype none

module conway #(
    parameter int W   = 640,                                // grid width
    parameter int H   = 480,                                // grid height
    parameter int W3  = (W + 2) / 3,                        // ceil(W/3) -- BRAM word-columns
    parameter int H3  = (H + 2) / 3,                        // ceil(H/3) -- BRAM word-rows
    parameter int A_W = $clog2(W3 * H3),                    // BRAM address width
    parameter int X_W = $clog2(W),
    parameter int Y_W = $clog2(H),
    parameter int X3W = (W3 <= 1) ? 1 : $clog2(W3),
    parameter int Y3W = (H3 <= 1) ? 1 : $clog2(H3)
) (
    input  wire             clk,
    input  wire             rst_n,

    // Frame-start strobe from the VGA controller (one cycle, last blank cycle).
    input  wire             frame_start,

    // 1-bit AXI-Stream pixel output
    output logic            m_axis_tdata,
    output logic            m_axis_tvalid,
    input  wire             m_axis_tready,

    // Engine run/step control
    input  wire             run,
    output logic            frame_done,

    // Programming interface (writes both framebuffers at once)
    input  wire             prog_mode,
    input  wire             prog_we,
    input  wire [X_W-1:0]   prog_x,
    input  wire [Y_W-1:0]   prog_y,
    input  wire             prog_data
);

    // -------------------------------------------------------------------------
    // Pipeline enable -- pixel-rate gating from downstream tready and prog_mode.
    // -------------------------------------------------------------------------
    wire enable = m_axis_tready & ~prog_mode;

    // -------------------------------------------------------------------------
    // Raster-scan counters with paired (mod3, div3) sub-counters.
    // The mod3/div3 pair tracks cx%3 and cx/3 without using mod or div at
    // run-time; the upper counter advances only when the lower rolls over.
    // -------------------------------------------------------------------------
    logic [X_W-1:0]   cx;
    logic [Y_W-1:0]   cy;
    logic [1:0]       cx_m3, cy_m3;
    logic [X3W-1:0]   cx_d3;
    logic [Y3W-1:0]   cy_d3;

    wire cx_last = (cx == X_W'(W - 1));
    wire cy_last = (cy == Y_W'(H - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cx <= '0; cx_m3 <= '0; cx_d3 <= '0;
            cy <= '0; cy_m3 <= '0; cy_d3 <= '0;
        end else if (frame_start) begin
            cx <= '0; cx_m3 <= '0; cx_d3 <= '0;
            cy <= '0; cy_m3 <= '0; cy_d3 <= '0;
        end else if (enable) begin
            if (cx_last) begin
                cx <= '0; cx_m3 <= '0; cx_d3 <= '0;
                if (cy_last) begin
                    cy <= '0; cy_m3 <= '0; cy_d3 <= '0;
                end else begin
                    cy <= cy + 1'b1;
                    if (cy_m3 == 2'd2) begin cy_m3 <= '0; cy_d3 <= cy_d3 + 1'b1; end
                    else                     cy_m3 <= cy_m3 + 1'b1;
                end
            end else begin
                cx <= cx + 1'b1;
                if (cx_m3 == 2'd2) begin cx_m3 <= '0; cx_d3 <= cx_d3 + 1'b1; end
                else                     cx_m3 <= cx_m3 + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // _DELTA_LUT[bx][cm3] = ((bx - cm3) + 4) % 3 - 1   in {-1, 0, +1}.
    // -------------------------------------------------------------------------
    function automatic logic signed [1:0] delta_lut(input logic [1:0] b,
                                                    input logic [1:0] m);
        case ({b, m})
            4'b00_00: delta_lut =  2'sd0;
            4'b00_01: delta_lut = -2'sd1;
            4'b00_10: delta_lut =  2'sd1;
            4'b01_00: delta_lut =  2'sd1;
            4'b01_01: delta_lut =  2'sd0;
            4'b01_10: delta_lut = -2'sd1;
            4'b10_00: delta_lut = -2'sd1;
            4'b10_01: delta_lut =  2'sd1;
            4'b10_10: delta_lut =  2'sd0;
            default:  delta_lut =  2'sd0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Per-BRAM read address generation (combinational).  Out-of-grid neighbours
    // get a safe address of 0 and are masked to 0 by oob_mask[bx][by].
    // -------------------------------------------------------------------------
    logic [A_W-1:0] r_addr   [0:2][0:2];
    logic           oob_mask [0:2][0:2];

    always_comb begin
        for (int bx = 0; bx < 3; bx++) begin
            for (int by = 0; by < 3; by++) begin
                automatic logic signed [1:0] dx = delta_lut(2'(bx), cx_m3);
                automatic logic signed [1:0] dy = delta_lut(2'(by), cy_m3);
                automatic logic [X3W-1:0]    xd3;
                automatic logic [Y3W-1:0]    yd3;
                automatic logic              oob;

                oob = 1'b0;

                // x address / OOB
                if (dx == 2'sd0) begin
                    xd3 = cx_d3;
                end else if (dx == 2'sd1) begin
                    if (cx_last) begin
                        xd3 = '0;       // off the right edge -> mask
                        oob = 1'b1;
                    end else if (cx_m3 == 2'd2) begin
                        xd3 = cx_d3 + 1'b1;
                    end else begin
                        xd3 = cx_d3;
                    end
                end else begin // dx == -1
                    if (cx == '0) begin
                        xd3 = '0;       // off the left edge -> mask
                        oob = 1'b1;
                    end else if (cx_m3 == 2'd0) begin
                        xd3 = cx_d3 - 1'b1;
                    end else begin
                        xd3 = cx_d3;
                    end
                end

                // y address / OOB
                if (dy == 2'sd0) begin
                    yd3 = cy_d3;
                end else if (dy == 2'sd1) begin
                    if (cy_last) begin
                        yd3 = '0;
                        oob = 1'b1;
                    end else if (cy_m3 == 2'd2) begin
                        yd3 = cy_d3 + 1'b1;
                    end else begin
                        yd3 = cy_d3;
                    end
                end else begin // dy == -1
                    if (cy == '0) begin
                        yd3 = '0;
                        oob = 1'b1;
                    end else if (cy_m3 == 2'd0) begin
                        yd3 = cy_d3 - 1'b1;
                    end else begin
                        yd3 = cy_d3;
                    end
                end

                r_addr  [bx][by] = A_W'(yd3 * W3 + xd3);
                oob_mask[bx][by] = oob;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Programming-write address decode (slow path -- only at byte rate).
    // -------------------------------------------------------------------------
    logic [1:0]     px_m3, py_m3;
    logic [X3W-1:0] px_d3;
    logic [Y3W-1:0] py_d3;
    logic [A_W-1:0] pw_addr;

    always_comb begin
        px_m3   = 2'(prog_x % 3);
        py_m3   = 2'(prog_y % 3);
        px_d3   = X3W'(prog_x / 3);
        py_d3   = Y3W'(prog_y / 3);
        pw_addr = A_W'(py_d3 * W3 + px_d3);
    end

    // -------------------------------------------------------------------------
    // Active framebuffer select.  read_fb=0 means fb0 is read, fb1 is written.
    // -------------------------------------------------------------------------
    logic read_fb;

    // -------------------------------------------------------------------------
    // Pipeline-stage-1 registers -- track address-issue counters and the
    // out-of-grid masks one cycle forward so they line up with bram_rdata.
    // -------------------------------------------------------------------------
    logic [X_W-1:0] cx_s1;
    logic [Y_W-1:0] cy_s1;
    logic [1:0]     cx_m3_s1, cy_m3_s1;
    logic [X3W-1:0] cx_d3_s1;
    logic [Y3W-1:0] cy_d3_s1;
    logic           oob_s1 [0:2][0:2];
    logic           valid_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || frame_start) begin
            cx_s1 <= '0; cy_s1 <= '0;
            cx_m3_s1 <= '0; cy_m3_s1 <= '0;
            cx_d3_s1 <= '0; cy_d3_s1 <= '0;
            for (int bx = 0; bx < 3; bx++)
                for (int by = 0; by < 3; by++)
                    oob_s1[bx][by] <= 1'b0;
            valid_s1 <= 1'b0;
        end else if (enable) begin
            cx_s1    <= cx;
            cy_s1    <= cy;
            cx_m3_s1 <= cx_m3;
            cy_m3_s1 <= cy_m3;
            cx_d3_s1 <= cx_d3;
            cy_d3_s1 <= cy_d3;
            for (int bx = 0; bx < 3; bx++)
                for (int by = 0; by < 3; by++)
                    oob_s1[bx][by] <= oob_mask[bx][by];
            valid_s1 <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // BRAM array -- 2 framebuffers x 9 BRAMs.  Inferred as block RAM by Vivado.
    // We declare the engine write decode signals first (used inside generate).
    // -------------------------------------------------------------------------
    logic [A_W-1:0] eng_w_addr;
    logic           eng_w_data;
    logic [1:0]     eng_w_bx, eng_w_by;
    logic           eng_w_en;

    logic mem_fb0 [0:2][0:2][0:W3*H3-1];
    logic mem_fb1 [0:2][0:2][0:W3*H3-1];

    logic rdata_fb0 [0:2][0:2];
    logic rdata_fb1 [0:2][0:2];

    genvar gb_x, gb_y;
    generate
        for (gb_x = 0; gb_x < 3; gb_x++) begin : gx
            for (gb_y = 0; gb_y < 3; gb_y++) begin : gy

                // Engine write hits this BRAM iff (cx_m3_s1, cy_m3_s1)
                // selects (gb_x, gb_y).  Programming hits this BRAM iff
                // (px_m3, py_m3) selects it.
                wire eng_sel  = (eng_w_bx == 2'(gb_x)) && (eng_w_by == 2'(gb_y));
                wire prog_sel = (px_m3    == 2'(gb_x)) && (py_m3    == 2'(gb_y));

                // In prog mode: write both FBs from the prog interface.
                // Otherwise: engine writes the FB that is NOT read_fb.
                wire we0 = prog_mode ? (prog_we      & prog_sel)
                                     : (eng_w_en     & eng_sel & read_fb);
                wire we1 = prog_mode ? (prog_we      & prog_sel)
                                     : (eng_w_en     & eng_sel & ~read_fb);

                wire [A_W-1:0] waddr = prog_mode ? pw_addr   : eng_w_addr;
                wire           wdat  = prog_mode ? prog_data : eng_w_data;

                always_ff @(posedge clk) begin
                    if (we0) mem_fb0[gb_x][gb_y][waddr] <= wdat;
                    rdata_fb0[gb_x][gb_y] <= mem_fb0[gb_x][gb_y][r_addr[gb_x][gb_y]];
                end
                always_ff @(posedge clk) begin
                    if (we1) mem_fb1[gb_x][gb_y][waddr] <= wdat;
                    rdata_fb1[gb_x][gb_y] <= mem_fb1[gb_x][gb_y][r_addr[gb_x][gb_y]];
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Stage-1 combinational: select read_fb's bram_rdata, apply OOB mask,
    // un-permute back to neighbourhood (dy+1, dx+1).
    // -------------------------------------------------------------------------
    logic nbhd [0:2][0:2];
    always_comb begin
        // Default to 0 so any unassigned cell (cannot happen, but lint-safe)
        // is dead.
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++)
                nbhd[r][c] = 1'b0;

        for (int bx = 0; bx < 3; bx++) begin
            for (int by = 0; by < 3; by++) begin
                automatic logic signed [1:0] dx = delta_lut(2'(bx), cx_m3_s1);
                automatic logic signed [1:0] dy = delta_lut(2'(by), cy_m3_s1);
                automatic logic              raw;
                raw = read_fb ? rdata_fb1[bx][by] : rdata_fb0[bx][by];
                nbhd[dy + 2'sd1][dx + 2'sd1] = oob_s1[bx][by] ? 1'b0 : raw;
            end
        end
    end

    wire [3:0] live_count = 4'(nbhd[0][0]) + 4'(nbhd[0][1]) + 4'(nbhd[0][2])
                          + 4'(nbhd[1][0])                  + 4'(nbhd[1][2])
                          + 4'(nbhd[2][0]) + 4'(nbhd[2][1]) + 4'(nbhd[2][2]);
    wire centre_alive = nbhd[1][1];
    wire next_state   = centre_alive ? (live_count == 4'd2 || live_count == 4'd3)
                                     : (live_count == 4'd3);

    // -------------------------------------------------------------------------
    // Engine write decode: write next_state to write_fb at (cx_s1, cy_s1)
    // when stage-1 is valid and `run` is high.
    // -------------------------------------------------------------------------
    always_comb begin
        eng_w_en   = valid_s1 & run;
        eng_w_data = next_state;
        eng_w_bx   = cx_m3_s1;
        eng_w_by   = cy_m3_s1;
        eng_w_addr = A_W'(cy_d3_s1 * W3 + cx_d3_s1);
    end

    // -------------------------------------------------------------------------
    // Frame-completion / framebuffer swap.
    // -------------------------------------------------------------------------
    wire last_pixel_write = valid_s1 & run &
                            (cx_s1 == X_W'(W - 1)) & (cy_s1 == Y_W'(H - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_fb    <= 1'b0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (last_pixel_write) begin
                read_fb    <= ~read_fb;
                frame_done <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI-Stream output -- centre pixel of read_fb's neighbourhood.
    // (When run=0, the engine still raster-scans; the centre pixel is the
    // current state of read_fb at (cx_s1, cy_s1), so the display keeps showing
    // the live frame instead of going black.)
    // -------------------------------------------------------------------------
    assign m_axis_tdata  = nbhd[1][1];
    assign m_axis_tvalid = valid_s1 & ~prog_mode;

endmodule

`default_nettype wire
