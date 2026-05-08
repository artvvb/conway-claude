// uart-rx.sv — 8N1 UART receiver with AXI-Stream output
//
// Samples the centre of each bit: start bit at CLK_FREQ/(2*BAUD_RATE),
// then every CLK_FREQ/BAUD_RATE cycles thereafter.
// Input is synchronised through a 2-FF stage before use.
//
// AXI-Stream handshake: tvalid stays asserted until tready is seen.
// A new byte is not accepted until the previous one has been consumed,
// preventing data loss at the cost of dropping the incoming start edge
// if the consumer is too slow (acceptable for typical use cases).

`timescale 1ns / 1ps
`default_nettype none

module uart_rx #(
    parameter int CLK_FREQ  = 100_000_000,   // driving clock in Hz
    parameter int BAUD_RATE = 115_200        // target baud rate
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async assert / sync deassert recommended

    input  wire        rxd,     // raw serial input

    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    input  wire        m_axis_tready
);

    // -------------------------------------------------------------------------
    // Timing constants
    // -------------------------------------------------------------------------
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;   // e.g. 868 @ 100 MHz / 115200
    localparam int BAUD_W       = $clog2(CLKS_PER_BIT);   // counter width

    // -------------------------------------------------------------------------
    // 2-FF input synchroniser
    // -------------------------------------------------------------------------
    logic [1:0] rxd_sync;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) rxd_sync <= 2'b11;   // idle line is high
        else        rxd_sync <= {rxd_sync[0], rxd};

    wire rxd_s = rxd_sync[1];

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE  = 2'd0,
        START = 2'd1,
        DATA  = 2'd2,
        STOP  = 2'd3
    } state_t;

    state_t            state;
    logic [BAUD_W-1:0] baud_cnt;
    logic [2:0]        bit_cnt;
    logic [7:0]        shift_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            baud_cnt       <= '0;
            bit_cnt        <= '0;
            shift_reg      <= '0;
            m_axis_tdata   <= '0;
            m_axis_tvalid  <= 1'b0;
        end else begin
            // Consume handshake — clear valid as soon as tready is seen
            if (m_axis_tvalid && m_axis_tready)
                m_axis_tvalid <= 1'b0;

            case (state)
                // -----------------------------------------------------------------
                IDLE: begin
                    // Only start a new byte when the previous one has been consumed
                    if (!m_axis_tvalid && !rxd_s) begin
                        state    <= START;
                        baud_cnt <= '0;
                    end
                end

                // -----------------------------------------------------------------
                // Count to the centre of the start bit, then verify it is still low
                START: begin
                    if (baud_cnt == BAUD_W'(CLKS_PER_BIT / 2 - 1)) begin
                        baud_cnt <= '0;
                        if (!rxd_s) begin
                            state   <= DATA;
                            bit_cnt <= '0;
                        end else
                            state <= IDLE;   // false start
                    end else
                        baud_cnt <= baud_cnt + 1'b1;
                end

                // -----------------------------------------------------------------
                // Sample one bit per CLKS_PER_BIT, LSB first, shift right
                DATA: begin
                    if (baud_cnt == BAUD_W'(CLKS_PER_BIT - 1)) begin
                        baud_cnt  <= '0;
                        shift_reg <= {rxd_s, shift_reg[7:1]};   // LSB first → shifts into [7]
                        if (bit_cnt == 3'd7)
                            state <= STOP;
                        else
                            bit_cnt <= bit_cnt + 1'b1;
                    end else
                        baud_cnt <= baud_cnt + 1'b1;
                end

                // -----------------------------------------------------------------
                // Sample centre of stop bit; latch byte if stop bit is valid (high)
                STOP: begin
                    if (baud_cnt == BAUD_W'(CLKS_PER_BIT - 1)) begin
                        baud_cnt <= '0;
                        state    <= IDLE;
                        if (rxd_s) begin   // valid stop bit
                            m_axis_tdata  <= shift_reg;
                            m_axis_tvalid <= 1'b1;
                        end
                        // framing error (rxd_s=0): discard byte silently
                    end else
                        baud_cnt <= baud_cnt + 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
