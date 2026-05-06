// vga-test.sv — VGA test-pattern top for Basys 3 (XC7A35T-1CPG236C)
//
// System clock : 100 MHz (W5)
// Pixel clock  : 25.000 MHz — MMCME2_BASE, 100 × 10 / 40
//                (0.7 % slower than the 25.175 MHz ideal; undetectable on monitors)
//
// Control (BTNC)
//   Toggles between IDLE (black output) and RUN (test pattern).
//   Button is synchronised through two flip-flops then debounced with a
//   ~20 ms hold counter to suppress contact bounce.
//
// Pattern select (SW[1:0])
//   00  Colour bars  — 8 vertical stripes × 80 px, SMPTE palette.
//                      Bar position tracked with a paired counter (x_sub / bar_idx);
//                      no division used, consistent with the Conway engine approach.
//   01  Checkerboard — 64 × 64 px tiles.  Tile parity = px[6] ^ py[6]:
//                      bit-extract only, no division.
//   10  RGB gradient — R from column upper bits, G from row upper bits,
//                      B from their XOR.
//   11  Crosshatch   — white grid on black: vertical lines every 80 px
//                      (from x_sub == 0), horizontal lines every 64 lines
//                      (from py[5:0] == 0).
//
// LEDs
//   [0]   IDLE indicator
//   [1]   RUN  indicator
//   [3:2] SW[1:0] mirror — shows the active pattern
//   [7:4] frame_cnt[3:0] — toggles at ~4 Hz; visible sanity-check
//   [8]   PLL locked
//   [15:9] driven 0

`timescale 1ns / 1ps
`default_nettype none

