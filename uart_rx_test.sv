// uart-rx-test.sv — UART → hex decoder → LED barrel-shifter top for Basys 3
//
// System clock : 100 MHz (W5)
// UART         : 115200 8N1, received on USB-UART bridge RXD pin (B18)
//
// Operation
//   Each valid hex character received over UART shifts its 4-bit value into
//   the least-significant nibble of the 16-bit LED display:
//     led ← {led[11:0], nibble}
//   Invalid characters (not 0–9, A–F, a–f) are silently discarded.
//   After four valid characters the display holds the full 16-bit hex value.
//
// Reset
//   BTNC (U18) acts as active-high synchronous reset.  Hold to clear LEDs
//   and return the UART receiver to idle.

`timescale 1ns / 1ps
`default_nettype none

module uart_rx_test (
    input  wire         clk,    // 100 MHz system clock (W5)
    input  wire         btnc,   // centre push-button — hold for reset (U18)
    input  wire         rxd,    // UART receive from USB-UART bridge (B18)
    output logic [15:0] led     // LED display LD15..LD0
);

    // =========================================================================
    // Reset synchroniser
    // BTNC is active-high; invert and synchronise through two flip-flops for
    // a clean synchronous-release active-low reset.
    // =========================================================================
    logic [1:0] rst_sync;
    always_ff @(posedge clk)
        rst_sync <= {rst_sync[0], ~btnc};

    wire rst_n = rst_sync[1];

    // =========================================================================
    // UART receiver
    // =========================================================================
    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       rx_ready;   // driven by hex_decode below

    uart_rx #(
        .CLK_FREQ  (100_000_000),
        .BAUD_RATE (115_200)
    ) rx_inst (
        .clk           (clk),
        .rst_n         (rst_n),
        .rxd           (rxd),
        .m_axis_tdata  (rx_byte),
        .m_axis_tvalid (rx_valid),
        .m_axis_tready (rx_ready)
    );

    // =========================================================================
    // Hex decoder
    // =========================================================================
    wire [3:0] nibble;
    wire       nibble_valid;
    wire       nibble_invalid;   // tuser: 1 when character is not a hex digit

    hex_decode hex_inst (
        .s_axis_tdata  (rx_byte),
        .s_axis_tvalid (rx_valid),
        .s_axis_tready (rx_ready),   // feeds back to uart_rx tready
        .m_axis_tdata  (nibble),
        .m_axis_tvalid (nibble_valid),
        .m_axis_tuser  (nibble_invalid),
        .m_axis_tready (1'b1)        // LED shift register is always ready
    );

    // =========================================================================
    // LED barrel-shift register
    // Each accepted nibble shifts into the LSB; MSB falls off the display.
    // =========================================================================
    logic [15:0] led_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            led_r <= '0;
        else if (nibble_valid && !nibble_invalid)
            led_r <= {led_r[11:0], nibble};
    end

    // Register output for glitch-free drive
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) led <= '0;
        else        led <= led_r;
    end

endmodule

`default_nettype wire
