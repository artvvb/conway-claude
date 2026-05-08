// conway_top.sv -- Complete Conway's Game of Life system for Basys 3.
//
// Block diagram (single 25 MHz pixel-clock domain — no CDC anywhere)
//
//   100 MHz osc -> MMCM -> 25 MHz pix_clk
//
//   rxd -> uart_rx -> hex_decode -.
//                       (byte) ---+--> uart_cmd ----------> conway --> vga_controller --> VGA
//                       (nibble) -'        |                  ^             |
//                                          |  prog_*          |             v
//                                          +------------------+         Hsync/Vsync
//                                          |                  |             |
//                                          |  run, frame_done |   tready    |
//                                          +<-----------------+             |
//                                          |  frame_start                   |
//                                          +<-------------------------------+
//
//   The conway engine produces 1-bit pixels; this top expands them to a
//   black-and-white R4G4B4 word (FFF or 000) before handing them to vga.sv.
//
//   The build flow attaches a single source file to the project, so this
//   module pulls in every dependency by `include.

`timescale 1ns / 1ps
`default_nettype none

`include "vga.sv"
`include "uart_rx.sv"
`include "hex_decode.sv"
`include "uart_cmd.sv"
`include "conway.sv"

module conway_top (
    input  wire         clk,        // 100 MHz system clock (W5)
    input  wire         btnc,       // centre push-button — hold for reset (U18)

    input  wire         rxd,        // UART receive from USB-UART bridge (B18)

    output logic [15:0] led,

    output wire  [3:0]  vgaRed,
    output wire  [3:0]  vgaGreen,
    output wire  [3:0]  vgaBlue,
    output wire         Hsync,
    output wire         Vsync
);

    // =========================================================================
    // Pixel-clock generation — MMCME2_BASE  (100 MHz x 10 / 40 = 25.000 MHz)
    // =========================================================================
    wire pix_clk_raw, pix_clk, clkfb, pll_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD     (10.0),
        .CLKFBOUT_MULT_F   (10.0),
        .CLKOUT0_DIVIDE_F  (40.0),
        .DIVCLK_DIVIDE     (1),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE     (0.0)
    ) mmcm_inst (
        .CLKIN1   (clk),
        .CLKFBOUT (clkfb),     .CLKFBOUTB (),
        .CLKFBIN  (clkfb),
        .CLKOUT0  (pix_clk_raw), .CLKOUT0B (),
        .CLKOUT1  (), .CLKOUT1B (),
        .CLKOUT2  (), .CLKOUT2B (),
        .CLKOUT3  (), .CLKOUT3B (),
        .CLKOUT4  (), .CLKOUT5  (), .CLKOUT6 (),
        .LOCKED   (pll_locked),
        .RST      (1'b0),
        .PWRDWN   (1'b0)
    );

    BUFG pix_bufg (.I(pix_clk_raw), .O(pix_clk));

    // =========================================================================
    // Reset synchroniser (pix_clk domain)
    //   pll_locked low or btnc high asserts rst_n low (asynchronously).
    //   Release is synchronous through two flip-flops.
    // =========================================================================
    logic [1:0] rst_pipe;
    always_ff @(posedge pix_clk or negedge pll_locked)
        if (!pll_locked) rst_pipe <= 2'b00;
        else             rst_pipe <= {rst_pipe[0], ~btnc};

    wire rst_n = rst_pipe[1];

    // =========================================================================
    // UART receive — note CLK_FREQ matches the 25 MHz domain
    // =========================================================================
    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       rx_ready;

    uart_rx #(
        .CLK_FREQ  (25_000_000),
        .BAUD_RATE (115_200)
    ) rx_inst (
        .clk           (pix_clk),
        .rst_n         (rst_n),
        .rxd           (rxd),
        .m_axis_tdata  (rx_byte),
        .m_axis_tvalid (rx_valid),
        .m_axis_tready (rx_ready)
    );

    // =========================================================================
    // Hex decoder — combinational passthrough.  Carries (byte) and (nibble +
    // invalid) on a shared tvalid/tready, both fed in parallel to uart_cmd.
    // =========================================================================
    wire [3:0] rx_nibble;
    wire       rx_nibble_invalid;
    wire       rx_nibble_valid;        // == rx_valid (passthrough)
    wire       rx_nibble_ready;        // == rx_ready (passthrough)

    hex_decode hex_inst (
        .s_axis_tdata  (rx_byte),
        .s_axis_tvalid (rx_valid),
        .s_axis_tready (rx_ready),
        .m_axis_tdata  (rx_nibble),
        .m_axis_tvalid (rx_nibble_valid),
        .m_axis_tuser  (rx_nibble_invalid),
        .m_axis_tready (rx_nibble_ready)
    );

    // =========================================================================
    // Conway engine + VGA controller wires
    // =========================================================================
    localparam int CW = 640;
    localparam int CH = 480;

    wire        cw_pix;
    wire        cw_pix_valid;
    wire        cw_pix_ready;
    wire        cw_run;
    wire        cw_frame_done;
    wire        cw_prog_mode;
    wire        cw_prog_we;
    wire [$clog2(CW)-1:0] cw_prog_x;
    wire [$clog2(CH)-1:0] cw_prog_y;
    wire        cw_prog_data;

    wire        vga_frame_start;

    // =========================================================================
    // Command parser
    // =========================================================================
    uart_cmd #(
        .W (CW),
        .H (CH)
    ) cmd_inst (
        .clk                 (pix_clk),
        .rst_n               (rst_n),

        .s_axis_byte_tdata   (rx_byte),
        .s_axis_nibble_tdata (rx_nibble),
        .s_axis_nibble_tuser (rx_nibble_invalid),
        // Single shared handshake — drive into BOTH chains.  hex_decode is
        // combinational so its tready/tvalid track the byte stream exactly.
        .s_axis_tvalid       (rx_nibble_valid),
        .s_axis_tready       (rx_nibble_ready),

        .run                 (cw_run),
        .frame_done          (cw_frame_done),
        .frame_start         (vga_frame_start),

        .prog_mode           (cw_prog_mode),
        .prog_we             (cw_prog_we),
        .prog_x              (cw_prog_x),
        .prog_y              (cw_prog_y),
        .prog_data           (cw_prog_data)
    );

    // =========================================================================
    // Conway engine
    // =========================================================================
    conway #(
        .W (CW),
        .H (CH)
    ) conway_inst (
        .clk           (pix_clk),
        .rst_n         (rst_n),
        .frame_start   (vga_frame_start),

        .m_axis_tdata  (cw_pix),
        .m_axis_tvalid (cw_pix_valid),
        .m_axis_tready (cw_pix_ready),

        .run           (cw_run),
        .frame_done    (cw_frame_done),

        .prog_mode     (cw_prog_mode),
        .prog_we       (cw_prog_we),
        .prog_x        (cw_prog_x),
        .prog_y        (cw_prog_y),
        .prog_data     (cw_prog_data)
    );

    // =========================================================================
    // 1-bit -> R4G4B4 expansion: alive = white, dead = black.
    // =========================================================================
    wire [11:0] vga_pixel = cw_pix ? 12'hFFF : 12'h000;

    // =========================================================================
    // VGA controller
    // =========================================================================
    vga_controller #(
        .H_ACTIVE      (640),
        .H_FRONT_PORCH (16),
        .H_SYNC_WIDTH  (96),
        .H_BACK_PORCH  (48),
        .V_ACTIVE      (480),
        .V_FRONT_PORCH (10),
        .V_SYNC_WIDTH  (2),
        .V_BACK_PORCH  (33),
        .HSYNC_POL     (1'b0),
        .VSYNC_POL     (1'b0)
    ) vga_ctrl (
        .clk           (pix_clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (vga_pixel),
        .s_axis_tvalid (cw_pix_valid),
        .s_axis_tready (cw_pix_ready),
        .vga_r         (vgaRed),
        .vga_g         (vgaGreen),
        .vga_b         (vgaBlue),
        .vga_hsync     (Hsync),
        .vga_vsync     (Vsync),
        .vga_de        (),
        .frame_start   (vga_frame_start)
    );

    // =========================================================================
    // LED status
    //   [0] run
    //   [1] prog_mode
    //   [2] frame_done (sticky-toggle for visibility)
    //   [7:4] free counter (~6 Hz) so we can tell the design is alive
    //   [8] PLL locked
    //   [15:9] 0
    // =========================================================================
    logic        fd_toggle;
    always_ff @(posedge pix_clk or negedge rst_n)
        if (!rst_n)            fd_toggle <= 1'b0;
        else if (cw_frame_done) fd_toggle <= ~fd_toggle;

    logic [21:0] heartbeat;
    always_ff @(posedge pix_clk or negedge rst_n)
        if (!rst_n) heartbeat <= '0;
        else        heartbeat <= heartbeat + 1'b1;

    always_ff @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) led <= '0;
        else begin
            led[0]    <= cw_run;
            led[1]    <= 1'b0;
            led[2]    <= fd_toggle;
            led[3]    <= cw_prog_mode;
            led[7:4]  <= heartbeat[21:18];
            led[8]    <= pll_locked;
            led[15:9] <= '0;
        end
    end

endmodule

`default_nettype wire