module vga_test (
    input  wire         clk,      // 100 MHz system clock (W5)

    input  wire         btnc,     // centre push-button — toggle IDLE / RUN (U18)

    input  wire [1:0]   sw,       // pattern select: SW1 (V16), SW0 (V17)

    output logic [15:0] led,      // debug LEDs LD15..LD0

    // VGA — names match Basys 3 master XDC exactly
    output wire  [3:0]  vgaRed,
    output wire  [3:0]  vgaGreen,
    output wire  [3:0]  vgaBlue,
    output wire         Hsync,
    output wire         Vsync
);

    // =========================================================================
    // Pixel-clock generation — MMCME2_BASE
    // VCO = 100 MHz × 10 = 1000 MHz (within Artix-7 600–1200 MHz range)
    // OUT = 1000 MHz / 40 = 25.000 MHz
    // =========================================================================
    wire pix_clk_raw, pix_clk, clkfb, pll_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD     (10.0),   // 100 MHz = 10 ns period
        .CLKFBOUT_MULT_F   (10.0),   // VCO = 1000 MHz
        .CLKOUT0_DIVIDE_F  (40.0),   // pixel clock = 25.000 MHz
        .DIVCLK_DIVIDE     (1),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE     (0.0)
    ) mmcm_inst (
        .CLKIN1    (clk),
        .CLKFBOUT  (clkfb),   .CLKFBOUTB (),
        .CLKFBIN   (clkfb),
        .CLKOUT0   (pix_clk_raw), .CLKOUT0B (),
        .CLKOUT1   (), .CLKOUT1B (),
        .CLKOUT2   (), .CLKOUT2B (),
        .CLKOUT3   (), .CLKOUT3B (),
        .CLKOUT4   (), .CLKOUT5  (), .CLKOUT6 (),
        .LOCKED    (pll_locked),
        .RST       (1'b0),
        .PWRDWN    (1'b0)
    );

    BUFG pix_bufg (.I(pix_clk_raw), .O(pix_clk));

    // =========================================================================
    // Reset synchroniser (pixel-clock domain)
    // pll_locked going low asserts reset asynchronously (negedge sensitivity).
    // pll_locked going high releases reset synchronously after two pix_clk
    // edges, preventing metastability on the reset release path.
    // =========================================================================
    logic [1:0] rst_pipe;
    always_ff @(posedge pix_clk or negedge pll_locked)
        if (!pll_locked) rst_pipe <= 2'b00;
        else             rst_pipe <= {rst_pipe[0], 1'b1};

    wire rst_n = rst_pipe[1];   // synchronous-release active-low reset

    // =========================================================================
    // Button: 2-FF synchroniser + ~20 ms debounce, pixel-clock domain
    // =========================================================================
    logic [1:0] btn_sync;
    always_ff @(posedge pix_clk or negedge rst_n)
        if (!rst_n) btn_sync <= 2'b00;
        else        btn_sync <= {btn_sync[0], btnc};

    // Debounce: candidate must hold stable for DB_TICKS before being accepted
    localparam int DB_TICKS = 500_000;              // ~20 ms @ 25 MHz
    localparam int DB_W     = $clog2(DB_TICKS + 1);

    logic [DB_W-1:0] db_cnt;
    logic            btn_db, btn_db_r;

    always_ff @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            db_cnt <= '0;
            btn_db <= 1'b0;
        end else begin
            if (btn_sync[1] != btn_db) begin
                if (db_cnt == DB_W'(DB_TICKS - 1)) begin
                    btn_db <= btn_sync[1];
                    db_cnt <= '0;
                end else
                    db_cnt <= db_cnt + 1'b1;
            end else
                db_cnt <= '0;
        end
    end

    always_ff @(posedge pix_clk or negedge rst_n)
        if (!rst_n) btn_db_r <= 1'b0;
        else        btn_db_r <= btn_db;

    wire btn_rise = btn_db & ~btn_db_r;   // one-cycle pulse on press

    // =========================================================================
    // Control state machine  IDLE ↔ RUN
    // =========================================================================
    typedef enum logic { IDLE = 1'b0, RUN = 1'b1 } state_t;
    state_t state;

    always_ff @(posedge pix_clk or negedge rst_n)
        if (!rst_n)        state <= IDLE;
        else if (btn_rise) state <= (state == IDLE) ? RUN : IDLE;

    wire running = (state == RUN);

    // =========================================================================
    // Switch input registered to pixel-clock domain
    // sw changes orders of magnitude slower than pix_clk; one pipeline register
    // removes any metastability before the combinational pattern mux.
    // =========================================================================
    logic [1:0] sw_r;
    always_ff @(posedge pix_clk) sw_r <= sw;

    // =========================================================================
    // AXI-Stream wires
    // =========================================================================
    wire        tvalid_w = running;
    wire        tready_w;                  // driven by vga_controller
    wire consume = tvalid_w & tready_w;   // one pixel consumed per active clock

    // =========================================================================
    // Pixel counters (px, py)
    // Advance only when a pixel is consumed so the pattern generator always
    // knows which logical pixel position it is producing.
    // =========================================================================
    localparam int H_ACTIVE = 640;
    localparam int V_ACTIVE = 480;
    localparam int PX_W     = $clog2(H_ACTIVE + 1);   // 10 bits
    localparam int PY_W     = $clog2(V_ACTIVE + 1);   //  9 bits

    logic [PX_W-1:0] px;
    logic [PY_W-1:0] py;
    logic [11:0]     frame_cnt;           // wraps at 4096 (~68 s @ 60 fps)

    always_ff @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n || !running) begin
            px        <= '0;
            py        <= '0;
            frame_cnt <= '0;
        end else if (consume) begin
            if (px == PX_W'(H_ACTIVE - 1)) begin
                px <= '0;
                if (py == PY_W'(V_ACTIVE - 1)) begin
                    py        <= '0;
                    frame_cnt <= frame_cnt + 1'b1;
                end else
                    py <= py + 1'b1;
            end else
                px <= px + 1'b1;
        end
    end

    // =========================================================================
    // Colour-bar paired counters (no division — mirrors the Conway engine style)
    //
    // 640 / 8 bars = 80 px per bar.
    // x_sub   : lower counter, 0–79, resets every bar boundary
    // bar_idx : upper counter, 0–7,  increments when x_sub rolls over
    // Both reset at the end of each line so bar 0 always starts at px = 0.
    // =========================================================================
    localparam int BAR_W   = 80;
    localparam int BAR_W_W = $clog2(BAR_W);   // 7 bits covers 0–79

    logic [BAR_W_W-1:0] x_sub;
    logic [2:0]          bar_idx;

    always_ff @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n || !running) begin
            x_sub   <= '0;
            bar_idx <= '0;
        end else if (consume) begin
            if (px == PX_W'(H_ACTIVE - 1)) begin
                // End of active line — reset for next line
                x_sub   <= '0;
                bar_idx <= '0;
            end else if (x_sub == BAR_W_W'(BAR_W - 1)) begin
                // End of this bar — advance to next
                x_sub   <= '0;
                bar_idx <= bar_idx + 1'b1;
            end else
                x_sub <= x_sub + 1'b1;
        end
    end

    // =========================================================================
    // Pattern generation (combinational)
    // =========================================================================

    // SMPTE-style colour bar palette
    logic [11:0] bar_colour;
    always_comb
        case (bar_idx)
            3'd0: bar_colour = 12'hFFF;   // white
            3'd1: bar_colour = 12'hFF0;   // yellow
            3'd2: bar_colour = 12'h0FF;   // cyan
            3'd3: bar_colour = 12'h0F0;   // green
            3'd4: bar_colour = 12'hF0F;   // magenta
            3'd5: bar_colour = 12'hF00;   // red
            3'd6: bar_colour = 12'h00F;   // blue
            3'd7: bar_colour = 12'h000;   // black
        endcase

    logic [11:0] pixel;
    always_comb
        case (sw_r)
            2'b00:   // Colour bars (SMPTE palette, 8 × 80 px)
                pixel = bar_colour;

            2'b01:   // Checkerboard 64 × 64 px — bit-extract only, no division
                pixel = (px[6] ^ py[6]) ? 12'hFFF : 12'h000;

            2'b10:   // RGB gradient
                pixel = {px[9:6], py[8:5], px[5:2] ^ py[7:4]};

            2'b11:   // Crosshatch — white grid on black
                     //   Vertical lines every 80 px  : x_sub == 0
                     //   Horizontal lines every 64 ln: py[5:0] == 0  (power-of-2 no-div)
                pixel = ((x_sub == '0) || (py[5:0] == '0)) ? 12'hFFF : 12'h000;
        endcase

    // =========================================================================
    // VGA controller instance
    // =========================================================================
    vga_controller #(
        .H_ACTIVE      (H_ACTIVE),
        .H_FRONT_PORCH (16),
        .H_SYNC_WIDTH  (96),
        .H_BACK_PORCH  (48),
        .V_ACTIVE      (V_ACTIVE),
        .V_FRONT_PORCH (10),
        .V_SYNC_WIDTH  (2),
        .V_BACK_PORCH  (33),
        .HSYNC_POL     (1'b0),
        .VSYNC_POL     (1'b0)
    ) vga_ctrl (
        .clk           (pix_clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (pixel),
        .s_axis_tvalid (tvalid_w),
        .s_axis_tready (tready_w),
        .vga_r         (vgaRed),
        .vga_g         (vgaGreen),
        .vga_b         (vgaBlue),
        .vga_hsync     (Hsync),
        .vga_vsync     (Vsync),
        .vga_de        ()
    );

    // =========================================================================
    // LED indicators (registered in pixel-clock domain)
    //   [0]   IDLE
    //   [1]   RUN
    //   [3:2] active pattern (SW mirror)
    //   [7:4] frame counter bits [3:0] — toggles at ~4 Hz when running
    //   [8]   PLL locked (should be solid on after startup)
    //   [15:9] unused
    // =========================================================================
    always_ff @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            led <= '0;
        end else begin
            led[0]    <= ~running;
            led[1]    <=  running;
            led[3:2]  <=  sw_r;
            led[7:4]  <=  frame_cnt[3:0];
            led[8]    <=  pll_locked;
            led[15:9] <= '0;
        end
    end

endmodule

`default_nettype wire
